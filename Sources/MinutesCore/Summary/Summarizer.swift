import Foundation
import NaturalLanguage

/// Builds structured meeting notes (summary, topics, decisions, action items, open questions) from the transcript,
/// the user's own notes, calendar data and background context.
public struct Summarizer: Sendable {
    public struct Input: Sendable {
        public var meeting: Meeting
        public var segments: [TranscriptSegment]
        public var userNotes: String
        public var context: String
        public var vocabulary: [String]
        public var language: String  // "auto" or a language name/code

        public init(
            meeting: Meeting, segments: [TranscriptSegment], userNotes: String, context: String, vocabulary: [String],
            language: String
        ) {
            self.meeting = meeting
            self.segments = segments
            self.userNotes = userNotes
            self.context = context
            self.vocabulary = vocabulary
            self.language = language
        }
    }

    public struct Output: Sendable {
        public var title: String?
        public var markdown: String
    }

    public static let defaultInstructions = """
        You are an expert meeting note-taker. Write the notes the user would have written themselves if they had \
        listened perfectly: concise, specific and skimmable.

        Rules:
        - Use only information from the transcript, the user's notes and the provided context. Never invent facts, \
        numbers, owners or deadlines; if something is unclear, say so briefly.
        - The user's own notes mark what they found important: cover every point in them and keep their wording \
        where sensible, expanded with details from the transcript.
        - "Me" in the transcript is the user; call them by the first name given in the background. Other speakers \
        are labeled "Speaker 1", "Speaker 2", ... or by name. Put a name to every speaker you can and use it \
        everywhere instead of the label. Evidence, strongest first: names confirmed by the user; people \
        addressing each other ("Flo, can you …?" followed by Speaker 2 agreeing means Speaker 2 is Flo) or \
        introducing themselves; the calendar event. The calendar title often names the other person, and \
        attendees may be given only as email addresses (anna.schmidt@example.com is Anna Schmidt). The attendee \
        list usually includes the user. When exactly one remote speaker and exactly one other attendee remain, \
        that attendee is the speaker. Keep a label only when no name can be inferred.
        - The transcript comes from speech recognition and contains errors. Silently correct misheard names, \
        terms and abbreviations using the attendee list, glossary and background. Do not quote obvious \
        recognition errors.
        - Leave out small talk, filler and logistics unless they matter.
        - Write everything in {LANGUAGE}, including all headings. Keep \
        established English technical terms as they are.

        Output Markdown in exactly this structure (omit a section if it would be empty, except the summary):

        # <short, specific meeting title>

        ## {H_SUMMARY}
        2–4 sentences: purpose, outcome, most important next step.

        ## <Topic heading>
        - Bullets with the substance: facts, arguments, numbers, concerns, who said what when it matters.
        (one section per major topic, in the order discussed; no extra wrapper heading around the topics)

        ## {H_DECISIONS}
        - Each decision that was actually made.

        ## {H_ACTIONS}
        - [ ] **Owner**: task (deadline if one was stated)

        ## {H_QUESTIONS}
        - Unresolved points or things to follow up on.
        """

    /// Appended to the instructions (also to a custom prompt) when a meeting was recorded with Data Protection.
    public static let dataProtectionInstructions = """
        Additional rules for this meeting (they change how you read the transcript, not the output structure):
        It was recorded in Data Protection mode: only the user's microphone was transcribed. What the \
        other participants said through the computer was deliberately not recorded, so the transcript holds one \
        side of the conversation: the user, and anyone speaking in the same room. Write the notes from that side:
        - Infer what the others said, asked or proposed from the user's replies and the context, but only where \
        the user's side makes it clear, and phrase it as inferred ("Anna apparently asked about …, and the user \
        agreed to …"). Say once, in the summary, that the notes rest on the user's side only; do not repeat it in \
        every bullet and do not add a section about it.
        - Never invent statements, numbers, decisions or commitments of the other participants. What they \
        committed to is known only when the user repeats or confirms it; otherwise list it under open questions.
        - Tasks the user took on are certain; tasks for others only when the user stated them.
        - Do not try to name remote speakers: they are not in the transcript. "Speaker 1", "Speaker 2" … are \
        people in the room with the user.
        """

