import Foundation

private let log = MinutesLog("Digest")

/// Turns a passive-mode day transcript into a rolling digest (updated every so often while the day runs) and
/// an end-of-day summary, with the same Claude model as meeting notes.
///
/// Each update sends only the current digest plus the transcript added since the last update (at most
/// `maxBlockChars`; a larger backlog is worked off in several calls), so the cost per update stays flat however
/// long the day gets. The model replies with the complete new digest, or `NO_CHANGE` when the new stretch was
/// all noise, which saves the output tokens of rewriting it.
public struct DayDigester: Sendable {
    public let store: DayStore
    public let settings: AppSettings

    public init(store: DayStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    // MARK: Cadence

    /// Below this much new speech an update is not worth a call (~30 s of talk).
    public static let minNewChars = 400
    /// This much new speech triggers an update right away (~15 minutes of continuous conversation).
    public static let volumeChars = 12_000
    /// A pause this long after new speech usually means a conversation ended: summarize it while it is fresh.
    public static let idleSeconds: TimeInterval = 5 * 60
    /// Otherwise update at least this often while there is new speech.
    public static let maxInterval: TimeInterval = 30 * 60
    /// But not more often than this (except for the volume trigger), to bound calls on a talkative day.
    public static let minInterval: TimeInterval = 10 * 60
    /// Transcript per call (~10k tokens). Bounds the prompt; a backlog is split into several calls.
    public static let maxBlockChars = 40_000
    /// The end-of-day summary includes the full transcript up to this size (~55k tokens, which keeps the prompt
    /// below the 100k-token price step); longer days are summarized from the digest and meeting notes alone.
    public static let maxFinalTranscriptChars = 200_000
    public static let noChange = "NO_CHANGE"

    /// Weight of one entry for the cadence: its text, or a fixed amount for a meeting marker so it gets in.
    static func weight(_ entry: DayEntry) -> Int {
        switch entry.kind {
        case .speech: return entry.text.count
        case .meeting: return minNewChars
        case .dataProtection: return 0
        }
    }

    public static func shouldUpdate(pending: [DayEntry], state: DayState, now: Date = Date()) -> Bool {
        let chars = pending.reduce(0) { $0 + weight($1) }
        guard chars >= minNewChars, let first = pending.first, let last = pending.last else { return false }
        if chars >= volumeChars { return true }
        let sinceUpdate = now.timeIntervalSince(state.digestUpdatedAt ?? first.start)
        guard sinceUpdate >= minInterval else { return false }
        return now.timeIntervalSince(last.end) >= idleSeconds || sinceUpdate >= maxInterval
    }

    /// Entries not yet in the digest, with the day's state.
    public func pendingAndState(_ day: String) -> (pending: [DayEntry], state: DayState) {
        let (entries, state) = store.snapshot(day)
        return (Array(entries.dropFirst(state.digestedEntries)), state)
    }

    // MARK: Rolling digest

    public struct UpdateResult: Sendable {
        public var calls = 0
        public var unchanged = 0
        public var inputTokens = 0
        public var outputTokens = 0
        public var costUSD = 0.0
    }

    /// Folds all pending transcript into the digest, in blocks of at most `maxBlockChars`.
    @discardableResult
    public func update(_ day: String) async throws -> UpdateResult {
        let client = try Self.client(settings)
        var result = UpdateResult()
        while true {
            let (all, startState) = store.snapshot(day)
            let done = min(startState.digestedEntries, all.count)
            let pending = Array(all[done...])
            guard !pending.isEmpty else { break }
            var block: [DayEntry] = []
            var chars = 0
            for entry in pending {
                if !block.isEmpty, chars + entry.text.count > Self.maxBlockChars { break }
                block.append(entry)
                chars += entry.text.count
            }
            let digest = store.read("digest.md", day: day) ?? ""
            let messages = Self.updateMessages(
                day: day, digest: digest, block: block, before: Array(all[..<done].suffix(12)), settings: settings,
                language: language(all),
                protectedAtStart: DayEntry.protectionActive(Array(all[..<done]), before: block.map(\.start).min() ?? .distantFuture))
            let completion: AnthropicClient.Completion
            do {
                completion = try await client.complete(system: messages.system, user: messages.user, maxTokens: 16_000)
            } catch AnthropicError.refusal {
                // Retrying the same stretch would be declined again and block every later update: skip it.
                log.warning("digest \(day): the model declined a stretch of \(block.count) entries; skipped")
                store.updateState(day) { s in
                    if s.generation == startState.generation { s.digestedEntries = done + block.count }
                    s.lastError = "The model declined to summarize part of the transcript; that part was skipped."
                }
                continue
            } catch {
                store.updateState(day) { $0.lastError = error.localizedDescription }
                throw error
            }
            let text = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let unchanged = text == Self.noChange || text.hasPrefix(Self.noChange)
            var discarded = false
            store.updateState(day) { s in
                // The user forgot part of the transcript while this call ran: drop its result, count the cost.
                if s.generation != startState.generation {
                    discarded = true
                } else {
                    if !unchanged, !text.isEmpty { try? store.write(text + "\n", to: "digest.md", day: day) }
                    s.digestedEntries = done + block.count
                }
                s.digestUpdatedAt = Date()
                s.digestUpdates += 1
                s.inputTokens += completion.inputTokens
                s.outputTokens += completion.outputTokens
                s.costUSD += completion.costUSD
                s.lastError = nil
            }
            result.calls += 1
            result.unchanged += unchanged ? 1 : 0
            result.inputTokens += completion.inputTokens
            result.outputTokens += completion.outputTokens
            result.costUSD += completion.costUSD
            log.info(
                "digest \(day): \(block.count) entries (\(chars) chars) in \(String(format: "%.1f", completion.seconds)) s, \(discarded ? "discarded (transcript changed)" : unchanged ? "no change" : "updated"), \(completion.inputTokens) in / \(completion.outputTokens) out, $\(String(format: "%.4f", completion.costUSD))")
        }
        return result
    }

    // MARK: End of day

    /// Writes summary.md from the digest, the day's meeting notes and (when it fits) the full transcript.
    @discardableResult
    public func finalize(_ day: String, meetings: [(meeting: Meeting, notes: String)]) async throws -> AnthropicClient.Completion {
        let client = try Self.client(settings)
        let entries = store.entries(day)
        guard entries.contains(where: { $0.kind == .speech }) || !meetings.isEmpty else { throw AnthropicError.emptyTranscript }
        let messages = Self.finalMessages(
            day: day, digest: store.read("digest.md", day: day) ?? "", entries: entries, meetings: meetings,
            settings: settings, language: language(entries))
        let completion = try await client.complete(system: messages.system, user: messages.user, maxTokens: 24_000)
        try store.write(completion.text + "\n", to: "summary.md", day: day)
        store.updateState(day) { s in
            s.summaryWrittenAt = Date()
            s.inputTokens += completion.inputTokens
            s.outputTokens += completion.outputTokens
            s.costUSD += completion.costUSD
        }
        log.info(
            "day summary \(day) in \(String(format: "%.1f", completion.seconds)) s: \(completion.inputTokens) in / \(completion.outputTokens) out, $\(String(format: "%.4f", completion.costUSD))")
        return completion
    }

    /// Finished meetings of that day with their notes, for the end-of-day summary.
    public static func meetings(on day: String, in library: MeetingStore) -> [(meeting: Meeting, notes: String)] {
        library.list()
            .filter { DayStore.key(for: $0.startedAt) == day && $0.status == .done }
            .sorted { $0.startedAt < $1.startedAt }
            .compactMap { m in library.read("summary.md", for: m).map { (m, $0) } }
    }

    // MARK: Prompts

    static func client(_ settings: AppSettings) throws -> AnthropicClient {
        guard settings.llmProvider == .anthropic, let key = Keychain.resolvedAPIKey() else { throw AnthropicError.missingKey }
        return AnthropicClient(apiKey: key, model: AppSettings.summaryModel, effort: AppSettings.summaryEffort)
    }

    /// The notes language: the setting, or the language the user speaks (microphone), not that of videos playing.
    func language(_ entries: [DayEntry]) -> String {
        guard settings.summaryLanguage == "auto" else { return settings.summaryLanguage }
        let mic = entries.filter { $0.kind == .speech && $0.channel == .me }
        let sample = (mic.isEmpty ? entries : mic).prefix(400)
        return Summarizer.detectLanguage(sample.map { TranscriptSegment(channel: $0.channel ?? .me, speaker: $0.source, start: 0, end: 0, text: $0.text) })
    }

    struct Headings {
        var overview, timeline, actions, decisions, questions, summary, unsure: String

        init(_ language: String) {
            if language == "German" {
                (overview, timeline, actions, decisions, questions, summary, unsure) =
                    ("Überblick", "Verlauf", "Aufgaben", "Entscheidungen", "Offene Fragen", "Zusammenfassung", "unsicher")
            } else {
                (overview, timeline, actions, decisions, questions, summary, unsure) =
                    ("Overview", "Timeline", "Action items", "Decisions", "Open questions", "Summary", "uncertain")
            }
        }
    }

    /// Shared description of the transcript and of what counts as noise, used by both prompts.
    static let sourceRules = """
        ## The transcript
        Each line is "[HH:MM:SS] Source: text" in local time.
        - "Mic" is the Mac's microphone: usually the user, but also anyone near them (colleagues, visitors, family, \
        the other side of a phone call on speaker) and any TV, radio or music in the room.
        - "Mac" is sound the computer played: the other side of calls and video meetings, but also videos, podcasts, \
        music, games and notification sounds.
        - A line "— Meeting recorded separately: <title> (HH:MM–HH:MM) —" means that meeting was recorded with its \
        own notes while passive capture paused.
        - Speakers are not identified beyond these two sources. Work out who is talking from the content: names \
        used, who answers whom, the user's background. In a call, Mic lines are usually the user and Mac lines \
        the other side.
        - The text comes from speech recognition, which mishears names and invents words in music and noise. \
        Correct obvious errors silently using the glossary and background; never quote gibberish.

        ## What matters
        - Conversations the user takes part in: calls, video meetings that were not recorded separately, talks \
        with people in the room, and notes the user dictates to themselves.
        - From them: decisions and agreements; tasks, above all anything the user promised to do ("I'll send you \
        the deck tomorrow") or was asked to do; deadlines, dates and appointments; important numbers; people, \
        companies and projects; ideas the user expressed; open questions.

        ## What is noise
        Leave it out entirely, and do not mention that you left something out:
        - Media the user listens to without taking part: videos, podcasts, news, TV, films, music and lyrics, ads, \
        audiobooks, games. Typical signs: polished or scripted monologue, presenter or narrator tone, lyrics, no \
        reply from Mic. If the user reacts with something work-related ("we should use that in the pitch"), keep \
        the user's point in one line.
        - Small talk, greetings, filler, routine logistics (coffee, lunch, "can you hear me"), the user talking to \
        pets or children, and conversations between other people that do not involve the user.
        - Fragments too short or garbled to understand on their own.
        - Personal and sensitive matters (health, family, relationships, money) unless they produce a concrete task \
        or appointment for the user; then keep only what the task needs.
        """

    /// Added to the source rules when the day has Data Protection stretches.
    static let dataProtectionRules = """
        ## Data Protection stretches
        Between "— Data Protection on … —" and "— Data Protection off … —" (or the end of the transcript), only \
        the microphone was transcribed; sound the Mac played was deliberately not recorded. In calls and video \
        meetings there you have only the user's side (and people in the same room):
        - Infer what the other side said or asked from the user's replies where that is clear, and phrase it as \
        inferred ("the client apparently asked for …"). Never invent their statements, numbers or commitments; \
        what they promised counts only when the user repeats or confirms it.
        - Tasks the user took on are certain. Without Mac lines, a monologue on Mic is more likely the user on a \
        call than media, unless it sounds like TV or radio in the room.
        - Do not mention the markers themselves or that a side is missing, except once where it matters for an item.
        """

    static let digestInstructions = """
        You keep a running digest of the user's working day. Their Mac transcribes its microphone and its own sound \
        output all day, so most of the transcript is noise. Every so often you receive the current digest and the \
        newest stretch of transcript, and you return the complete updated digest.

        {SOURCE_RULES}

        ## Rules
        - Use only what the transcript and the background say. Never invent names, numbers, owners, dates or \
        deadlines.
        - When you are unsure whether something was a real conversation or media, or who said it, include it only \
        if it would matter, and mark it "({UNSURE})".
        - Keep every item of the current digest unless the new transcript corrects, completes or settles it; then \
        change it in place (for example tick off a task reported as done with "- [x]"). Merge duplicates. Never \
        drop earlier items silently.
        - The lines under "Just before" were already processed; they are there only so you understand a \
        conversation that continues into the new stretch.
        - Separately recorded meetings go into the timeline as one line with time and title; do not guess their \
        content.
        - Keep it short and skimmable: the whole digest should stay under about 700 words even on a busy day. \
        When space runs short, compress finished topics from earlier in the day to one line each.
        - Write in {LANGUAGE}, including the headings. Keep established English technical terms. Refer to the user \
        in the third person by the first name given in the background, never as "I" or "me".
        - If the new stretch contains nothing that matters and nothing that changes the digest, reply with exactly \
        {NO_CHANGE} and nothing else.

        ## Output
        Markdown in exactly this structure. Omit a section when it is empty, except the first:

        ## {H_OVERVIEW}
        1–3 sentences: what the day has been about so far.

        ## {H_TIMELINE}
        - **HH:MM–HH:MM** Topic, with whom if known
          - one or two short sub-bullets with the substance
        (one bullet per relevant conversation or block of work, in order)

        ## {H_ACTIONS}
        - [ ] **Owner**: task (deadline if one was stated)
        (the user's own commitments first)

        ## {H_DECISIONS}
        - Decisions and agreements, one line each.

        ## {H_QUESTIONS}
        - Unresolved points and things to follow up.
        """

    static let finalInstructions = """
        You write the end-of-day summary of the user's working day, to be read the next morning: what happened, \
        what was decided, what they have to do. Their Mac transcribed its microphone and its own sound output all \
        day. You get the running digest written during the day, the notes of meetings recorded separately, and, \
        when it fits, the full transcript, which is mostly noise.

        {SOURCE_RULES}

        ## Rules
        - The digest was written piece by piece and can contain mistakes, duplicates or gaps. When the transcript \
        is included, check the digest against it, fix errors, merge duplicates and add what matters but is missing.
        - Put the separately recorded meetings into the timeline and take over their decisions and the user's \
        action items, without repeating their notes in full.
        - Use only what the inputs say. Never invent names, numbers, owners, dates or deadlines. Mark uncertain \
        items "({UNSURE})".
        - Write in {LANGUAGE}, including the headings. Keep established English technical terms. Refer to the user \
        in the third person by the first name given in the background, never as "I" or "me".
        - Be concise and specific; prefer one precise line over three vague ones.

        ## Output
        Markdown in exactly this structure. Omit a section when it is empty, except the summary:

        # <short, specific title for the day>

        ## {H_SUMMARY}
        3–5 sentences: the day's main threads, outcomes and the most important next steps.

        ## {H_TIMELINE}
        - **HH:MM–HH:MM** Topic, with whom if known: one line of substance
        (conversations and recorded meetings, in order)

        ## {H_ACTIONS}
        - [ ] **Owner**: task (deadline if one was stated)
        (the user's own open tasks first; tasks settled during the day as "- [x]")

        ## {H_DECISIONS}
        - Decisions and agreements, one line each.

        ## {H_QUESTIONS}
        - Unresolved points and things to follow up.
        """

    static func fill(_ template: String, language: String, dataProtection: Bool = false) -> String {
        let h = Headings(language)
        return template
            .replacingOccurrences(of: "{SOURCE_RULES}", with: sourceRules + (dataProtection ? "\n\n" + dataProtectionRules : ""))
            .replacingOccurrences(of: "{LANGUAGE}", with: language)
            .replacingOccurrences(of: "{NO_CHANGE}", with: noChange)
            .replacingOccurrences(of: "{UNSURE}", with: h.unsure)
            .replacingOccurrences(of: "{H_OVERVIEW}", with: h.overview)
            .replacingOccurrences(of: "{H_TIMELINE}", with: h.timeline)
            .replacingOccurrences(of: "{H_ACTIONS}", with: h.actions)
            .replacingOccurrences(of: "{H_DECISIONS}", with: h.decisions)
            .replacingOccurrences(of: "{H_QUESTIONS}", with: h.questions)
            .replacingOccurrences(of: "{H_SUMMARY}", with: h.summary)
    }

    static func header(day: String, settings: AppSettings) -> String {
        var user = "## Day\n"
        if let date = DayStore.date(for: day) {
            user += date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()) + ". Times are local.\n"
        }
        let background = Summarizer.background(settings: settings)
        if !background.isEmpty { user += "\n## Background about the user\n\(background)\n" }
        let vocabulary = AppPaths.vocabularyTerms().map(\.term)
        if !vocabulary.isEmpty { user += "\n## Glossary (correct spellings)\n\(vocabulary.joined(separator: ", "))\n" }
        return user
    }

