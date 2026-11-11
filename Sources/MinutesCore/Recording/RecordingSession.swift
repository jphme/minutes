import AVFoundation
import FluidAudio
import Foundation
import os

private let log = MinutesLog("Recording")

/// One channel's path from capture to disk and live transcription.
/// Places incoming buffers on a shared timeline (seconds since recording start) using host time,
/// filling gaps (device switches, tap restarts) with silence so both channels stay aligned.
/// Without a file (passive mode) only the transcriber gets the audio, and long gaps (the system tap delivers
/// nothing until some app first plays sound, which can take hours; restarts and sleep leave gaps too) skip ahead
/// instead of materializing silence.
final class ChannelPipeline: @unchecked Sendable {
    enum Item: Sendable {
        case audio([Float])
        /// Samples of timeline to skip without audio.
        case gap(Int)
    }

    let channel: Channel
    private let file: AVAudioFile?
    private let queue: DispatchQueue
    private let startHost: UInt64
    private var cursor = 0  // samples written to the timeline
    private var continuation: AsyncStream<Item>.Continuation?
    private var consumer: Task<Void, Never>?
    private(set) var level: Float = 0  // smoothed RMS for the UI meter
    private static let maxPaddedGap = 32_000  // 2 s; longer gaps skip ahead when there is no file to keep aligned

