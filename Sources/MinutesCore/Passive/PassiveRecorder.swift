import AVFoundation
import FluidAudio
import Foundation

private let log = MinutesLog("Passive")

/// Passive mode's capture: microphone and system audio all day, transcribed on the fly, stored as text only.
///
/// Compared with a meeting `RecordingSession`: no audio file is written (audio lives only in memory until its
/// utterance is transcribed), partial captions are normally off (each utterance is transcribed once, when it ends), a
/// Bluetooth headset's microphone is avoided (opening it would switch the headset to its call profile all day),
/// and microphone utterances that merely repeat what the speakers played are dropped before they are stored.
///
/// Storing is slow on purpose (a microphone utterance waits 30 s for the echo check) because the digest only runs
/// every few minutes. For a person watching the transcript, `onPreview` reports each utterance right away: while it
/// is still being spoken (only with `setLivePreview(true)`, which costs extra transcription work), and when it has
/// ended but is not stored yet. A stored entry has the same id as its previews.
public final class PassiveRecorder: @unchecked Sendable {
    public typealias OnEntry = @Sendable (DayEntry) -> Void
    public typealias OnPreview = @Sendable (Preview) -> Void

    /// A line that is not in the day's transcript yet. Empty `text` means: remove the preview with this id
    /// (it was dropped as speaker echo, forgotten, or turned out to be empty).
    public struct Preview: Sendable, Identifiable, Equatable {
        public let id: UUID
        public let channel: Channel
        public let start: Date
        public let text: String
        /// false while the utterance is still being spoken.
        public let ended: Bool

        public init(id: UUID, channel: Channel, start: Date, text: String, ended: Bool) {
            self.id = id
            self.channel = channel
            self.start = start
            self.text = text
            self.ended = ended
        }
    }

    private let store: DayStore
    private let onEntry: OnEntry
    private let onPreview: OnPreview?
    /// Seconds between partial transcriptions of a running utterance while live preview is on (meetings use 1.5 s).
    private static let previewInterval = 2.0
    private let system = SystemAudioCapture()
    private let microphone = MicrophoneCapture()
    private var pipelines: [Channel: ChannelPipeline] = [:]
    private var transcribers: [LiveTranscriber] = []
    private var startHost: UInt64 = 0
    private let queue = DispatchQueue(label: "minutes.passive")
    private var watchdog: DispatchSourceTimer?
    private var lastTapRestart: UInt64 = 0
    /// Microphone segments wait here until any system-audio segment they could be an echo of has arrived.
    private var pendingMic: [TranscriptSegment] = []
    private var recentSystem: [TranscriptSegment] = []
    /// A system segment can end up to the transcriber's 28 s limit after a matching mic segment.
    private static let echoHold = 30.0
    public private(set) var warnings: [String] = []

    /// Which streams to capture (both in the app; the CLI can pick one to measure each stream's cost).
    public let channels: Set<Channel>

    public init(
        store: DayStore, channels: Set<Channel> = Set(Channel.allCases), onPreview: OnPreview? = nil,
        onEntry: @escaping OnEntry
    ) {
        self.store = store
        self.channels = channels
        self.onPreview = onPreview
        self.onEntry = onEntry
        microphone.avoidBluetooth = true
        // Measured on an M5 Pro in silence: the default 512-frame buffers cost 4.4 % of a core in coreaudiod plus
        // 1.8 % here; 4096 frames (the built-in mic's maximum, 85 ms) halve both. Latency does not matter here.
        microphone.bufferFrames = Self.bufferFrames
        system.bufferFrames = Self.bufferFrames
    }

    static let bufferFrames: UInt32 = 4096