    /// Lines in time order (microphone entries are stored up to 30 s late, after the echo check).
    static func transcript(_ entries: [DayEntry]) -> String {
        entries.sorted { $0.start < $1.start }.map { DayStore.markdownLine($0).trimmingCharacters(in: .newlines) }.joined(separator: "\n")
    }

    static func updateMessages(
        day: String, digest: String, block: [DayEntry], before: [DayEntry], settings: AppSettings, language: String,
        protectedAtStart: Bool = false
    ) -> (system: String, user: String) {
        var user = header(day: day, settings: settings)
        let current = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        user += "\n## Current digest\n\(current.isEmpty ? "(empty: this is the first update today)" : current)\n"
        if !before.isEmpty { user += "\n## Just before (already processed)\n\(transcript(before))\n" }
        var span = ""
        if let first = block.map(\.start).min(), let last = block.map(\.end).max() {
            span = "\(DayStore.clock(first, seconds: false))–\(DayStore.clock(last, seconds: false))"
        }
        // The marker that switched Data Protection on may lie in an earlier stretch: repeat it at the top.
        var lines = transcript(block)
        if protectedAtStart {
            lines = "— \(DayStore.protectionText(true)) (since earlier) —\n" + lines
        }
        user += "\n## New transcript \(span)\n\(lines)\n"
        let protected = protectedAtStart || block.contains { $0.kind == .dataProtection }
        return (fill(digestInstructions, language: language, dataProtection: protected), user)
    }

    static func finalMessages(
        day: String, digest: String, entries: [DayEntry], meetings: [(meeting: Meeting, notes: String)],
        settings: AppSettings, language: String
    ) -> (system: String, user: String) {
        var user = header(day: day, settings: settings)
        let current = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        user += "\n## Running digest\n\(current.isEmpty ? "(none)" : current)\n"
        if !meetings.isEmpty {
            user += "\n## Meetings recorded separately\n"
            for (m, notes) in meetings {
                let end = m.endedAt.map { "–" + DayStore.clock($0, seconds: false) } ?? ""
                user += "\n### \(DayStore.clock(m.startedAt, seconds: false))\(end) \(m.title)\n"
                user += String(notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(6_000)) + "\n"
            }
        }
        let text = transcript(entries)
        if text.count <= maxFinalTranscriptChars {
            user += "\n## Full transcript\n\(text)\n"
        } else {
            user += "\n## Full transcript\n(omitted: too long; rely on the digest)\n"
        }
        let protected = entries.contains { $0.kind == .dataProtection && $0.text == "on" }
        return (fill(finalInstructions, language: language, dataProtection: protected), user)
    }
}
