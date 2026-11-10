import AVFoundation
import CoreAudio
import Foundation

private let log = MinutesLog("Microphone")

/// Captures the default input device (the "Me" side) as 16 kHz mono through a Core Audio IOProc.
///
/// A HAL IOProc instead of AVAudioEngine: AVAudioEngine stops on every configuration change anywhere in the
/// audio graph (output switches, Bluetooth profile changes, Siri taking the mic), and restarting it triggers
/// further changes, which ended in a restart loop in testing. Reading the input device directly only reacts
/// to what matters: a different default input device. Rate changes are caught by `RateTracker`.
public final class MicrophoneCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "minutes.microphone", qos: .userInitiated)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let resampler = MonoResampler()
    private var rateTracker = RateTracker(rate: 48_000)
    private var sink: AudioSink?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var rebuildWork: DispatchWorkItem?
    private var running = false
    public private(set) var lastAudibleHostTime: UInt64 = 0
    public private(set) var lastBufferHostTime: UInt64 = 0
    public private(set) var deviceName: String?
    /// Opening a Bluetooth headset's microphone switches it to the low-quality call profile for all audio.
    /// Fine during a call, not all day: passive mode sets this to record from the built-in microphone instead.
    public var avoidBluetooth = false
    /// IO buffer size to ask for; larger buffers mean fewer wake-ups (passive mode trades latency for energy).
    public var bufferFrames: UInt32?

    public init() {}

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start(sink: @escaping AudioSink) throws {
        try queue.sync {
            self.sink = sink
            self.running = true
            try self.build()
        }
        inputListener = CoreAudioUtils.addSystemListener(kAudioHardwarePropertyDefaultInputDevice, queue: queue) {
            [weak self] in
            self?.scheduleRebuild(reason: "default input changed")
        }
    }

    public func stop() {
        if let inputListener {
            CoreAudioUtils.removeSystemListener(kAudioHardwarePropertyDefaultInputDevice, queue: queue, listener: inputListener)
        }
        inputListener = nil
        queue.sync {
            self.running = false
            self.rebuildWork?.cancel()
            self.teardown()
            self.sink = nil
        }
    }

    /// Device changes often arrive in bursts; rebuild once things have been quiet for half a second.
    private func scheduleRebuild(reason: String) {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            let current = self.targetDevice
            guard current != self.deviceID || self.procID == nil else { return }
            log.info("\(reason), switching microphone")
            self.teardown()
            do { try self.build() } catch { log.error("microphone rebuild failed: \(error.localizedDescription)") }
        }
        rebuildWork = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// The default input, or the built-in microphone instead of a Bluetooth headset when `avoidBluetooth` is set.
    private var targetDevice: AudioObjectID? {
        guard let device = CoreAudioUtils.defaultInputDevice else { return nil }
        if avoidBluetooth, CoreAudioUtils.isBluetooth(device), let builtIn = CoreAudioUtils.builtInInputDevice { return builtIn }
        return device
    }

    private func build() throws {
        guard let device = targetDevice, device != kAudioObjectUnknown else {
            throw CaptureError.microphone("no input device")
        }
        deviceID = device
        deviceName = CoreAudioUtils.deviceName(device)
        var addr = CoreAudioUtils.address(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtStatus = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &asbd)
        guard fmtStatus == noErr, asbd.mSampleRate > 0 else { throw CaptureError.coreAudio("read input format", fmtStatus) }
        rateTracker = RateTracker(rate: asbd.mSampleRate)

        var newProc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&newProc, device, queue) { [weak self] _, inputData, inputTime, _, _ in
            self?.handle(inputData, inputTime)
        }
        guard status == noErr, let newProc else { throw CaptureError.coreAudio("create microphone IO proc", status) }
        procID = newProc
        let frames = bufferFrames.flatMap { CoreAudioUtils.setBufferFrames(device, $0) }
        status = AudioDeviceStart(device, newProc)
        guard status == noErr else { throw CaptureError.coreAudio("start microphone", status) }
        log.info(
            "microphone running: \(deviceName ?? "?"), \(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch\(frames.map { ", \($0)-frame buffers" } ?? "")")
    }

    private func handle(_ inputData: UnsafePointer<AudioBufferList>, _ inputTime: UnsafePointer<AudioTimeStamp>) {
        guard running, let sink else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let buffer = list.first, let data = buffer.mData, buffer.mDataByteSize > 0 else { return }
        let channels = max(Int(buffer.mNumberChannels), 1)
        let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        let host = inputTime.pointee.mFlags.contains(.hostTimeValid) ? inputTime.pointee.mHostTime : HostTime.now
        let previous = rateTracker.rate
        let rate = rateTracker.update(frames: frames, hostTime: host)
        if rate != previous { log.warning("microphone rate corrected from \(previous) to \(rate) Hz") }
        guard frames > 0,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: true),
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        memcpy(pcm.floatChannelData![0], data, Int(buffer.mDataByteSize))
        let samples = resampler.convert(pcm)
        lastBufferHostTime = host
        if samples.contains(where: { abs($0) > 1e-4 }) { lastAudibleHostTime = host }
        if !samples.isEmpty { sink(samples, host) }
    }

    private func teardown() {
        if deviceID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { if running { stop() } }
}
