import FluidAudio
import Foundation
import os

private let log = MinutesLog("LiveTranscriber")

/// Turns one channel's continuous 16 kHz stream into transcript segments while the meeting runs.
///
/// Silero VAD (256 ms hops) finds utterances; each utterance is transcribed with the batch ASR model when
/// it ends, and re-transcribed every ~1.5 s while it is still going so captions appear quickly. Batch
/// models on short utterances are both more accurate than streaming models and cheap on the ANE
/// (about 50 ms for 10 s of audio), so system load stays low.
public actor LiveTranscriber {
    public typealias Emit = @Sendable (TranscriptSegment) -> Void

    private let channel: Channel
    private let asr: AsrEngine
    private let vad: VadManager
    private let emit: Emit

    private static let rate = 16_000
    private static let hop = 4_096  // 256 ms, the Silero model's native window
    private let speechThreshold: Float = 0.5
    private let silenceThreshold: Float = 0.35
    private let endSilenceHops = 2  // ~0.5 s of silence closes an utterance
    private let prerollHops = 2
    private let softMaxSeconds = 12.0  // split at the next quiet hop after this
    private let hardMaxSeconds = 28.0
    private let partialInterval: Double

    private var vadState: VadStreamState
    private var pending: [Float] = []
    private var processedSamples = 0  // timeline position of the start of `pending`
    private var preroll: [[Float]] = []
    private var speech: [Float] = []
    private var speechStartSample = 0
    private var silentHops = 0
    private var segmentID = UUID()
    private var lastPartialSamples = 0
    private var inSpeech = false
    /// Partial captions re-transcribe the growing utterance every `partialInterval` seconds. Passive mode keeps
    /// them off to save work and turns them on only while someone watches the transcript.
    private var partials: Bool

    public func setPartials(_ on: Bool) { partials = on }

    /// Work done so far, for energy accounting (passive mode logs it; the CLI prints it).
    public struct Stats: Sendable {
        public var audioSeconds = 0.0
        public var vadCalls = 0
        /// Hops skipped without running the VAD because they were digital silence (e.g. nothing playing).
        public var silentHopsSkipped = 0
        public var asrCalls = 0
        public var asrAudioSeconds = 0.0
        /// Wall time spent waiting for the ASR model (mostly Neural Engine time).
        public var asrBusySeconds = 0.0
        public var segments = 0
    }
    public private(set) var stats = Stats()

    public init(
        channel: Channel, asr: AsrEngine, vad: VadManager, partials: Bool = true, partialInterval: Double = 1.5,
        emit: @escaping Emit
    ) async {
        self.channel = channel
        self.asr = asr
        self.vad = vad
        self.partials = partials
        self.partialInterval = partialInterval
        self.emit = emit
        self.vadState = await vad.makeStreamState()
    }

    /// Appends audio that continues the channel timeline (gaps must already be filled with zeros).
    public func append(_ samples: [Float]) async {
        pending.append(contentsOf: samples)
        while pending.count >= Self.hop {
            let chunk = Array(pending.prefix(Self.hop))
            pending.removeFirst(Self.hop)
            await process(chunk)
            processedSamples += Self.hop
        }
    }

    /// Moves the timeline forward without audio (a long gap in delivery); closes the utterance in progress first.
    public func skip(_ samples: Int) async {
        let buffered = pending.count
        await finish()
        processedSamples += buffered + samples
        pending.removeAll()
        preroll.removeAll()
        vadState = await vad.makeStreamState()
    }

    /// Flushes the utterance in progress (call when recording stops).
    public func finish() async {
        if inSpeech {
            speech.append(contentsOf: pending)
            pending.removeAll()
            await closeSegment()
        }
    }

    private func process(_ chunk: [Float]) async {
        stats.audioSeconds += Double(chunk.count) / Double(Self.rate)
        var probability: Float = 0
        // Digital silence (a tap with nothing playing, a muted mic) cannot be speech: skip the model.
        if chunk.contains(where: { abs($0) > 1e-5 }) {
            do {
                stats.vadCalls += 1
                let result = try await vad.processStreamingChunk(chunk, state: vadState)
                vadState = result.state
                probability = result.probability
            } catch {
                log.error("VAD failed: \(error.localizedDescription)")
            }
        } else {
            stats.silentHopsSkipped += 1
        }

        if !inSpeech {
            if probability >= speechThreshold {
                inSpeech = true
                segmentID = UUID()
                speech = preroll.flatMap { $0 } + chunk
                speechStartSample = processedSamples - preroll.count * Self.hop
                silentHops = 0
                lastPartialSamples = 0
                preroll.removeAll()
            } else {
                preroll.append(chunk)
                if preroll.count > prerollHops { preroll.removeFirst() }
            }
            return
        }

        speech.append(contentsOf: chunk)
        silentHops = probability < silenceThreshold ? silentHops + 1 : 0
        let seconds = Double(speech.count) / Double(Self.rate)

        if silentHops >= endSilenceHops
            || (seconds >= softMaxSeconds && probability < speechThreshold)
            || seconds >= hardMaxSeconds
        {
            await closeSegment()
        } else if partials, Double(speech.count - lastPartialSamples) / Double(Self.rate) >= partialInterval {
            lastPartialSamples = speech.count
            await transcribe(final: false)
        }
    }

    private func closeSegment() async {
        // Drop trailing silence beyond one hop so timestamps end near the last word.
        let trailing = max(0, silentHops - 1) * Self.hop
        if trailing > 0, trailing < speech.count { speech.removeLast(trailing) }
        await transcribe(final: true)
        inSpeech = false
        speech.removeAll()
        silentHops = 0
    }

    private func transcribe(final: Bool) async {
        // Bursts under 0.4 s are usually clicks or breaths; shorter audio is padded to 1 s for the model.
        guard speech.count >= Self.rate * 2 / 5 else { return }
        do {
            var audio = speech
            if audio.count < Self.rate { audio += [Float](repeating: 0, count: Self.rate - audio.count) }
            let asrStart = Date()
            let out = try await asr.transcribe(audio)
            stats.asrCalls += 1
            stats.asrAudioSeconds += Double(audio.count) / Double(Self.rate)
            stats.asrBusySeconds += Date().timeIntervalSince(asrStart)
            if final { stats.segments += 1 }
            let text = out.text
            // An empty final still goes out so the consumer can drop an earlier partial with this id.
            guard !text.isEmpty || (final && lastPartialSamples > 0) else { return }
            let start = Double(speechStartSample) / Double(Self.rate)
            let words = out.words.map {
                AsrWord(text: $0.text, start: $0.start + start, end: $0.end + start, confidence: $0.confidence)
            }
            emit(
                TranscriptSegment(
                    id: segmentID, channel: channel, speaker: channel == .me ? "Me" : "Them",
                    start: start, end: start + Double(speech.count) / Double(Self.rate),
                    text: text, words: words, isFinal: final))
        } catch {
            log.error("ASR failed: \(error.localizedDescription)")
        }
    }
}
