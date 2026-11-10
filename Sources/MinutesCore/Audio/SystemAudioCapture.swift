import AVFoundation
import CoreAudio
import Foundation
import os

/// Receives 16 kHz mono samples plus the host time (mach ticks) of the first sample.
public typealias AudioSink = @Sendable (_ samples: [Float], _ hostTime: UInt64) -> Void

private let log = MinutesLog("SystemAudio")

/// Captures everything the Mac plays (all processes except this app) through a Core Audio process tap
/// (macOS 14.2+). Needs the "System Audio Recording" permission, prompted on first start.
/// This is the "Them" side of a meeting: it works for any meeting app, native or browser, without a bot.
public final class SystemAudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "minutes.system-audio", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private let resampler = MonoResampler()
    private var sink: AudioSink?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var running = false
    /// Cleared by `detach()` without touching the capture queue, which may be stuck in a Core Audio call.
    private let forwarding = OSAllocatedUnfairLock(initialState: true)
    private let restartPending = OSAllocatedUnfairLock(initialState: false)
    private var rateTracker = RateTracker(rate: 48_000)
    /// Last time a non-silent buffer arrived; used by the caller to detect a silently broken tap.
    public private(set) var lastAudibleHostTime: UInt64 = 0
    public private(set) var lastBufferHostTime: UInt64 = 0
    /// IO buffer size to ask for on the tap's aggregate device; larger buffers mean fewer wake-ups.
    public var bufferFrames: UInt32?

    public init() {}

    public func start(sink: @escaping AudioSink) throws {
        forwarding.withLock { $0 = true }
        try queue.sync {
            self.sink = sink
            try self.build()
            self.running = true
        }
        // Rebuild when the user switches output (e.g. AirPods connect): the aggregate follows one device.
        outputListener = CoreAudioUtils.addSystemListener(kAudioHardwarePropertyDefaultOutputDevice, queue: queue) {
            [weak self] in
            guard let self, self.running else { return }
            log.info("default output changed, rebuilding tap")
            self.teardown()
            do { try self.build() } catch { log.error("rebuild failed: \(error.localizedDescription)") }
        }
    }

    public func stop() {
        if let outputListener {
            CoreAudioUtils.removeSystemListener(kAudioHardwarePropertyDefaultOutputDevice, queue: queue, listener: outputListener)
        }
        outputListener = nil
        queue.sync {
            self.running = false
            self.teardown()
            self.sink = nil
        }
    }

    /// Stops delivering audio immediately, without waiting for the capture queue.
    public func detach() {
        forwarding.withLock { $0 = false }
    }

    /// Tears down and recreates the tap. Call when buffers stop arriving (known macOS tap bug after sleep/route changes).
    /// Calls while a restart is still queued or running are ignored, so a hanging Core Audio call cannot pile them up.
    public func restart() {
        let alreadyPending = restartPending.withLock { pending -> Bool in
            defer { pending = true }
            return pending
        }
        guard !alreadyPending else { return }
        queue.async {
            defer { self.restartPending.withLock { $0 = false } }
            guard self.running, self.forwarding.withLock({ $0 }) else { return }
            self.teardown()
            do { try self.build() } catch { log.error("restart failed: \(error.localizedDescription)") }
        }
    }

    private func build() throws {
        let ownProcess = CoreAudioUtils.processObject(for: getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Minutes system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr else { throw CaptureError.coreAudio("create process tap", status) }
        tapID = newTap

        guard var asbd = CoreAudioUtils.property(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription()),
            let format = AVAudioFormat(streamDescription: &asbd)
        else { throw CaptureError.coreAudio("read tap format", -1) }
        tapFormat = format
        // Prefer the aggregate's actual rate once it exists (set below); the tap format can lag behind the device.
        rateTracker = RateTracker(rate: format.sampleRate)

        guard let output = CoreAudioUtils.defaultOutputDevice, let outputUID = CoreAudioUtils.deviceUID(output) else {
            throw CaptureError.coreAudio("default output device", -1)
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Minutes tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
        guard status == noErr else { throw CaptureError.coreAudio("create aggregate device", status) }
        aggregateID = newAggregate

        var newProc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, queue) {
            [weak self] _, inputData, inputTime, _, _ in
            self?.handle(inputData, inputTime)
        }
        guard status == noErr, let newProc else { throw CaptureError.coreAudio("create IO proc", status) }
        procID = newProc
        if let bufferFrames { CoreAudioUtils.setBufferFrames(aggregateID, bufferFrames) }
        status = AudioDeviceStart(aggregateID, newProc)
        guard status == noErr else { throw CaptureError.coreAudio("start aggregate device", status) }
        if let actual = CoreAudioUtils.property(aggregateID, kAudioDevicePropertyActualSampleRate, default: Float64(0)),
            actual > 0
        {
            rateTracker = RateTracker(rate: actual)
        }
        log.info("system audio tap running: tap format \(format.sampleRate) Hz, device \(rateTracker.rate) Hz, \(format.channelCount) ch")
    }

    private func handle(_ inputData: UnsafePointer<AudioBufferList>, _ inputTime: UnsafePointer<AudioTimeStamp>) {
        guard running, forwarding.withLock({ $0 }), let format = tapFormat, let sink else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        // The tap is the last buffer; earlier ones belong to the output device's own inputs, if any.
        guard let tapBuffer = list.last, let data = tapBuffer.mData, tapBuffer.mDataByteSize > 0 else { return }
        let channels = max(Int(tapBuffer.mNumberChannels), 1)
        let frames = Int(tapBuffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        let host = inputTime.pointee.mFlags.contains(.hostTimeValid) ? inputTime.pointee.mHostTime : HostTime.now
        let previousRate = rateTracker.rate
        let rate = rateTracker.update(frames: frames, hostTime: host)
        if rate != previousRate { log.warning("system audio rate corrected from \(previousRate) to \(rate) Hz") }
        _ = format
        guard frames > 0,
            let interleaved = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels),
                interleaved: true),
            let pcm = AVAudioPCMBuffer(pcmFormat: interleaved, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        memcpy(pcm.floatChannelData![0], data, Int(tapBuffer.mDataByteSize))
        let samples = resampler.convert(pcm)
        lastBufferHostTime = host
        if samples.contains(where: { abs($0) > 1e-4 }) { lastAudibleHostTime = host }
        if !samples.isEmpty { sink(samples, host) }
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { if running { stop() } }
}

public enum CaptureError: LocalizedError {
    case coreAudio(String, OSStatus)
    case microphone(String)

    public var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status): return "Core Audio: \(step) failed (\(status))"
        case .microphone(let msg): return "Microphone: \(msg)"
        }
    }
}
