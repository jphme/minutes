import Foundation

/// User settings, stored as editable JSON in ~/Library/Application Support/Minutes/settings.json.
public struct AppSettings: Codable, Sendable, Equatable {
    public enum LLMProvider: String, Codable, Sendable, CaseIterable {
        /// Claude through the Anthropic API (key in the keychain). Only the transcript text is sent, never audio.
        case anthropic
        case none
    }

    /// The one model that writes notes. Not a user setting: chosen in a blind comparison of Sonnet 5.5 (low, medium,
    /// high) and Haiku 5.5 (medium, high) on a real 50-minute call. Haiku at high effort matched Sonnet on names and
    /// details at about a tenth of the cost (≈ $0.01 per meeting hour); it takes ~45 s, which is fine after a meeting.
    public static let summaryModel = "claude-haiku-5-5"
    /// Reasoning effort for notes. At Haiku's default (medium) details were missed.
    public static let summaryEffort: String? = "high"

    public var asrModel: AsrModelKind = .parakeetUltra
    public var libraryPath: String = MeetingStore.defaultRoot.path
    public var detectMeetings = true
    /// Start recording right away when a meeting is detected instead of asking.
    public var autoStartRecording = false
    /// Stop when the meeting app releases the microphone.
    public var autoStopRecording = true
    public var useCalendar = true
    /// Keep the audio after the final transcript is done. Off by default: audio is written only while recording
    /// and processing, then deleted, so only text is stored (legal reasons; turn on for debugging).
    public var keepAudio = false
    public var llmProvider: LLMProvider = .anthropic
    /// The user's name and a line about their work, given to the notes model ("Me" in transcripts).
    public var userName = ""
    public var userAbout = ""
    /// Git remote for syncing notes and transcripts (encrypted with git-crypt); empty turns syncing off.
    public var notesRepository = ""
    /// Language for generated notes: "auto" follows the meeting language.
    public var summaryLanguage = "auto"
    /// Bundle IDs (prefix match) that should never trigger a meeting prompt.
    public var ignoredApps: [String] = []
    /// Extra bundle ID -> name pairs to treat as meeting apps.
    public var extraMeetingApps: [String: String] = [:]
    /// Passive mode: transcribe microphone and system audio all day into a daily digest (text only). Off by
    /// default and switched on only after the user confirms the consent notice.
    public var passiveMode = false
    /// Pause passive mode on battery power below this charge in percent (0 = never, 100 = whenever on battery).
    public var passiveBatteryThreshold = 20
    /// Pause passive mode while the screen is locked (the user is away; only bystanders would be recorded).
    public var passivePauseWhenLocked = true
    /// Data Protection: transcribe only the microphone, never what the Mac plays (the other side of calls). The
    /// default for new meetings and passive days; each meeting and day can override it from its toolbar.
    public var dataProtection = false

    public init() {}

    // Decode leniently so new fields can be added without breaking existing settings files.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        asrModel = (try? c.decode(AsrModelKind.self, forKey: .asrModel)) ?? d.asrModel
        libraryPath = (try? c.decode(String.self, forKey: .libraryPath)) ?? d.libraryPath
        detectMeetings = (try? c.decode(Bool.self, forKey: .detectMeetings)) ?? d.detectMeetings
        autoStartRecording = (try? c.decode(Bool.self, forKey: .autoStartRecording)) ?? d.autoStartRecording
        autoStopRecording = (try? c.decode(Bool.self, forKey: .autoStopRecording)) ?? d.autoStopRecording
        useCalendar = (try? c.decode(Bool.self, forKey: .useCalendar)) ?? d.useCalendar
        keepAudio = (try? c.decode(Bool.self, forKey: .keepAudio)) ?? d.keepAudio
        llmProvider = (try? c.decode(LLMProvider.self, forKey: .llmProvider)) ?? d.llmProvider
        userName = (try? c.decode(String.self, forKey: .userName)) ?? d.userName
        userAbout = (try? c.decode(String.self, forKey: .userAbout)) ?? d.userAbout
        notesRepository = (try? c.decode(String.self, forKey: .notesRepository)) ?? d.notesRepository
        summaryLanguage = (try? c.decode(String.self, forKey: .summaryLanguage)) ?? d.summaryLanguage
        ignoredApps = (try? c.decode([String].self, forKey: .ignoredApps)) ?? d.ignoredApps
        extraMeetingApps = (try? c.decode([String: String].self, forKey: .extraMeetingApps)) ?? d.extraMeetingApps
        passiveMode = (try? c.decode(Bool.self, forKey: .passiveMode)) ?? d.passiveMode
        passiveBatteryThreshold = (try? c.decode(Int.self, forKey: .passiveBatteryThreshold)) ?? d.passiveBatteryThreshold
        passivePauseWhenLocked = (try? c.decode(Bool.self, forKey: .passivePauseWhenLocked)) ?? d.passivePauseWhenLocked
        dataProtection = (try? c.decode(Bool.self, forKey: .dataProtection)) ?? d.dataProtection
    }
}

/// Location of settings and user-maintained context files.
public enum AppPaths {
    /// ~/Library/Application Support/Minutes, or $MINUTES_SUPPORT_DIR (used to isolate tests and benchmarks).
    public static var support: URL {
        let url = ProcessInfo.processInfo.environment["MINUTES_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Minutes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var settings: URL { support.appendingPathComponent("settings.json") }
    /// Terms, names and their spellings, one per line ("Term" or "Term: alias1, alias2").
    public static var vocabulary: URL { support.appendingPathComponent("vocabulary.txt") }
    /// Free-form background about the user and their work, given to the LLM with every summary.
    public static var context: URL { support.appendingPathComponent("context.md") }
    /// Optional override of the built-in summary instructions.
    public static var summaryPrompt: URL { support.appendingPathComponent("summary-prompt.md") }
    public static var logs: URL { support.appendingPathComponent("logs", isDirectory: true) }

    public static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settings),
            let s = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return s
    }

    public static func save(_ s: AppSettings) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(s).write(to: settings, options: .atomic)
    }

    public static func readText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Creates starter files so the user can find and edit them.
    public static func ensureDefaults() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: settings.path) { save(AppSettings()) }
        // Empty files: Settings → Background shows an example as placeholder. Lines starting with # are ignored.
        for url in [vocabulary, context] where !fm.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Parses vocabulary.txt into terms with optional aliases (comment and blank lines skipped).
    public static func vocabularyTerms() -> [(term: String, aliases: [String])] {
        readText(vocabulary).split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let aliases = parts.count > 1
                ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            return (parts[0], aliases)
        }
    }
}