    init(channel: Channel, url: URL?, startHost: UInt64, transcriber: LiveTranscriber?) throws {
        self.channel = channel
        self.startHost = startHost
        self.queue = DispatchQueue(label: "minutes.channel.\(channel.rawValue)")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        file = try url.map {
            try AVAudioFile(forWriting: $0, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        if let transcriber {
            let (stream, continuation) = AsyncStream<Item>.makeStream(bufferingPolicy: .unbounded)
            self.continuation = continuation
            consumer = Task.detached(priority: .userInitiated) {
                for await item in stream {
                    switch item {
                    case .audio(let chunk): await transcriber.append(chunk)
                    case .gap(let samples): await transcriber.skip(samples)
                    }
                }
                await transcriber.finish()
            }
        }
    }

    private var closed = false

    /// Called from the capture queue.
    func receive(_ samples: [Float], hostTime: UInt64) {
        queue.async { [self] in
            guard !closed else { return }
            let expected = Int(HostTime.seconds(hostTime &- startHost) * 16_000)
            var chunk = samples
            if hostTime > startHost, expected > cursor + 1_600 {
                let missing = expected - cursor
                if file == nil, missing > Self.maxPaddedGap {
                    cursor += missing
                    continuation?.yield(.gap(missing))
                } else {
                    // More than 100 ms missing: pad so later audio lands at the right time.
                    chunk = [Float](repeating: 0, count: missing) + samples
                }
            }
            write(chunk)
            continuation?.yield(.audio(chunk))
            var sum: Float = 0
            for s in samples { sum += s * s }
            let rms = sqrt(sum / Float(max(samples.count, 1)))
            level = max(rms, level * 0.8)
        }
    }

    private func write(_ samples: [Float]) {
        guard !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(pcmFormat: MonoResampler.targetFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        if let file {
            do { try file.write(from: buffer) } catch { log.error("write failed: \(error.localizedDescription)") }
        }
        cursor += samples.count
    }

    var duration: Double { queue.sync { Double(cursor) / 16_000 } }

    /// Flushes pending audio and waits until the live transcriber has processed everything.
    func finish() async {
        queue.sync {}
        continuation?.finish()
        await consumer?.value
        queue.sync {
            closed = true
            file?.close()
        }
    }
}

/// Records a meeting: system audio ("Them") and microphone ("Me") to separate files, with live captions.
public final class RecordingSession: @unchecked Sendable {
    public let meeting: Meeting
    /// Recording part within the meeting (0 for a new meeting, n after resuming n times).
    public let part: Int
    /// Seconds from the meeting start to this part's start; live segments are shifted onto the meeting timeline.
    public let timeOffset: Double
    private let store: MeetingStore
    /// Replaced by a fresh instance when system audio is switched back on: the old one may still be tearing down.
    private var system = SystemAudioCapture()
    /// False with Data Protection: the process tap does not run, so the other participants are never captured.
    public private(set) var capturesSystemAudio: Bool
    private var themSink: AudioSink?
    private var systemStartedAt = Date()
    private let microphone = MicrophoneCapture()
    private var pipelines: [Channel: ChannelPipeline] = [:]
    private let onSegment: @Sendable (TranscriptSegment) -> Void
    private var watchdog: Timer?
    private let startedAt = Date()
    private var warnedSilence: Set<Channel> = []
    public private(set) var warnings: [String] = []
    /// Called on the main thread when a problem appears during recording (e.g. a silent channel).
    public var onWarning: (@Sendable (String) -> Void)?

    public init(
        meeting: Meeting, store: MeetingStore, part: Int = 0, timeOffset: Double = 0,
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void
    ) {
        self.meeting = meeting
        self.part = part
        self.timeOffset = timeOffset
        self.store = store
        self.onSegment = onSegment
        capturesSystemAudio = !meeting.isProtected
    }

    /// Data Protection switched during the recording: stops or restarts system-audio capture. Call on the main thread.
    public func setSystemAudio(_ on: Bool) {
        guard on != capturesSystemAudio, let sink = themSink else { return }
        capturesSystemAudio = on
        if on {
            system = SystemAudioCapture()
            systemStartedAt = Date()
            do {
                try system.start(sink: sink)
            } catch {
                warn("System audio unavailable: \(error.localizedDescription)")
            }
        } else {
            system.detach()
            let old = system
            DispatchQueue.global(qos: .utility).async { old.stop() }
        }
        log.info("system audio \(on ? "on" : "off (Data Protection)")")
    }

    /// Starts both captures. Live transcription is skipped when `asr`/`vad` are nil (e.g. models still downloading).
    public func start(asr: AsrEngine?, vad: VadManager?) async throws {
        let startHost = HostTime.now
        let store = store
        let meeting = meeting
        let onSegment = onSegment
        let offset = timeOffset
        let emit: LiveTranscriber.Emit = { segment in
            let shifted = segment.shifted(by: offset)
            store.appendLive(shifted, for: meeting)
            onSegment(shifted)
        }

        for channel in Channel.allCases {
            var transcriber: LiveTranscriber?
            if let asr, let vad { transcriber = await LiveTranscriber(channel: channel, asr: asr, vad: vad, emit: emit) }
            pipelines[channel] = try ChannelPipeline(
                channel: channel, url: store.file("\(MeetingStore.audioBaseName(channel, part: part)).caf", for: meeting),
                startHost: startHost, transcriber: transcriber)
        }

        // Microphone first: opening it can change the audio route, which must not happen while the tap is starting.
        // A pending permission prompt must not block system-audio capture, so in that case the mic starts later.
        let mePipeline = pipelines[.me]!
        let microphone = microphone
        let startMic: @Sendable () -> Void = { [weak self] in
            do {
                try microphone.start { samples, host in mePipeline.receive(samples, hostTime: host) }
            } catch {
                self?.warn("Microphone unavailable: \(error.localizedDescription)")
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startMic()
        case .notDetermined:
            log.info("waiting for microphone permission")
            Task {
                if await MicrophoneCapture.requestAccess() { startMic() } else { self.warn(Self.micDenied) }
            }
        default:
            warn(Self.micDenied)
        }
        let themPipeline = pipelines[.them]!
        let themSink: AudioSink = { samples, host in themPipeline.receive(samples, hostTime: host) }
        self.themSink = themSink
        if capturesSystemAudio {
            do {
                try system.start(sink: themSink)
            } catch {
                warnings.append("System audio unavailable: \(error.localizedDescription)")
            }
        }
        startWatchdog()
        log.info("recording started: \(self.meeting.folderName)\(self.capturesSystemAudio ? "" : " (Data Protection: microphone only)")")
    }

    /// The process tap can silently stop delivering buffers after sleep or route changes; rebuild it if so.
    private func startWatchdog() {
        DispatchQueue.main.async {
            self.watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                guard let self else { return }
                let last = self.system.lastBufferHostTime
                if self.capturesSystemAudio, last > 0, HostTime.seconds(HostTime.now &- last) > 5 {
                    log.warning("system audio stalled, restarting tap")
                    self.system.restart()
                }
                self.checkSilence()
            }
        }
    }

    /// A channel that has delivered only digital silence for a while almost always means a missing permission.
    private func checkSilence() {
        let age = Date().timeIntervalSince(startedAt)
        if age > 15, microphone.lastAudibleHostTime == 0, !warnedSilence.contains(.me) {
            warnedSilence.insert(.me)
            warn("The microphone is delivering silence. Check System Settings → Privacy & Security → Microphone for Minutes.")
        }
        let othersPlaying = CoreAudioUtils.processObjects.contains {
            CoreAudioUtils.processPID($0) != getpid() && CoreAudioUtils.processIsRunningOutput($0)
        }
        if capturesSystemAudio, Date().timeIntervalSince(systemStartedAt) > 20, system.lastAudibleHostTime == 0, othersPlaying,
            !warnedSilence.contains(.them)
        {
            warnedSilence.insert(.them)
            warn("System audio is silent although apps are playing sound. Allow Minutes under System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only.")
        }
    }

    static let micDenied =
        "Microphone access is off for Minutes. Enable it in System Settings → Privacy & Security → Microphone."

    private func warn(_ message: String) {
        log.warning(message)
        warnings.append(message)
        onWarning?(message)
    }

    public func level(_ channel: Channel) -> Float { pipelines[channel]?.level ?? 0 }

    public var elapsed: Double { pipelines[.me]?.duration ?? 0 }

    /// Stops capture and waits until live transcription has drained.
    public func stop() async {
        await MainActor.run {
            self.watchdog?.invalidate()
            self.watchdog = nil
        }
        microphone.stop()
        // Tearing down the tap can block for minutes when Core Audio hangs (seen when a Bluetooth headset
        // disconnected mid-call). Stop forwarding audio now and tear down in the background.
        system.detach()
        let system = system
        DispatchQueue.global(qos: .utility).async { system.stop() }
        for pipeline in pipelines.values { await pipeline.finish() }
        log.info("recording stopped: \(self.meeting.folderName)")
    }
}
