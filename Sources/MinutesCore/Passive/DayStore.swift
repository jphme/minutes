import Foundation

private let log = MinutesLog("DayStore")

/// One line of a passive-mode day: an utterance, or a marker for a meeting recorded separately.
public struct DayEntry: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case speech
        /// A meeting recording ran (passive capture was paused); `text` is its title.
        case meeting
    }

    public var id: UUID
    public var kind: Kind
    public var start: Date
    public var end: Date
    /// Microphone ("me") or what the Mac played ("them"); nil for markers.
    public var channel: Channel?
    public var text: String
    /// Folder name of the meeting, for `.meeting` markers.
    public var meeting: String?
    /// The meeting's id, for `.meeting` markers: the folder is renamed when the meeting gets its final title.
    public var meetingID: UUID?

    public init(
        id: UUID = UUID(), kind: Kind = .speech, start: Date, end: Date, channel: Channel? = nil, text: String,
        meeting: String? = nil, meetingID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.channel = channel
        self.text = text
        self.meeting = meeting
        self.meetingID = meetingID
    }

    /// Label in transcripts and prompts: "Mic" for the microphone, "Mac" for sound the computer played.
    public var source: String { channel == .them ? "Mac" : "Mic" }
}

/// Bookkeeping for a day: how far the digest has read, and what the summaries cost.
public struct DayState: Codable, Sendable, Equatable {
    /// Number of transcript entries (lines) already folded into the digest.
    public var digestedEntries = 0
    public var digestUpdatedAt: Date?
    public var digestUpdates = 0
    public var summaryWrittenAt: Date?
    public var inputTokens = 0
    public var outputTokens = 0
    public var costUSD = 0.0
    public var lastError: String?
    /// Bumped when entries are forgotten, so a digest update that read them in the meantime is discarded.
    public var generation = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DayState()
        digestedEntries = (try? c.decode(Int.self, forKey: .digestedEntries)) ?? d.digestedEntries
        digestUpdatedAt = try? c.decode(Date.self, forKey: .digestUpdatedAt)
        digestUpdates = (try? c.decode(Int.self, forKey: .digestUpdates)) ?? d.digestUpdates
        summaryWrittenAt = try? c.decode(Date.self, forKey: .summaryWrittenAt)
        inputTokens = (try? c.decode(Int.self, forKey: .inputTokens)) ?? d.inputTokens
        outputTokens = (try? c.decode(Int.self, forKey: .outputTokens)) ?? d.outputTokens
        costUSD = (try? c.decode(Double.self, forKey: .costUSD)) ?? d.costUSD
        lastError = try? c.decode(String.self, forKey: .lastError)
        generation = (try? c.decode(Int.self, forKey: .generation)) ?? d.generation
    }
}

