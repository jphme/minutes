import FluidAudio
import Foundation
import os

private let log = MinutesLog("FinalTranscriber")

/// Post-meeting pass: re-transcribes each channel in full (best context, word timings), splits the
/// system-audio channel into speakers with offline diarization (pyannote community-1 + VBx on the ANE),
/// removes loudspeaker echo from the microphone channel, and merges everything into one transcript.
public actor FinalTranscriber {
    public struct Result: Sendable {
        public var segments: [TranscriptSegment]
        /// Mean voice embedding per diarized speaker label, stored for recognizing people across meetings later.
        public var speakerEmbeddings: [String: [Float]]
        public var timings: [String: Double]
    }

    public enum Stage: Sendable { case transcribingMe, transcribingThem, diarizing, merging }

    private let asr: AsrEngine
    private var diarizer: OfflineDiarizerManager?

    public init(asr: AsrEngine) {
        self.asr = asr
    }

    public func process(
        meAudio: URL?, themAudio: URL?, progress: (@Sendable (Stage) -> Void)? = nil
    ) async throws -> Result {
        var timings: [String: Double] = [:]
        var segments: [TranscriptSegment] = []
        var embeddings: [String: [Float]] = [:]

        var meSegments: [TranscriptSegment] = []
        var meWords: [AsrWord] = []
        if let meAudio, Self.hasAudio(meAudio) {
            progress?(.transcribingMe)
            let t = Date()
            let out = try await asr.transcribeFile(meAudio)
            timings["asr_me"] = Date().timeIntervalSince(t)
            meWords = out.words
        }

        var themSegments: [TranscriptSegment] = []
        if let themAudio, Self.hasAudio(themAudio) {
            progress?(.transcribingThem)
            var t = Date()
            let out = try await asr.transcribeFile(themAudio)
            timings["asr_them"] = Date().timeIntervalSince(t)

            progress?(.diarizing)
            t = Date()
            var turns: [(speaker: String, start: Double, end: Double)] = []
            do {
                let diarizer = try await loadDiarizer()
                let result = try await diarizer.process(themAudio)
                let labels = Self.speakerLabels(result.segments)
                turns = result.segments.map {
                    (labels[$0.speakerId] ?? $0.speakerId, Double($0.startTimeSeconds), Double($0.endTimeSeconds))
                }
                for (id, vector) in result.speakerDatabase ?? [:] {
                    if let label = labels[id] { embeddings[label] = vector }
                }
            } catch {
                log.error("diarization failed, falling back to a single remote speaker: \(error.localizedDescription)")
            }
            timings["diarization"] = Date().timeIntervalSince(t)
            themSegments = Self.assignSpeakers(out.words, turns: turns)
        }

        // The microphone usually holds only the user, but in an in-person meeting everyone in the room is on it.
        // Diarize it too; when several people talk, the one with the most speech is "Me".
        if let meAudio, !meWords.isEmpty {
            progress?(.diarizing)
            let t = Date()
            var turns: [(speaker: String, start: Double, end: Double)] = []
            do {
                let diarizer = try await loadDiarizer()
                let result = try await diarizer.process(meAudio)
                let nextNumber = Set(themSegments.map(\.speaker)).filter { $0.hasPrefix("Speaker ") }.count + 1
                turns = Self.micTurns(result.segments, nextSpeakerNumber: nextNumber)
            } catch {
                log.error("microphone diarization failed: \(error.localizedDescription)")
            }
            timings["diarization_me"] = Date().timeIntervalSince(t)
            meSegments = Self.assignSpeakers(meWords, turns: turns, channel: .me)
        }

        progress?(.merging)
        meSegments = Self.removeEcho(me: meSegments, them: themSegments)
        segments = (meSegments + themSegments).sorted { $0.start < $1.start }
        return Result(segments: segments, speakerEmbeddings: embeddings, timings: timings)
    }

    private func loadDiarizer() async throws -> OfflineDiarizerManager {
        if let diarizer { return diarizer }
        // Exclusive segments: one speaker per instant, which is what word attribution needs.
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig(exclusiveSegments: true))
        try await manager.prepareModels()
        diarizer = manager
        return manager
    }

    // MARK: - Pure helpers (static so they are easy to test)

    /// True if the file exists and has more than a trivial amount of audio.
    static func hasAudio(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? Int
        else { return false }
        return size > 64_000  // > ~1 s of 16 kHz 16-bit audio plus header
    }

    /// Labels microphone diarization: one speaker (or others with little speech) → everything "Me"; otherwise the
    /// speaker with the most speech is "Me" and the rest get numbers after the remote speakers.
    static func micTurns(
        _ segments: [TimedSpeakerSegment], nextSpeakerNumber: Int
    ) -> [(speaker: String, start: Double, end: Double)] {
        var talk: [String: Double] = [:]
        for s in segments { talk[s.speakerId, default: 0] += Double(s.durationSeconds) }
        let total = talk.values.reduce(0, +)
        guard let me = talk.max(by: { $0.value < $1.value })?.key, total > 0 else { return [] }
        // Speakers below 10 % of speech and 15 s are usually echo, TV or misclustering: fold them into "Me".
        let others = talk.filter { $0.key != me && ($0.value / total >= 0.10 || $0.value >= 15) }
        guard !others.isEmpty else { return [] }
        var labels: [String: String] = [me: "Me"]
        var n = nextSpeakerNumber
        for s in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) where labels[s.speakerId] == nil {
            if others[s.speakerId] != nil {
                labels[s.speakerId] = "Speaker \(n)"
                n += 1
            } else {
                labels[s.speakerId] = "Me"
            }
        }
        return segments.map { (labels[$0.speakerId] ?? "Me", Double($0.startTimeSeconds), Double($0.endTimeSeconds)) }
    }

    /// "Speaker 1", "Speaker 2", ... in order of first appearance.
    static func speakerLabels(_ segments: [TimedSpeakerSegment]) -> [String: String] {
        var labels: [String: String] = [:]
        for seg in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) where labels[seg.speakerId] == nil {
            labels[seg.speakerId] = "Speaker \(labels.count + 1)"
        }
        return labels
    }

    /// Splits a word stream into utterances at pauses, or at sentence ends once an utterance gets long.
    static func groupByPauses(
        _ words: [AsrWord], channel: Channel, speaker: String, pause: Double = 1.0, maxLength: Double = 30
    ) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: [AsrWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(
                TranscriptSegment(
                    channel: channel, speaker: speaker, start: first.start, end: last.end,
                    text: current.map(\.text).joined(separator: " "), words: current))
            current.removeAll()
        }
        for word in words {
            if let last = current.last, let first = current.first {
                let gap = word.start - last.end
                let sentenceEnd = last.text.last.map { ".?!".contains($0) } ?? false
                if gap >= pause || (word.start - first.start > maxLength && sentenceEnd) || (gap > 0.4 && sentenceEnd && word.start - first.start > 12) {
                    flush()
                }
            }
            current.append(word)
        }
        flush()
        return segments
    }

    /// Assigns each word to the diarization turn it overlaps most (nearest turn if none), then groups runs.
    static func assignSpeakers(
        _ words: [AsrWord], turns: [(speaker: String, start: Double, end: Double)], channel: Channel = .them
    ) -> [TranscriptSegment] {
        guard !turns.isEmpty, !words.isEmpty else {
            return groupByPauses(words, channel: channel, speaker: channel == .me ? "Me" : "Them")
        }
        let sorted = turns.sorted { $0.start < $1.start }
        var labels: [String] = words.map { word in
            var best: (String, Double)?
            for turn in sorted {
                if turn.start > word.end + 2 { break }
                let overlap = min(turn.end, word.end) - max(turn.start, word.start)
                let distance = overlap > 0 ? -overlap : min(abs(turn.start - word.end), abs(word.start - turn.end))
                if best == nil || distance < best!.1 { best = (turn.speaker, distance) }
            }
            return best?.0 ?? sorted.min(by: { abs($0.start - word.start) < abs($1.start - word.start) })!.speaker
        }
        smoothBoundaries(words, &labels)

        var segments: [TranscriptSegment] = []
        var runStart = 0
        for i in 1...words.count where i == words.count || labels[i] != labels[runStart] {
            segments += groupByPauses(Array(words[runStart..<i]), channel: channel, speaker: labels[runStart])
            runStart = i
        }
        return segments
    }

    /// Diarization turn edges are often off by a word or two ("…an answer? Not | yet."). Moves each speaker
    /// change to the nearest sentence end within two words, preferring the position with the longest pause.
    static func smoothBoundaries(_ words: [AsrWord], _ labels: inout [String]) {
        func endsSentence(_ i: Int) -> Bool { words[i].text.last.map { ".?!".contains($0) } ?? false }
        func pause(after i: Int) -> Double { i + 1 < words.count ? words[i + 1].start - words[i].end : 0 }
        var i = 1
        while i < words.count {
            defer { i += 1 }
            guard labels[i] != labels[i - 1], !endsSentence(i - 1) else { continue }
            // Candidates: last word of the old speaker moves to index c (boundary after c).
            let candidates = (max(0, i - 3)...min(words.count - 2, i + 1)).filter { endsSentence($0) }
            guard let c = candidates.max(by: { pause(after: $0) < pause(after: $1) }) else { continue }
            let old = labels[i - 1]
            let new = labels[i]
            if c < i - 1 {
                for k in (c + 1)..<i { labels[k] = new }
            } else if c >= i {
                for k in i...c { labels[k] = old }
            }
        }
    }

    /// Drops microphone segments that are the remote side leaking from loudspeakers into the mic:
    /// they overlap remote speech in time and repeat most of its words.
    static func removeEcho(me: [TranscriptSegment], them: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !them.isEmpty else { return me }
        return me.filter { seg in
            let window = them.filter { $0.end >= seg.start - 1.5 && $0.start <= seg.end + 1.5 }
            guard !window.isEmpty else { return true }
            let mine = normalizedWords(seg.text)
            guard !mine.isEmpty else { return false }
            let theirs = Set(window.flatMap { normalizedWords($0.text) })
            let shared = mine.filter { theirs.contains($0) }.count
            return Double(shared) / Double(mine.count) < 0.6
        }
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
