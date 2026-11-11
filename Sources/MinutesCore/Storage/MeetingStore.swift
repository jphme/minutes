import Foundation

/// File-based meeting library: one folder per meeting, plain files that other tools (and Claude) can read.
///
///     <root>/2026-11-09 14-30 Weekly sync/
///         meeting.json        metadata (Meeting)
///         transcript.json     final segments ([TranscriptSegment]); live.jsonl while recording
///         transcript.md       readable transcript
///         notes.md            the user's own notes typed during the meeting
///         summary.md          generated meeting notes
///         audio-me.m4a / audio-them.m4a   recordings (CAF while recording/processing)
///         speakers.json       voice embeddings per diarized speaker
public final class MeetingStore: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static var defaultRoot: URL {
        fm_documents.appendingPathComponent("Minutes", isDirectory: true)
    }

    private static var fm_documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    public init(root: URL = MeetingStore.defaultRoot) {
        self.root = root
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Paths

    public func folder(for meeting: Meeting) -> URL { root.appendingPathComponent(meeting.folderName, isDirectory: true) }
    public func file(_ name: String, for meeting: Meeting) -> URL { folder(for: meeting).appendingPathComponent(name) }

    /// "audio-me" for part 0, "audio-me-2" for part 1, …
    public static func audioBaseName(_ channel: Channel, part: Int = 0) -> String {
        part == 0 ? "audio-\(channel.rawValue)" : "audio-\(channel.rawValue)-\(part + 1)"
    }

    public func audioURL(_ channel: Channel, for meeting: Meeting, part: Int = 0) -> URL? {
        for ext in ["caf", "wav", "m4a"] {
            let url = file("\(Self.audioBaseName(channel, part: part)).\(ext)", for: meeting)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// True if any part still has audio on disk (needed for re-transcription).
    public func hasAudio(_ meeting: Meeting) -> Bool {
        meeting.allParts.indices.contains { i in Channel.allCases.contains { audioURL($0, for: meeting, part: i) != nil } }
    }

    // MARK: CRUD

    /// Creates the folder for a new meeting and writes its metadata.
    public func create(_ meeting: Meeting) throws -> Meeting {
        var m = meeting
        let base = Self.folderName(date: m.startedAt, title: m.title)
        var name = base
        var n = 2
        while fm.fileExists(atPath: root.appendingPathComponent(name).path) {
            name = "\(base) \(n)"
            n += 1
        }
        m.folderName = name
        try fm.createDirectory(at: folder(for: m), withIntermediateDirectories: true)
        try save(m)
        return m
    }

    public func save(_ meeting: Meeting) throws {
        try encoder.encode(meeting).write(to: file("meeting.json", for: meeting), options: .atomic)
    }

    /// Renames the folder to match a new title (keeps the date prefix).
    public func rename(_ meeting: Meeting, to title: String) throws -> Meeting {
        var m = meeting
        m.title = title
        let newName = Self.folderName(date: m.startedAt, title: title)
        if newName != meeting.folderName, !fm.fileExists(atPath: root.appendingPathComponent(newName).path) {
            try fm.moveItem(at: folder(for: meeting), to: root.appendingPathComponent(newName))
            m.folderName = newName
        }
        try save(m)
        return m
    }

    public func delete(_ meeting: Meeting) throws {
        try fm.trashItem(at: folder(for: meeting), resultingItemURL: nil)
    }

    /// All meetings, newest first.
    public func list() -> [Meeting] {
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir -> Meeting? in
            let url = dir.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: url), var m = try? decoder.decode(Meeting.self, from: data) else {
                return nil
            }
            m.folderName = dir.lastPathComponent  // tolerate folders renamed in Finder
            return m
        }.sorted { $0.startedAt > $1.startedAt }
    }

    public func reload(_ meeting: Meeting) -> Meeting? {
        guard let data = try? Data(contentsOf: file("meeting.json", for: meeting)),
            var m = try? decoder.decode(Meeting.self, from: data)
        else { return nil }
        m.folderName = meeting.folderName
        return m
    }

    // MARK: Transcript

    public func saveTranscript(_ segments: [TranscriptSegment], for meeting: Meeting) throws {
        try encoder.encode(segments).write(to: file("transcript.json", for: meeting), options: .atomic)
        try transcriptMarkdown(segments, meeting: meeting).write(
            to: file("transcript.md", for: meeting), atomically: true, encoding: .utf8)
    }

    /// Final transcript if present, otherwise whatever the live transcriber wrote.
    /// With Data Protection on, system-audio lines are never returned, even if a live file still holds some from
    /// before the switch.
    public func loadTranscript(for meeting: Meeting) -> [TranscriptSegment] {
        let segments = loadFinalTranscript(for: meeting) ?? loadLiveTranscript(for: meeting)
        return meeting.isProtected ? segments.filter { $0.channel != .them } : segments
    }

    public func loadFinalTranscript(for meeting: Meeting) -> [TranscriptSegment]? {
        guard let data = try? Data(contentsOf: file("transcript.json", for: meeting)) else { return nil }
        return try? decoder.decode([TranscriptSegment].self, from: data)
    }

    public func appendLive(_ segment: TranscriptSegment, for meeting: Meeting) {
        guard segment.isFinal, let data = try? JSONEncoder().encode(segment) else { return }
        let url = file("live.jsonl", for: meeting)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data + Data([0x0A]))
            try? handle.close()
        } else {
            try? (data + Data([0x0A])).write(to: url)
        }
    }

    public func loadLiveTranscript(for meeting: Meeting) -> [TranscriptSegment] {
        guard let text = try? String(contentsOf: file("live.jsonl", for: meeting), encoding: .utf8) else { return [] }
        var byID: [UUID: TranscriptSegment] = [:]
        for line in text.split(separator: "\n") {
            if let seg = try? JSONDecoder().decode(TranscriptSegment.self, from: Data(line.utf8)) { byID[seg.id] = seg }
        }
        return byID.values.filter { !$0.text.isEmpty }.sorted { $0.start < $1.start }
    }

    public func transcriptMarkdown(_ segments: [TranscriptSegment], meeting: Meeting) -> String {
        var out = "# \(meeting.title) — Transcript\n\n"
        out += "\(Self.humanDate(meeting.startedAt))\n\n"
        var lastSpeaker = ""
        for seg in segments {
            let name = meeting.displayName(for: seg.speaker)
            if name != lastSpeaker {
                out += "\n**\(name)** [\([TranscriptSegment].clock(seg.start))]\n"
                lastSpeaker = name
            }
            out += "\(seg.text)\n"
        }
        return out
    }

    // MARK: Text files

    public func read(_ name: String, for meeting: Meeting) -> String? {
        try? String(contentsOf: file(name, for: meeting), encoding: .utf8)
    }

    public func write(_ text: String, to name: String, for meeting: Meeting) throws {
        try text.write(to: file(name, for: meeting), atomically: true, encoding: .utf8)
    }

    public func saveSpeakerEmbeddings(_ embeddings: [String: [Float]], for meeting: Meeting) throws {
        try encoder.encode(embeddings).write(to: file("speakers.json", for: meeting), options: .atomic)
    }

    public func loadSpeakerEmbeddings(for meeting: Meeting) -> [String: [Float]] {
        guard let data = try? Data(contentsOf: file("speakers.json", for: meeting)) else { return [:] }
        return (try? decoder.decode([String: [Float]].self, from: data)) ?? [:]
    }

    // MARK: Parts

    /// Starts a new recording part in an existing meeting (resume after a dropped call). Returns the part index.
    public func addPart(to meeting: inout Meeting, at date: Date = Date()) throws -> Int {
        var parts = meeting.allParts
        parts.append(RecordingPart(startedAt: date))
        meeting.parts = parts
        meeting.endedAt = nil
        meeting.status = .recording
        try save(meeting)
        return parts.count - 1
    }

    /// Appends meeting `other` to `meeting` as further parts: transcripts are shifted onto one timeline,
    /// speakers matched by voice, audio files and notes moved over, and `other` is moved to the Trash.
    public func merge(_ other: Meeting, into meeting: Meeting) throws -> Meeting {
        let (first, second) = meeting.startedAt <= other.startedAt ? (meeting, other) : (other, meeting)
        var merged = first
        let firstParts = first.allParts
        let secondParts = second.allParts
        merged.parts = firstParts + secondParts
        merged.endedAt = [first.endedAt, second.endedAt].compactMap { $0 }.max()
        merged.attendees = Array(NSOrderedSet(array: first.attendees + second.attendees)) as? [String] ?? first.attendees
        if merged.calendarEventTitle == nil {
            merged.calendarEventTitle = second.calendarEventTitle
            merged.calendarEventID = second.calendarEventID
        }
        // One-sided only if both were: otherwise the notes model should treat the other side as present.
        merged.dataProtection = first.isProtected && second.isProtected ? true : nil

        // Transcript: shift the second meeting onto the first one's timeline and relabel its speakers.
        let shift = second.startedAt.timeIntervalSince(first.startedAt)
        var segments = loadTranscript(for: first)
        var embeddings = loadSpeakerEmbeddings(for: first)
        let incoming = loadTranscript(for: second).map { $0.shifted(by: shift) }
        let mapping = SpeakerMatcher.mapping(
            newLabels: incoming.map(\.speaker), newEmbeddings: loadSpeakerEmbeddings(for: second),
            existingLabels: Set(segments.map(\.speaker)), existingEmbeddings: &embeddings)
        segments += incoming.map { var s = $0; s.speaker = mapping[s.speaker] ?? s.speaker; return s }
        for (k, v) in second.speakerNames where merged.speakerNames[mapping[k] ?? k] == nil {
            merged.speakerNames[mapping[k] ?? k] = v
        }
        segments.sort { $0.start < $1.start }

        // Audio: the second meeting's parts follow the first one's.
        for (i, _) in secondParts.enumerated() {
            for channel in Channel.allCases {
                guard let src = audioURL(channel, for: second, part: i) else { continue }
                let dst = file("\(Self.audioBaseName(channel, part: firstParts.count + i)).\(src.pathExtension)", for: merged)
                try fm.moveItem(at: src, to: dst)
            }
        }
        let notes = [read("notes.md", for: first), read("notes.md", for: second)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        try write(notes.joined(separator: "\n\n"), to: "notes.md", for: merged)
        try saveTranscript(segments, for: merged)
        try saveSpeakerEmbeddings(embeddings, for: merged)
        try save(merged)
        try delete(second)
        return merged
    }

    // MARK: Helpers

    static func folderName(date: Date, title: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(f.string(from: date)) \(String(clean.prefix(80)))"
    }

    public static func humanDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f.string(from: date)
    }
}