    /// Background block for the prompt: the user's name and role from Settings plus the free-form context file.
    public static func background(settings: AppSettings) -> String {
        var lines: [String] = []
        let name = settings.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { lines.append("The user (\"Me\" in the transcript) is \(name).") }
        let about = settings.userAbout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !about.isEmpty { lines.append(about) }
        let context = AppPaths.readText(AppPaths.context).trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty { lines.append(context) }
        return lines.joined(separator: "\n\n")
    }

    public static func instructions() -> String {
        let custom = AppPaths.readText(AppPaths.summaryPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? defaultInstructions : custom
    }

    /// Dominant language of the transcript, for the "auto" setting.
    public static func detectLanguage(_ segments: [TranscriptSegment]) -> String {
        let sample = segments.prefix(400).map(\.text).joined(separator: " ")
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.german, .english, .french, .spanish, .italian, .dutch]
        recognizer.processString(sample)
        switch recognizer.dominantLanguage {
        case .german?: return "German"
        case .french?: return "French"
        case .spanish?: return "Spanish"
        case .italian?: return "Italian"
        case .dutch?: return "Dutch"
        default: return "English"
        }
    }

    public static func messages(for input: Input) -> (system: String, user: String) {
        let language = input.language == "auto" ? detectLanguage(input.segments) : input.language
        let headings = language == "German"
            ? ["Zusammenfassung", "Entscheidungen", "Aufgaben", "Offene Fragen"]
            : ["Summary", "Decisions", "Action items", "Open questions"]
        var instructions = instructions()
        if input.meeting.isProtected {
            instructions += "\n\n" + dataProtectionInstructions
        }
        let system = instructions
            .replacingOccurrences(of: "{LANGUAGE}", with: language)
            .replacingOccurrences(of: "{H_SUMMARY}", with: headings[0])
            .replacingOccurrences(of: "{H_DECISIONS}", with: headings[1])
            .replacingOccurrences(of: "{H_ACTIONS}", with: headings[2])
            .replacingOccurrences(of: "{H_QUESTIONS}", with: headings[3])
        let m = input.meeting
        var user = "## Meeting\n"
        if let event = m.calendarEventTitle {
            user += "Calendar event: \(event)\n"
        } else {
            user += "Title: \(m.title)\n"
        }
        user += "Date: \(MeetingStore.humanDate(m.startedAt))\n"
        if m.isProtected { user += "Recorded with Data Protection: microphone only, the other participants are not in the transcript.\n" }
        if let d = m.duration { user += "Duration: \(Int(d / 60)) minutes\n" }
        if let app = m.sourceApp { user += "App: \(app)\n" }
        if !m.attendees.isEmpty { user += "Attendees (from calendar): \(m.attendees.joined(separator: ", "))\n" }
        let renamed = m.speakerNames.filter { !$0.value.isEmpty }
        if !renamed.isEmpty {
            user += "Speaker names confirmed by the user: "
                + renamed.map { "\($0.key) = \($0.value)" }.sorted().joined(separator: ", ") + "\n"
        }
        let context = input.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty { user += "\n## Background about the user\n\(context)\n" }
        if !input.vocabulary.isEmpty {
            user += "\n## Glossary (correct spellings)\n\(input.vocabulary.joined(separator: ", "))\n"
        }
        let notes = input.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        user += "\n## The user's own notes\n\(notes.isEmpty ? "(none)" : notes)\n"
        let transcript = input.segments.map { seg in
            "[\([TranscriptSegment].clock(seg.start))] \(m.displayName(for: seg.speaker)): \(seg.text)"
        }.joined(separator: "\n")
        user += "\n## Transcript\n\(transcript)\n"
        return (system, user)
    }

    /// Splits off the leading "# Title" line.
    public static func parse(_ markdown: String) -> Output {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = trimmed.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("# ") {
            let title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
            return Output(title: title.isEmpty ? nil : title, markdown: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Output(title: nil, markdown: trimmed)
    }
}
