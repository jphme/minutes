import AVFoundation
import FluidAudio
import Foundation

private let log = MinutesLog("ASR")

/// Speech recognition models the app can run. All run locally through FluidAudio (CoreML, mostly on the ANE).
public enum AsrModelKind: String, CaseIterable, Codable, Sendable {
    /// NVIDIA Parakeet TDT 0.6B v3, 25 European languages with automatic language detection.
    case parakeetV3 = "parakeet-v3"
    /// moondream's post-training of Parakeet v3 (same API, more accurate per FluidAudio's FLEURS numbers).
    case parakeetUltra = "parakeet-ultra"
    /// NVIDIA Nemotron Unified ASR 0.6B, 25 European languages, language prompt "auto".
    case nemotronUnified = "nemotron-unified"

    public var displayName: String {
        switch self {
        case .parakeetV3: return "Parakeet TDT v3"
        case .parakeetUltra: return "Parakeet Ultra"
        case .nemotronUnified: return "Nemotron Unified 0.6B"
        }
    }
}

/// One recognized word with timing relative to the start of the transcribed audio.
public struct AsrWord: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Float

    public init(text: String, start: Double, end: Double, confidence: Float) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct AsrOutput: Sendable {
    public var text: String
    public var words: [AsrWord]
    public var processingTime: TimeInterval
}

