import Foundation

/// Which capture stream a piece of speech came from. The microphone is the user, system audio is everyone else.
public enum Channel: String, Codable, Sendable, CaseIterable {
    case me
    case them
}

/// One utterance in a transcript. Times are seconds since the recording started.
public struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var channel: Channel
    /// Display label: "Me", or a diarized speaker such as "Speaker 1" (renameable).
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [AsrWord]?
    /// False while a live segment is still being spoken and may change.
    public var isFinal: Bool

    public init(
        id: UUID = UUID(), channel: Channel, speaker: String, start: Double, end: Double, text: String,
        words: [AsrWord]? = nil, isFinal: Bool = true
    ) {
        self.id = id
        self.channel = channel
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.isFinal = isFinal
    }
}

public extension TranscriptSegment {
    /// The same segment moved later on the timeline (word timings included).
    func shifted(by seconds: Double) -> TranscriptSegment {
        guard seconds != 0 else { return self }
        var s = self
        s.start += seconds
        s.end += seconds
        s.words = words?.map { var w = $0; w.start += seconds; w.end += seconds; return w }
        return s
    }
}

public extension Array where Element == TranscriptSegment {
    /// Plain-text transcript with timestamps and speaker labels, used for the LLM and for Markdown export.
    func formatted(timestamps: Bool = true) -> String {
        map { seg in
            let prefix = timestamps ? "[\(Self.clock(seg.start))] " : ""
            return "\(prefix)\(seg.speaker): \(seg.text)"
        }.joined(separator: "\n")
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
