import AVFoundation
import Foundation
import os

private let log = MinutesLog("Processor")

/// Everything that happens after a recording stops: final transcript, speaker split, audio compression, summary.
public actor MeetingProcessor {
    public enum Progress: Sendable {
        case stage(String)
        case summaryDelta(String)
    }

    private let store: MeetingStore
    private let asr: AsrEngine
    private let final: FinalTranscriber

    public init(store: MeetingStore, asr: AsrEngine) {
        self.store = store
        self.asr = asr
        self.final = FinalTranscriber(asr: asr)
    }

    /// Runs the post-meeting transcription and then the summary. Errors are recorded on the meeting.
    public func process(
        _ meeting: Meeting, settings: AppSettings, onlyPending: Bool = false,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async -> Meeting {
        var m = meeting
        do {
            m = try await transcribe(m, settings: settings, onlyPending: onlyPending, progress: progress)
        } catch {
            log.error("final transcription failed: \(error.localizedDescription)")
            m.status = .failed
            m.error = "Transcription failed: \(error.localizedDescription)"
            try? store.save(m)
            return m
        }
        let hasTranscript = !store.loadTranscript(for: m).isEmpty
        if settings.llmProvider != .none, Keychain.hasKey, hasTranscript {
            do {
                m = try await summarize(m, settings: settings, progress: progress)
            } catch {
                log.error("summary failed: \(error.localizedDescription)")
                m.error = "Summary failed: \(error.localizedDescription)"
            }
        } else if m.calendarEventTitle == nil, Self.isGenericTitle(m.title) {
            // Without notes there is no generated title: name the meeting by its start time instead.
            m = (try? store.rename(m, to: Self.dateTitle(m.startedAt))) ?? m
        }
        m.status = .done
        try? store.save(m)
        return m
    }

    /// Final transcript for every part that has audio. With `onlyPending`, parts already transcribed keep their
    /// segments (used after resuming a meeting, where the first part's audio may already be deleted).
    public func transcribe(
        _ meeting: Meeting, settings: AppSettings, onlyPending: Bool = false,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Meeting {
        var m = meeting
        m.status = .processing
        m.error = nil
        m.asrModel = settings.asrModel.rawValue
        try store.save(m)
        await asr.configureVocabulary(file: AppPaths.vocabulary)

        var parts = m.allParts
        if m.isProtected {
            // Data Protection switched on during the recording: system audio from before the switch is deleted unheard.
            for i in parts.indices {
                for ext in ["caf", "wav", "m4a"] {
                    try? FileManager.default.removeItem(at: store.file("\(MeetingStore.audioBaseName(.them, part: i)).\(ext)", for: m))
                }
            }
        }
        let existing = store.loadFinalTranscript(for: m) ?? []
        var embeddings = store.loadSpeakerEmbeddings(for: m)
        var segments: [TranscriptSegment] = []
        for i in parts.indices {
            let offset = m.offset(ofPart: i)
            let nextOffset = i + 1 < parts.count ? m.offset(ofPart: i + 1) : .infinity
            let me = store.audioURL(.me, for: m, part: i)
            let them = store.audioURL(.them, for: m, part: i)
            guard me != nil || them != nil, !(onlyPending && parts[i].transcribed) else {
                segments += existing.filter { $0.start >= offset - 1 && $0.start < nextOffset - 1 }
                continue
            }
            let label = parts.count > 1 ? " (part \(i + 1) of \(parts.count))" : ""
            let result = try await final.process(meAudio: me, themAudio: them) { stage in
                let text: String
                switch stage {
                case .transcribingMe: text = "Transcribing your microphone…"
                case .transcribingThem: text = "Transcribing other participants…"
                case .diarizing: text = "Separating speakers…"
                case .merging: text = "Merging transcript…"
                }
                progress?(.stage(text + label))
            }
            log.info("final pass timings\(label): \(result.timings)")
            let mapping = SpeakerMatcher.mapping(
                newLabels: result.segments.map(\.speaker), newEmbeddings: result.speakerEmbeddings,
                existingLabels: Set(segments.map(\.speaker)), existingEmbeddings: &embeddings)
            segments += result.segments.map { seg in
                var s = seg.shifted(by: offset)
                s.speaker = mapping[s.speaker] ?? s.speaker
                return s
            }
            parts[i].transcribed = true
        }
        if m.isProtected { segments.removeAll { $0.channel == .them } }
        segments.sort { $0.start < $1.start }
        if m.parts != nil { m.parts = parts }
        try store.saveTranscript(segments, for: m)
        if !embeddings.isEmpty { try? store.saveSpeakerEmbeddings(embeddings, for: m) }
        progress?(.stage(settings.keepAudio ? "Compressing audio…" : "Deleting audio…"))
        compressAudio(m, keep: settings.keepAudio)
        m.status = .summarizing
        try store.save(m)
        return m
    }

    /// Generates the notes without saving them (used by `summarize` and by model comparisons).
    public func generateNotes(
        _ meeting: Meeting, settings: AppSettings, model: String? = nil, effort: String? = nil,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> (output: Summarizer.Output, completion: AnthropicClient.Completion) {
        let segments = store.loadTranscript(for: meeting)
        guard !segments.isEmpty else { throw AnthropicError.emptyTranscript }
        guard settings.llmProvider == .anthropic else { throw AnthropicError.missingKey }
        guard let key = Keychain.resolvedAPIKey() else { throw AnthropicError.missingKey }
        let model = model ?? AppSettings.summaryModel
        let client = AnthropicClient(apiKey: key, model: model, effort: effort ?? AppSettings.summaryEffort)
        let input = Summarizer.Input(
            meeting: meeting, segments: segments, userNotes: store.read("notes.md", for: meeting) ?? "",
            context: Summarizer.background(settings: settings),
            vocabulary: AppPaths.vocabularyTerms().map(\.term), language: settings.summaryLanguage)
        progress?(.stage("Writing notes…"))
        let messages = Summarizer.messages(for: input)
        let completion = try await client.complete(system: messages.system, user: messages.user) { delta in
            progress?(.summaryDelta(delta))
        }
        log.info(
            "notes generated in \(String(format: "%.1f", completion.seconds)) s with \(completion.model): \(completion.inputTokens) in / \(completion.outputTokens) out tokens, $\(String(format: "%.4f", completion.costUSD))")
        return (Summarizer.parse(completion.text), completion)
    }

    public func summarize(
        _ meeting: Meeting, settings: AppSettings, progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Meeting {
        var m = meeting
        let (parsed, completion) = try await generateNotes(m, settings: settings, progress: progress)
        try store.write(parsed.markdown + "\n", to: "summary.md", for: m)
        m.summaryModel = completion.model
        if let title = parsed.title, m.calendarEventTitle == nil, Self.isGenericTitle(m.title) {
            m = try store.rename(m, to: title)
        }
        try store.save(m)
        return m
    }

    /// "Meeting 9 Nov 2026, 16:38" in the user's locale.
    static func dateTitle(_ date: Date) -> String {
        "Meeting " + date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }

    public static func isGenericTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.hasSuffix("meeting") || lower.hasSuffix("call") || lower.hasPrefix("meeting")
            || lower.hasPrefix("recording") || lower.hasSuffix("huddle")
    }

    /// Replaces the CAF recordings with AAC (about 15 MB per hour per channel), or deletes all audio of the meeting
    /// when recordings are not kept (the default: only the transcript is stored).
    nonisolated func compressAudio(_ meeting: Meeting, keep: Bool) {
        for part in meeting.allParts.indices {
            for channel in Channel.allCases { compress(meeting, channel: channel, part: part, keep: keep) }
        }
    }

    private nonisolated func compress(_ meeting: Meeting, channel: Channel, part: Int, keep: Bool) {
        let base = MeetingStore.audioBaseName(channel, part: part)
        if !keep {
            for ext in ["caf", "wav", "m4a"] { try? FileManager.default.removeItem(at: store.file("\(base).\(ext)", for: meeting)) }
            return
        }
        let caf = store.file("\(base).caf", for: meeting)
        guard FileManager.default.fileExists(atPath: caf.path) else { return }
        let m4a = store.file("\(base).m4a", for: meeting)
        do {
            try Self.encodeAAC(from: caf, to: m4a)
            try FileManager.default.removeItem(at: caf)
        } catch {
            log.error("AAC encoding failed, keeping CAF: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: m4a)
        }
    }

    static func encodeAAC(from source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: input.fileFormat.sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
        ]
        let output = try AVAudioFile(
            forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65_536) else { return }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }
}