/// Wraps the FluidAudio managers behind one interface so the rest of the app does not care which model runs.
public actor AsrEngine {
    public let kind: AsrModelKind
    private var parakeet: AsrManager?
    private var unified: UnifiedAsrManager?
    private var vocabularySession: VocabularyBoostingSession?
    private var vocabularySignature = ""
    private var vocabularyEntries: [(term: String, aliases: [String])] = []

    public init(kind: AsrModelKind) {
        self.kind = kind
    }

    public var isLoaded: Bool { parakeet != nil || unified != nil }

    /// Downloads the model on first use (to ~/Library/Application Support/FluidAudio/Models) and loads it.
    public func load() async throws {
        guard !isLoaded else { return }
        switch kind {
        case .parakeetV3, .parakeetUltra:
            let version: AsrModelVersion = kind == .parakeetV3 ? .v3 : .ultra
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            parakeet = manager
        case .nemotronUnified:
            let manager = UnifiedAsrManager(
                config: UnifiedConfig(family: .nemotronMultilingual(.auto)), encoderPrecision: .fp16)
            try await manager.loadModels()
            unified = manager
        }
    }

    /// Transcribes 16 kHz mono Float32 samples. Each call is independent (decoder state is not carried over).
    public func transcribe(_ samples: [Float]) async throws -> AsrOutput {
        try await load()
        let start = Date()
        let result: ASRResult
        if let parakeet {
            var state = TdtDecoderState.make(decoderLayers: await parakeet.decoderLayerCount)
            result = try await parakeet.transcribe(samples, decoderState: &state)
        } else if let unified {
            result = try await unified.transcribeDetailed(samples)
        } else {
            throw NSError(domain: "AsrEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "model not loaded"])
        }
        let words = Self.words(from: result.tokenTimings ?? [])
        return AsrOutput(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            words: words,
            processingTime: Date().timeIntervalSince(start))
    }

    /// Loads the custom vocabulary (vocabulary.txt format: "Term" or "Term: alias1, alias2") for the final pass.
    /// Uses FluidAudio's CTC keyword spotter (Parakeet CTC 110M) to replace misrecognized words where the audio
    /// supports the vocabulary term. Reloads only when the file changed; an empty file disables boosting.
    public func configureVocabulary(file: URL) async {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let hasTerms = text.split(separator: "\n").contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }
        guard hasTerms else {
            vocabularySession = nil
            vocabularySignature = ""
            return
        }
        guard text != vocabularySignature else { return }
        do {
            let (vocab, ctc) = try await CustomVocabularyContext.loadWithCtcTokens(from: file.path)
            vocabularySession = try await VocabularyBoostingSession(vocabulary: vocab, ctcModels: ctc)
            vocabularySignature = text
            vocabularyEntries = vocab.terms.map { ($0.text, $0.aliases ?? []) }
            log.info("custom vocabulary loaded: \(vocab.terms.count) terms")
        } catch {
            log.error("custom vocabulary failed to load: \(error.localizedDescription)")
            vocabularySession = nil
        }
    }

    /// Transcribes a whole recording with full context and word timings (used for the post-meeting pass),
    /// then applies custom-vocabulary rescoring if configured.
    public func transcribeFile(_ url: URL) async throws -> AsrOutput {
        try await load()
        let start = Date()
        let samples = try AudioConverter().resampleAudioFile(url)
        let result: ASRResult
        if let parakeet {
            var state = TdtDecoderState.make(decoderLayers: await parakeet.decoderLayerCount)
            result = try await parakeet.transcribe(samples, decoderState: &state)
        } else if let unified {
            result = try await unified.transcribeDetailed(samples)
        } else {
            throw NSError(domain: "AsrEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "model not loaded"])
        }
        let tokens = result.tokenTimings ?? []
        var words = Self.words(from: tokens)
        if let vocabularySession {
            words = await Self.applyVocabulary(
                words: words, tokens: tokens, samples: samples, session: vocabularySession, entries: vocabularyEntries)
        }
        return AsrOutput(
            text: words.map(\.text).joined(separator: " "),
            words: words,
            processingTime: Date().timeIntervalSince(start))
    }

    /// Runs vocabulary rescoring in windows of ~45 s (split at pauses) so memory stays bounded for long meetings,
    /// and maps the replacements back onto the timed words.
    static func applyVocabulary(
        words: [AsrWord], tokens: [TokenTiming], samples: [Float], session: VocabularyBoostingSession,
        entries: [(term: String, aliases: [String])]
    ) async -> [AsrWord] {
        guard !words.isEmpty else { return words }
        var result = words
        var chunkStart = 0
        var replaced = 0
        while chunkStart < result.count {
            var end = chunkStart
            let t0 = result[chunkStart].start
            while end + 1 < result.count, result[end + 1].start - t0 < 45 || result[end + 1].start - result[end].end < 0.3 {
                end += 1
                if result[end].start - t0 > 90 { break }
            }
            let from = max(0, t0 - 0.5)
            let to = min(Double(samples.count) / 16_000, result[end].end + 0.5)
            let lo = Int(from * 16_000)
            let hi = max(lo, Int(to * 16_000))
            let chunkTokens = tokens.filter { $0.startTime >= from && $0.endTime <= to }.map {
                TokenTiming(
                    token: $0.token, tokenId: $0.tokenId, startTime: $0.startTime - from, endTime: $0.endTime - from,
                    confidence: $0.confidence)
            }
            let chunkWords = Array(result[chunkStart...end])
            if !chunkTokens.isEmpty, hi > lo,
                let output = await session.rescore(
                    text: chunkWords.map(\.text).joined(separator: " "), tokenTimings: chunkTokens,
                    audioSamples: Array(samples[lo..<hi])),
                output.wasModified
            {
                let accepted = output.replacements.filter { $0.shouldReplace && isPlausible($0, entries: entries) }
                for r in accepted { log.info("vocabulary: \"\(r.originalWord)\" -> \"\(r.replacementWord ?? "")\" (\(r.reason))") }
                let updated = replace(chunkWords, with: accepted)
                replaced += accepted.count
                result.replaceSubrange(chunkStart...end, with: updated)
                end = chunkStart + updated.count - 1
            }
            chunkStart = end + 1
        }
        if replaced > 0 { log.info("custom vocabulary replaced \(replaced) words") }
        return result
    }

    /// The CTC spotter is English-trained and over-fires on German speech, so a replacement is only accepted when
    /// the recognized word already looks like the term (normalized edit similarity >= 0.6, e.g. "Wacken" → "Backend",
    /// "back end" → "Backend") or exactly matches one of the user's listed misrecognitions.
    static func isPlausible(_ r: VocabularyRescorer.RescoringResult, entries: [(term: String, aliases: [String])]) -> Bool {
        guard let replacement = r.replacementWord else { return false }
        let original = letters(r.originalWord)
        let parts = r.originalWord.split(separator: " ")
        guard !original.isEmpty, parts.count <= 3 else { return false }
        // Never merge across a sentence or clause boundary ("Launch. One" -> "Launchwoche").
        if parts.dropLast().contains(where: { $0.last.map { ".?!,;:".contains($0) } ?? false }) { return false }
        let entry = entries.first { $0.term.caseInsensitiveCompare(replacement) == .orderedSame }
        if let entry, entry.aliases.contains(where: { letters($0) == original }) { return true }
        let target = letters(replacement)
        guard original != target else { return false }
        return similarity(original, target) >= (parts.count > 1 ? 0.75 : 0.6)
    }

    static func letters(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Applies "original → replacement" pairs to a word list in order, keeping timing and trailing punctuation.
    /// Multi-word originals ("ella mind") collapse into one word carrying the combined time span.
    static func replace(_ words: [AsrWord], with replacements: [VocabularyRescorer.RescoringResult]) -> [AsrWord] {
        var out = words
        var cursor = 0
        func bare(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        }
        for r in replacements {
            guard let replacement = r.replacementWord else { continue }
            let target = r.originalWord.split(separator: " ").map { bare(String($0)) }
            guard !target.isEmpty else { continue }
            var i = cursor
            while i + target.count <= out.count {
                if (0..<target.count).allSatisfy({ bare(out[i + $0].text) == target[$0] }) {
                    let last = out[i + target.count - 1]
                    let trailing = String(last.text.reversed().prefix { CharacterSet.punctuationCharacters.contains($0.unicodeScalars.first!) }.reversed())
                    var merged = out[i]
                    merged.text = replacement + trailing
                    merged.end = last.end
                    out.replaceSubrange(i..<(i + target.count), with: [merged])
                    cursor = i + 1
                    break
                }
                i += 1
            }
        }
        return out
    }

    /// Groups sub-word tokens into words. SentencePiece marks a word start with "▁"; some paths emit a leading space.
    static func words(from tokens: [TokenTiming]) -> [AsrWord] {
        var words: [AsrWord] = []
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        for token in tokens {
            let raw = token.token
            let piece = raw.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
            let isPunctuation = piece.unicodeScalars.allSatisfy { punctuation.contains($0) }
            if isPunctuation, !words.isEmpty {
                // Punctuation attaches to the previous word. Its timestamp is unreliable (it can land on the
                // next utterance), so it never extends the word's end time.
                words[words.count - 1].text += piece
                continue
            }
            var startsWord = raw.hasPrefix("▁") || raw.hasPrefix(" ") || words.isEmpty
            // Numbers are often emitted without a word-start marker ("jetzt" + "42").
            if !startsWord, let prev = words.last?.text.unicodeScalars.last, let next = piece.unicodeScalars.first,
                CharacterSet.letters.contains(prev), CharacterSet.decimalDigits.contains(next)
            {
                startsWord = true
            }
            if startsWord {
                words.append(
                    AsrWord(text: piece, start: token.startTime, end: token.endTime, confidence: token.confidence))
            } else {
                words[words.count - 1].text += piece
                words[words.count - 1].end = token.endTime
                words[words.count - 1].confidence = min(words[words.count - 1].confidence, token.confidence)
            }
        }
        return words
    }
}
