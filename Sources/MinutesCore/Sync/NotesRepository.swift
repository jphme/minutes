import Foundation

private let log = MinutesLog("NotesSync")

/// Mirrors finished meetings as Markdown into a git repository (e.g. a private GitHub repo) so other tools and
/// cloud agents can read them. File contents are encrypted with git-crypt; only the README and .gitattributes are
/// plain text. Paths and commit messages are not encrypted by git-crypt and carry the meeting title on purpose,
/// so files are easy to find (the user's choice).
///
///     README.md, .gitattributes          plain
///     index.md                           encrypted: one row per meeting
///     meetings/2026/2026-11-09-1538-weekly-sync-b2a314b9/   (the ID suffix keeps the folder stable across renames)
///         notes.md                       encrypted: front matter (title, time, attendees) + generated notes
///         transcript.md                  encrypted
///         my-notes.md                    encrypted, only if the user typed notes
public actor NotesRepository {
    public struct Export: Sendable {
        public var meeting: Meeting
        public var summary: String
        public var userNotes: String
        public var transcriptMarkdown: String

        public init(meeting: Meeting, store: MeetingStore) {
            self.meeting = meeting
            summary = store.read("summary.md", for: meeting) ?? ""
            userNotes = store.read("notes.md", for: meeting) ?? ""
            let segments = store.loadTranscript(for: meeting)
            transcriptMarkdown = segments.isEmpty ? "" : store.transcriptMarkdown(segments, meeting: meeting)
        }
    }

    public enum SyncError: LocalizedError {
        case command(String, String)
        case missingKey(URL)
        case notEncrypted([String])
        case gitCryptMissing

        public var errorDescription: String? {
            switch self {
            case .command(let cmd, let out): return "\(cmd) failed: \(out.prefix(400))"
            case .missingKey(let url):
                return "The notes repository is encrypted with a git-crypt key this Mac does not have. Put the key file at \(url.path)."
            case .notEncrypted(let files):
                return "Refusing to push: these files would not be encrypted: \(files.joined(separator: ", "))"
            case .gitCryptMissing: return "git-crypt is not installed (brew install git-crypt)."
            }
        }
    }

    public let remote: String
    public let local: URL
    private let branch = "main"

    /// Copy of the repository's git-crypt key. Back it up (e.g. in a password manager): without it the notes cannot be read.
    public static var keyFile: URL { AppPaths.support.appendingPathComponent("notes-repo.git-crypt.key") }
    public static var defaultLocal: URL { AppPaths.support.appendingPathComponent("notes-repo", isDirectory: true) }

    public init(remote: String, local: URL = NotesRepository.defaultLocal) {
        self.remote = remote
        self.local = local
    }

    /// Writes the given meetings, removes deleted ones, commits and pushes. Returns a short status line.
    @discardableResult
    public func sync(_ exports: [Export], removedIDs: [UUID]) throws -> String {
        try prepare()
        try pullRebase()
        let fm = FileManager.default
        var written = 0
        var titles: [String] = []
        let readme = local.appendingPathComponent("README.md")
        if (try? String(contentsOf: readme, encoding: .utf8)) != Self.readme {
            try Self.readme.write(to: readme, atomically: true, encoding: .utf8)
        }
        for export in exports where !export.transcriptMarkdown.isEmpty || !export.summary.isEmpty {
            let dir = local.appendingPathComponent(Self.folderPath(export.meeting), isDirectory: true)
            // A meeting whose start time changed (merge) may still sit in an older folder.
            for old in folders(for: export.meeting.id) where old.path != dir.path { try? fm.removeItem(at: old) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.notesFile(export).write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
            try export.transcriptMarkdown.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            let mine = dir.appendingPathComponent("my-notes.md")
            let notes = export.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            if notes.isEmpty { try? fm.removeItem(at: mine) } else { try (notes + "\n").write(to: mine, atomically: true, encoding: .utf8) }
            written += 1
            titles.append(export.meeting.title)
        }
        var removedTitles: [String] = []
        for id in removedIDs {
            for dir in folders(for: id) {
                removedTitles.append(Self.frontMatter("title", in: dir.appendingPathComponent("notes.md")) ?? dir.lastPathComponent)
                try? fm.removeItem(at: dir)
            }
        }
        try writeIndex()

        try git("add", "-A")
        let staged = try git("diff", "--cached", "--name-only", "--diff-filter=ACMR")
            .split(separator: "\n").map(String.init)
        let removed = try git("diff", "--cached", "--name-only", "--diff-filter=D").split(separator: "\n")
        guard !staged.isEmpty || !removed.isEmpty else { return "Notes repository is up to date." }
        try verifyEncrypted(staged)
        let count = Set(staged.compactMap { $0.hasPrefix("meetings/") ? $0.split(separator: "/").dropLast().last : nil }).count
        var message: [String] = []
        if count > 0 { message.append("Update \(titles.count == 1 ? titles[0] : "\(count) meetings")") }
        if !removedTitles.isEmpty { message.append("Remove \(removedTitles.joined(separator: ", "))") }
        let body = titles.count > 1 ? "\n\n" + titles.map { "- \($0)" }.joined(separator: "\n") : ""
        try git("commit", "-q", "-m", (message.isEmpty ? ["Update meeting notes"] : message).joined(separator: "; ") + body)
        do {
            try git("push", "-q", "-u", "origin", branch)
        } catch {
            try pullRebase()
            try git("push", "-q", "-u", "origin", branch)
        }
        log.info("pushed notes: \(written) written, \(removedIDs.count) removed")
        let removedText = removedTitles.isEmpty ? "" : ", removed \(removedTitles.count)"
        return "Synced \(count) meeting\(count == 1 ? "" : "s")\(removedText) to \(remote)."
    }

    // MARK: Setup

    private func prepare() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: local.appendingPathComponent(".git").path) {
            try? fm.removeItem(at: local)
            try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try run(Self.git, ["clone", "-q", remote, local.path], in: local.deletingLastPathComponent())
        }
        if (try? git("remote", "get-url", "origin"))?.trimmingCharacters(in: .whitespacesAndNewlines) != remote {
            try git("remote", "set-url", "origin", remote)
        }
        if (try? git("config", "user.email"))?.isEmpty ?? true {
            try git("config", "user.name", "Minutes")
            try git("config", "user.email", "minutes@localhost")
        }
        let keyInRepo = local.appendingPathComponent(".git/git-crypt/keys/default")
        let hasCommits = (try? git("rev-parse", "--verify", "-q", "HEAD")) != nil
        let remoteHasBranch = !((try? git("ls-remote", "--heads", "origin", branch)) ?? "").isEmpty
        if fm.fileExists(atPath: keyInRepo.path) { return }

        guard let gitCrypt = Self.gitCrypt else { throw SyncError.gitCryptMissing }
        if !hasCommits && !remoteHasBranch {
            // Fresh repository: set up encryption before anything is committed.
            try git("symbolic-ref", "HEAD", "refs/heads/\(branch)")
            try run(gitCrypt, ["init"], in: local)
            try Self.gitattributes.write(to: local.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
            try Self.readme.write(to: local.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try git("add", ".gitattributes", "README.md")
            try git("commit", "-q", "-m", "Set up encrypted meeting notes")
            try exportKey(gitCrypt)
            try git("push", "-q", "-u", "origin", branch)
            log.info("initialized notes repository with git-crypt; key copied to \(Self.keyFile.path)")
            return
        }
        guard fm.fileExists(atPath: Self.keyFile.path) else { throw SyncError.missingKey(Self.keyFile) }
        if !hasCommits { try git("fetch", "-q", "origin"); try git("checkout", "-q", "-B", branch, "origin/\(branch)") }
        try run(gitCrypt, ["unlock", Self.keyFile.path], in: local)
    }

    private func exportKey(_ gitCrypt: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.keyFile.path) {
            try fm.moveItem(at: Self.keyFile, to: Self.keyFile.appendingPathExtension("old-\(Int(Date().timeIntervalSince1970))"))
        }
        try run(gitCrypt, ["export-key", Self.keyFile.path], in: local)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.keyFile.path)
    }

    private func pullRebase() throws {
        try git("fetch", "-q", "origin")
        guard !((try? git("ls-remote", "--heads", "origin", branch)) ?? "").isEmpty else { return }
        try git("rebase", "-q", "origin/\(branch)")
    }

    /// Every staged file that the attributes mark for encryption must be stored as a git-crypt blob.
    private func verifyEncrypted(_ files: [String]) throws {
        let mustEncrypt = files.filter { $0.hasPrefix("meetings/") || $0 == "index.md" }
        var plain: [String] = []
        for file in mustEncrypt {
            let header = try runData(Self.git, ["cat-file", "blob", ":\(file)"], in: local).prefix(10)
            if header != Data("\0GITCRYPT\0".utf8) { plain.append(file) }
        }
        if !plain.isEmpty {
            _ = try? git("reset", "-q")
            throw SyncError.notEncrypted(plain)
        }
    }

    // MARK: Content

    public static func folderPath(_ m: Meeting) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy"
        let year = f.string(from: m.startedAt)
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let slug = Self.slug(m.title)
        return "meetings/\(year)/\(f.string(from: m.startedAt))\(slug.isEmpty ? "" : "-" + slug)-\(m.id.uuidString.prefix(8).lowercased())"
    }

    /// "Planung Q3 mit Müller & Söhne (v2)" -> "planung-q3-mit-mueller-soehne-v2", at most 60 characters.
    static func slug(_ title: String) -> String {
        var t = title.lowercased()
        for (a, b) in ["ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss"] { t = t.replacingOccurrences(of: a, with: b) }
        t = t.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        let words = t.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted)
            .filter { !$0.isEmpty }
        var out = ""
        for w in words {
            let next = out.isEmpty ? w : out + "-" + w
            if next.count > 60 { break }
            out = next
        }
        return out
    }

    static func frontMatter(_ key: String, in file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
            let line = text.split(separator: "\n").first(where: { $0.hasPrefix(key + ": ") })
        else { return nil }
        return String(line.dropFirst(key.count + 2)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func folders(for id: UUID) -> [URL] {
        let suffix = "-" + id.uuidString.prefix(8).lowercased()
        let meetings = local.appendingPathComponent("meetings")
        let years = (try? FileManager.default.contentsOfDirectory(at: meetings, includingPropertiesForKeys: nil)) ?? []
        return years.flatMap { year in
            ((try? FileManager.default.contentsOfDirectory(at: year, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasSuffix(suffix) }
        }
    }

    static func notesFile(_ e: Export) -> String {
        let m = e.meeting
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "yyyy-MM-dd'T'HH:mmxxx"
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var fm = "---\n"
        fm += "title: \(q(m.title))\n"
        fm += "start: \(time.string(from: m.startedAt))\n"
        if let end = m.endedAt { fm += "end: \(time.string(from: end))\n" }
        if let d = m.duration { fm += "duration_minutes: \(Int((d / 60).rounded()))\n" }
        if let event = m.calendarEventTitle { fm += "calendar_event: \(q(event))\n" }
        if !m.attendees.isEmpty { fm += "attendees: [\(m.attendees.map(q).joined(separator: ", "))]\n" }
        if let app = m.sourceApp { fm += "app: \(q(app))\n" }
        let speakers = m.speakerNames.filter { !$0.value.isEmpty }
        if !speakers.isEmpty { fm += "speakers: {\(speakers.sorted { $0.key < $1.key }.map { "\(q($0.key)): \(q($0.value))" }.joined(separator: ", "))}\n" }
        if let model = m.summaryModel { fm += "notes_model: \(model)\n" }
        fm += "id: \(m.id.uuidString)\n---\n\n"
        let body = e.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return fm + "# \(m.title)\n\n" + (body.isEmpty ? "_No generated notes._" : body) + "\n"
    }

    /// index.md: newest first, rebuilt from the front matter of every notes.md in the repository.
    private func writeIndex() throws {
        let meetings = local.appendingPathComponent("meetings")
        var rows: [(start: String, line: String)] = []
        let years = (try? FileManager.default.contentsOfDirectory(at: meetings, includingPropertiesForKeys: nil)) ?? []
        for year in years {
            for dir in (try? FileManager.default.contentsOfDirectory(at: year, includingPropertiesForKeys: nil)) ?? [] {
                guard let text = try? String(contentsOf: dir.appendingPathComponent("notes.md"), encoding: .utf8) else { continue }
                func field(_ key: String) -> String {
                    let line = text.split(separator: "\n").first { $0.hasPrefix(key + ": ") } ?? ""
                    return String(line.dropFirst(key.count + 2)).trimmingCharacters(in: CharacterSet(charactersIn: "\"[]"))
                        .replacingOccurrences(of: "\", \"", with: ", ").replacingOccurrences(of: "|", with: "/")
                }
                let start = field("start")
                let path = "meetings/\(year.lastPathComponent)/\(dir.lastPathComponent)"
                rows.append((start, "| \(start.prefix(16).replacingOccurrences(of: "T", with: " ")) | [\(field("title"))](\(path)/notes.md) | \(field("duration_minutes")) | \(field("attendees")) |"))
            }
        }
        let table = rows.sorted { $0.start > $1.start }.map(\.line).joined(separator: "\n")
        let index = """
            # Meetings

            Newest first. Each folder has notes.md (front matter + notes), transcript.md and, if any, my-notes.md.

            | Start | Title | Minutes | Attendees |
            |---|---|---|---|
            \(table)

            """
        try index.write(to: local.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    }

    static let gitattributes = """
        # Everything except this file and README.md is encrypted with git-crypt.
        meetings/** filter=git-crypt diff=git-crypt
        index.md filter=git-crypt diff=git-crypt

        """

    static let readme = """
        # Meeting notes

        Notes and transcripts written by Minutes, a local meeting transcriber. The contents of every file except this
        README and `.gitattributes` are encrypted with [git-crypt](https://github.com/AGWA/git-crypt). Folder names
        and commit messages are plain text and contain the meeting date, time and title.

        ## Layout

        - `index.md`: all meetings, newest first (start, title, length, attendees, link).
        - `meetings/<year>/<yyyy-mm-dd-hhmm>-<title>-<id>/notes.md`: YAML front matter (title, start/end, attendees,
          calendar event, speaker names) followed by the generated notes.
        - `.../transcript.md`: the speaker-labelled transcript ("Me" is the owner of the notes).
        - `.../my-notes.md`: notes typed by hand during the meeting, if any.

        ## Reading the notes elsewhere

        ```bash
        git clone <this repo> && cd <repo>
        git-crypt unlock /path/to/key           # or: echo "$MEETING_NOTES_KEY" | base64 -d > key && git-crypt unlock key
        ```

        The key is a binary file; store it base64-encoded as a secret for cloud agents (`base64 -i key`).
        Without the key, files show as binary data.

        """

    // MARK: Processes

    static let git = "/usr/bin/git"
    static var gitCrypt: String? {
        ["/opt/homebrew/bin/git-crypt", "/usr/local/bin/git-crypt"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private func git(_ args: String...) throws -> String {
        try run(Self.git, args, in: local)
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String], in dir: URL) throws -> String {
        String(decoding: try runData(tool, args, in: dir), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runData(_ tool: String, _ args: [String], in dir: URL) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        // Apps launched from Finder get a minimal PATH; git-crypt and gh (credential helper) live in Homebrew.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw SyncError.command(
                ([URL(fileURLWithPath: tool).lastPathComponent] + args.prefix(3)).joined(separator: " "),
                String(decoding: errData + data, as: UTF8.self))
        }
        return data
    }
}