/// Passive-mode storage: one folder per local date, text only (audio never touches the disk).
///
///     <library>/Days/2026-11-09/
///         transcript.jsonl   append-only, one DayEntry per line, written as each utterance ends
///         transcript.md      the same as readable Markdown, appended in step
///         digest.md          rolling digest, replaced atomically after each update
///         summary.md         end-of-day summary
///         day.json           DayState (digest cursor, cost, speech time)
///
/// Each utterance (at most ~28 s of speech, the live transcriber's hard limit) is appended and flushed the
/// moment it is transcribed, so a crash or power loss loses at most the utterance in progress. A torn last line
/// is skipped when reading. The whole day is one file because it stays small (a full day of talk is ~0.5 MB).
public final class DayStore: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default
    private let lock = NSLock()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// `library` is the meeting library; days live in its "Days" subfolder (no meeting.json, so the meeting list ignores it).
    public init(library: URL) {
        root = library.appendingPathComponent("Days", isDirectory: true)
    }

    // MARK: Days

    public static func key(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func date(for key: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }

    public func folder(_ day: String) -> URL { root.appendingPathComponent(day, isDirectory: true) }
    public func file(_ name: String, day: String) -> URL { folder(day).appendingPathComponent(name) }

    /// Days with passive data, newest first.
    public func days() -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { Self.date(for: $0) != nil && fm.fileExists(atPath: file("transcript.jsonl", day: $0).path) }
            .sorted(by: >)
    }

    // MARK: Transcript

    /// Appends one entry to its day (by start time) and flushes it to disk.
    public func append(_ entry: DayEntry) {
        let day = Self.key(for: entry.start)
        lock.lock()
        defer { lock.unlock() }
        do {
            try fm.createDirectory(at: folder(day), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(entry) + Data([0x0A])
            try appendData(data, to: file("transcript.jsonl", day: day))
            let md = file("transcript.md", day: day)
            if !fm.fileExists(atPath: md.path) { try Self.markdownHeader(day).write(to: md, atomically: true, encoding: .utf8) }
            try appendData(Data(Self.markdownLine(entry).utf8), to: md)
        } catch {
            log.error("append failed: \(error.localizedDescription)")
        }
    }

    private func appendData(_ data: Data, to url: URL) throws {
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    public func entries(_ day: String) -> [DayEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entriesUnlocked(day)
    }

    /// Entries and state read together, so a concurrent `forget` cannot fall between the two reads.
    public func snapshot(_ day: String) -> (entries: [DayEntry], state: DayState) {
        lock.lock()
        defer { lock.unlock() }
        return (entriesUnlocked(day), loadStateUnlocked(day))
    }

    private func entriesUnlocked(_ day: String) -> [DayEntry] {
        guard let text = try? String(contentsOf: file("transcript.jsonl", day: day), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? Self.decoder.decode(DayEntry.self, from: Data(line.utf8))
        }
    }

    /// Deletes every entry that ends after `date` (the "forget the last minutes" action) and rewrites both
    /// transcript files. If the digest or a summary had already seen any of it, they are deleted and the digest
    /// starts over from the remaining transcript. Returns how many entries were removed.
    @discardableResult
    public func forget(since date: Date, day: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let all = entriesUnlocked(day)
        let kept = all.filter { $0.end <= date }
        guard kept.count < all.count else { return 0 }
        // Lines are in arrival order, not time order (mic lines arrive late), so check positions, not counts.
        let firstRemoved = all.firstIndex { $0.end > date } ?? all.count
        do {
            let jsonl = try kept.map { String(decoding: try Self.encoder.encode($0), as: UTF8.self) }.joined(separator: "\n")
            try (jsonl.isEmpty ? "" : jsonl + "\n").write(to: file("transcript.jsonl", day: day), atomically: true, encoding: .utf8)
            try (Self.markdownHeader(day) + kept.map(Self.markdownLine).joined())
                .write(to: file("transcript.md", day: day), atomically: true, encoding: .utf8)
            var state = loadStateUnlocked(day)
            state.generation += 1
            if state.digestedEntries > firstRemoved {
                // The digest has seen forgotten text: start it over from the remaining transcript.
                state.digestedEntries = 0
                try? fm.removeItem(at: file("digest.md", day: day))
            }
            if state.summaryWrittenAt != nil {
                state.summaryWrittenAt = nil
                try? fm.removeItem(at: file("summary.md", day: day))
            }
            try saveStateUnlocked(state, day: day)
        } catch {
            log.error("forget failed: \(error.localizedDescription)")
        }
        return all.count - kept.count
    }

    /// Moves a day's folder (transcript, digest, summary) to the Trash.
    public func delete(_ day: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard fm.fileExists(atPath: folder(day).path) else { return }
        try fm.trashItem(at: folder(day), resultingItemURL: nil)
    }

    static func markdownHeader(_ day: String) -> String {
        "# Passive transcript \(day)\n\nMic = microphone, Mac = sound the computer played.\n\n"
    }

    public static func markdownLine(_ entry: DayEntry) -> String {
        switch entry.kind {
        case .speech: return "[\(clock(entry.start))] \(entry.source): \(entry.text)\n"
        case .meeting: return "\n— Meeting recorded separately: \(entry.text) (\(clock(entry.start, seconds: false))–\(clock(entry.end, seconds: false))) —\n\n"
        }
    }

    public static func clock(_ date: Date, seconds: Bool = true) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return seconds
            ? String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
            : String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: Digest, summary, state

    public func read(_ name: String, day: String) -> String? {
        try? String(contentsOf: file(name, day: day), encoding: .utf8)
    }

    public func write(_ text: String, to name: String, day: String) throws {
        try fm.createDirectory(at: folder(day), withIntermediateDirectories: true)
        try text.write(to: file(name, day: day), atomically: true, encoding: .utf8)
    }

    public func loadState(_ day: String) -> DayState {
        lock.lock()
        defer { lock.unlock() }
        return loadStateUnlocked(day)
    }

    /// Reads, changes and saves the state under the lock, so appends and digest updates do not overwrite each other.
    public func updateState(_ day: String, _ change: (inout DayState) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var state = loadStateUnlocked(day)
        change(&state)
        try? saveStateUnlocked(state, day: day)
    }

    private func loadStateUnlocked(_ day: String) -> DayState {
        guard let data = try? Data(contentsOf: file("day.json", day: day)),
            let state = try? Self.decoder.decode(DayState.self, from: data)
        else { return DayState() }
        return state
    }

    private func saveStateUnlocked(_ state: DayState, day: String) throws {
        try fm.createDirectory(at: folder(day), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(state).write(to: file("day.json", day: day), options: .atomic)
    }
}