    /// Starts the captures. Throws if the microphone is needed but not authorized.
    /// With `capture: false` nothing is recorded; audio comes from `feed` (tests play files through the pipeline).
    public func start(asr: AsrEngine, vad: VadManager, capture: Bool = true) async throws {
        if capture, channels.contains(.me), AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            throw CaptureError.microphone("microphone access is not granted")
        }
        startHost = HostTime.now
        let emit: LiveTranscriber.Emit = { [weak self] segment in
            self?.queue.async { self?.received(segment) }
        }
        for channel in Channel.allCases where channels.contains(channel) {
            let transcriber = await LiveTranscriber(
                channel: channel, asr: asr, vad: vad, partials: false, partialInterval: Self.previewInterval, emit: emit)
            transcribers.append(transcriber)
            pipelines[channel] = try ChannelPipeline(channel: channel, url: nil, startHost: startHost, transcriber: transcriber)
        }
        capturing = capture
        guard capture else {
            startTimer()
            return
        }
        if let me = pipelines[.me] {
            try microphone.start { samples, host in me.receive(samples, hostTime: host) }
        }
        if let them = pipelines[.them] {
            do {
                try system.start { samples, host in them.receive(samples, hostTime: host) }
            } catch {
                warnings.append("System audio unavailable: \(error.localizedDescription)")
                log.warning("system audio unavailable: \(error.localizedDescription)")
            }
        }
        startTimer()
        log.info("passive capture started (mic: \(microphone.deviceName ?? "?"))")
    }

    /// Stops capture, transcribes what is still buffered and stores the remaining segments.
    public func stop() async {
        watchdog?.cancel()
        watchdog = nil
        if capturing, channels.contains(.me) { microphone.stop() }
        if capturing, channels.contains(.them) {
            system.detach()
            let system = system
            DispatchQueue.global(qos: .utility).async { system.stop() }
        }
        for pipeline in pipelines.values { await pipeline.finish() }
        queue.sync { flushMic(force: true) }
        let s = await stats()
        log.info(
            "passive capture stopped: \(Int(s.audioSeconds)) s audio, \(s.segments) utterances, VAD \(s.vadCalls) calls (\(s.silentHopsSkipped) silent hops skipped), ASR \(s.asrCalls) calls, \(String(format: "%.1f", s.asrBusySeconds)) s busy")
    }

    /// Work done by both channels' transcribers.
    public func stats() async -> LiveTranscriber.Stats {
        var total = LiveTranscriber.Stats()
        for t in transcribers {
            let s = await t.stats
            total.audioSeconds += s.audioSeconds
            total.vadCalls += s.vadCalls
            total.silentHopsSkipped += s.silentHopsSkipped
            total.asrCalls += s.asrCalls
            total.asrAudioSeconds += s.asrAudioSeconds
            total.asrBusySeconds += s.asrBusySeconds
            total.segments += s.segments
        }
        return total
    }

    private var capturing = true

    /// Audio for a channel when started with `capture: false` (16 kHz mono, stamped with the current host time).
    public func feed(_ channel: Channel, samples: [Float]) {
        pipelines[channel]?.receive(samples, hostTime: HostTime.now)
    }

    /// Turns partial transcription of running utterances on or off. On costs about as much as a meeting's live
    /// transcript, so the app enables it only while today's transcript is on screen.
    public func setLivePreview(_ on: Bool) async {
        for t in transcribers { await t.setPartials(on) }
    }

    // MARK: Segments

    /// Seconds on the capture timeline right now (host time does not advance during sleep, like the timeline).
    private var timelineNow: Double { HostTime.seconds(HostTime.now &- startHost) }

    /// Wall-clock time of a timeline position, relative to now, which stays correct across a sleep.
    private func wallClock(_ seconds: Double) -> Date { Date().addingTimeInterval(seconds - timelineNow) }

    private func received(_ segment: TranscriptSegment) {
        guard segment.isFinal else { return preview(segment, ended: false) }
        // An empty final follows a partial that turned out to be nothing.
        guard !segment.text.isEmpty else { return removePreview(segment.id) }
        switch segment.channel {
        case .them:
            recentSystem.append(segment)
            save(segment)
        case .me:
            pendingMic.append(segment)
            preview(segment, ended: true)
        }
    }

    private func preview(_ segment: TranscriptSegment, ended: Bool) {
        guard !segment.text.isEmpty else { return }
        onPreview?(Preview(id: segment.id, channel: segment.channel, start: wallClock(segment.start), text: segment.text, ended: ended))
    }

    private func removePreview(_ id: UUID) {
        onPreview?(Preview(id: id, channel: .me, start: Date(), text: "", ended: true))
    }

    /// Drops waiting microphone utterances that already match what the Mac played, so their preview disappears
    /// within seconds instead of after the full hold. (More system audio can only make a match stronger.)
    private func dropKnownEchoes() {
        guard !pendingMic.isEmpty, !recentSystem.isEmpty else { return }
        let kept = FinalTranscriber.removeEcho(me: pendingMic, them: recentSystem)
        guard kept.count < pendingMic.count else { return }
        log.info("dropped \(pendingMic.count - kept.count) mic utterance(s) as speaker echo")
        for seg in pendingMic where !kept.contains(where: { $0.id == seg.id }) { removePreview(seg.id) }
        pendingMic = kept
    }

    private func flushMic(force: Bool) {
        dropKnownEchoes()
        let now = timelineNow
        let ready = pendingMic.filter { force || now - $0.end > Self.echoHold }
        guard !ready.isEmpty else { return }
        pendingMic.removeAll { seg in ready.contains { $0.id == seg.id } }
        let kept = FinalTranscriber.removeEcho(me: ready, them: recentSystem)
        if kept.count < ready.count {
            log.info("dropped \(ready.count - kept.count) mic utterance(s) as speaker echo")
            for seg in ready where !kept.contains(where: { $0.id == seg.id }) { removePreview(seg.id) }
        }
        for seg in kept { save(seg) }
        recentSystem.removeAll { now - $0.end > Self.echoHold * 2 }
    }

    /// Drops utterances that overlap a window the user asked to forget, including those still being transcribed
    /// or held for the echo check when the user clicked.
    public func forget(from start: Date, to end: Date) {
        queue.async { self.forgotten.append((start, end)) }
    }

    private var forgotten: [(Date, Date)] = []

    private func save(_ segment: TranscriptSegment) {
        let entry = DayEntry(
            id: segment.id, start: wallClock(segment.start), end: wallClock(segment.end), channel: segment.channel,
            text: segment.text)
        if forgotten.contains(where: { entry.end > $0.0 && entry.start < $0.1 }) { return removePreview(segment.id) }
        store.append(entry)
        onEntry(entry)
    }

    // MARK: Timer

    /// Every 2 s: release mic segments that can no longer be echoes; rebuild the tap if it stalled (at most once a minute).
    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.flushMic(force: false)
            let last = self.system.lastBufferHostTime
            if self.capturing, last > 0, HostTime.seconds(HostTime.now &- last) > 5,
                HostTime.seconds(HostTime.now &- self.lastTapRestart) > 60
            {
                log.warning("system audio stalled, restarting tap")
                self.lastTapRestart = HostTime.now
                self.system.restart()
            }
        }
        timer.resume()
        watchdog = timer
    }
}
