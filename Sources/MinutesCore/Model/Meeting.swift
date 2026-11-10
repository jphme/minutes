import Foundation

/// Metadata for one recorded meeting. Lives as `meeting.json` in the meeting's folder.
public struct Meeting: Codable, Sendable, Identifiable, Equatable, Hashable {
    public enum Status: String, Codable, Sendable {
        case recording
        /// Recording stopped, post-meeting transcription/diarization running.
        case processing
        /// Final transcript written, summary being generated.
        case summarizing
        case done
        /// Processing failed; `error` says why. Audio is kept so it can be retried.
        case failed
    }

    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: Status
    /// Bundle ID / name of the app that triggered detection, if any.
    public var sourceApp: String?
    public var calendarEventTitle: String?
    public var attendees: [String]
    public var asrModel: String?
    public var summaryModel: String?
    public var error: String?
    /// Display names for diarized speakers, e.g. "Speaker 1" -> "Anna".
    public var speakerNames: [String: String]
    /// Folder name relative to the library root (set by the store).
    public var folderName: String
    /// Recording parts when a meeting was resumed or merged; nil means one part from `startedAt` to `endedAt`.
    /// Part 1 audio is `audio-me.*`/`audio-them.*`, part n ≥ 2 is `audio-me-n.*`/`audio-them-n.*`.
    public var parts: [RecordingPart]?
    /// EventKit identifier of the linked calendar event, if any.
    public var calendarEventID: String?

    public init(
        id: UUID = UUID(), title: String, startedAt: Date = Date(), status: Status = .recording,
        sourceApp: String? = nil, calendarEventTitle: String? = nil, attendees: [String] = [], folderName: String = ""
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.status = status
        self.sourceApp = sourceApp
        self.calendarEventTitle = calendarEventTitle
        self.attendees = attendees
        self.speakerNames = [:]
        self.folderName = folderName
    }

    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    public func displayName(for speaker: String) -> String {
        speakerNames[speaker] ?? speaker
    }

    /// All recording parts, with the legacy single-part case filled in.
    public var allParts: [RecordingPart] {
        if let parts, !parts.isEmpty { return parts }
        return [RecordingPart(startedAt: startedAt, endedAt: endedAt, transcribed: status == .done || status == .summarizing)]
    }

    /// Seconds from the meeting start to the start of part `index` (transcript times use this timeline).
    public func offset(ofPart index: Int) -> Double {
        allParts[index].startedAt.timeIntervalSince(startedAt)
    }
}

/// One continuous recording within a meeting.
public struct RecordingPart: Codable, Sendable, Equatable, Hashable {
    public var startedAt: Date
    public var endedAt: Date?
    /// Whether this part's final transcript is already in transcript.json.
    public var transcribed: Bool

    public init(startedAt: Date, endedAt: Date? = nil, transcribed: Bool = false) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcribed = transcribed
    }
}
