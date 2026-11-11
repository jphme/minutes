import AppKit
import MinutesCore
import SwiftUI

/// Passive mode's switch, status and quick actions. The menu bar window and the main window's sidebar show the
/// same control.
struct PassiveControl: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var passive: PassiveModel
    /// Offer a button that opens today's day notes (the menu bar; in the sidebar the row is right there).
    var showOpenToday = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: passive.isListening ? "ear.badge.waveform" : "ear")
                    .foregroundStyle(passive.isListening ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("Passive mode")
                        if passive.isEnabled && passive.protectedToday {
                            Image(systemName: "lock.shield.fill").font(.caption).foregroundStyle(.secondary)
                                .help("Data Protection: only the microphone is transcribed today")
                        }
                    }
                    Text(passive.statusText).font(.caption).foregroundStyle(statusColor).lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { passive.isEnabled }, set: { passive.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Transcribe everything all day into day notes (text only)")
            }
            if passive.isEnabled {
                HStack(spacing: 10) {
                    PassivePauseButton()
                    Button("Forget last 15 min") { passive.forget(minutes: 15) }
                        .help("Delete what was transcribed in the last 15 minutes")
                    Spacer()
                    if showOpenToday {
                        Button("Day notes") {
                            model.selection = DayID.id(passive.today)
                            WindowOpener.openMain()
                        }
                        .help("Open today's notes and transcript")
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
        }
    }

    private var statusColor: Color {
        if case .failed = passive.state { return .orange }
        return .secondary
    }
}

/// "Pause ▾" with durations, or "Resume" while paused by the user.
struct PassivePauseButton: View {
    @EnvironmentObject var passive: PassiveModel

    var body: some View {
        if case .paused(.user) = passive.state {
            Button("Resume") { passive.resume() }
        } else {
            Menu("Pause") { PassivePauseItems() }.fixedSize()
        }
    }
}

struct PassivePauseItems: View {
    @EnvironmentObject var passive: PassiveModel

    var body: some View {
        Button("Pause for 15 minutes") { passive.pause(minutes: 15) }
        Button("Pause for 1 hour") { passive.pause(minutes: 60) }
        Button("Pause until tomorrow") { passive.pause(minutes: nil) }
    }
}

/// Settings → General: passive mode switch, energy and privacy options.
struct PassiveSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var passive: PassiveModel

    var body: some View {
        Section {
            Toggle("Passive mode: transcribe all day into day notes", isOn: Binding(
                get: { passive.isEnabled }, set: { passive.setEnabled($0) }))
            Toggle("Pause while the screen is locked", isOn: $model.settings.passivePauseWhenLocked)
                .disabled(!passive.isEnabled)
            Picker("Pause on battery", selection: $model.settings.passiveBatteryThreshold) {
                Text("Never").tag(0)
                Text("Below 50 %").tag(50)
                Text("Below 20 %").tag(20)
                Text("Always").tag(100)
            }
            .disabled(!passive.isEnabled)
        } header: {
            Text("Passive mode")
        } footer: {
            Text("""
                Listens to the microphone and to what your Mac plays whenever no meeting is being recorded, and keeps \
                only text (Days/ in the library; audio is never written to disk). Every 10–30 minutes of new speech, \
                Claude updates the day's notes and filters out videos, music, small talk and other noise (a few cents \
                per day); a day summary follows after midnight. It records people who may not know it: tell them, \
                and pause when someone objects (§ 201 StGB in Germany). Uses about 2–5 % of one CPU core, including \
                Core Audio; while today's transcript is on screen, lines appear as they are spoken, which costs a \
                little more.
                """)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One day of passive mode. Laid out like a meeting: title and facts on top, Notes and Transcript tabs, and the
/// same toolbar (copy notes, copy transcript, update notes, more, delete).
struct DayView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var passive: PassiveModel
    let day: String

    enum Tab: String, CaseIterable { case notes = "Notes", transcript = "Transcript" }
    @Local private var tab: Tab
    @Local private var channel: Channel? = nil
    @Local private var search = ""
    @Local private var followLive = true
    @Local private var copied: String?

    init(day: String, tab: Tab = .notes) {
        self.day = day
        _tab = Local(wrappedValue: tab)
    }

    private var isToday: Bool { day == passive.today }
    private var store: DayStore { passive.store }
    private var isBusy: Bool { passive.busy[day] != nil }
    /// Today: the mode capture runs in. Another day: whether any part of it was transcribed in Data Protection mode.
    private var isProtected: Bool {
        isToday ? passive.protectedToday : entries.contains { $0.kind == .dataProtection && $0.text == "on" }
    }
    private var entries: [DayEntry] {
        let all = isToday ? passive.todayEntries : store.entries(day)
        return all.sorted { $0.start < $1.start }
    }

    private func text(_ file: String) -> String? {
        _ = passive.revision
        let t = store.read(file, day: day)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    /// The Notes tab leads with the finished day's summary, and with the running digest while the day is going on
    /// (a summary written on demand during the day is older than the digest).
    private var summaryLeads: Bool { !isToday && text("summary.md") != nil }
    private var leading: String? { summaryLeads ? text("summary.md") : text("digest.md") }
    private var other: String? { summaryLeads ? text("digest.md") : text("summary.md") }

    var body: some View {
        let state = store.loadState(day)
        VStack(spacing: 0) {
            header(state)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 10)
            Divider()
            Group {
                switch tab {
                case .notes: notesTab(state)
                case .transcript: transcriptTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                DataProtectionToggle(
                    isOn: isProtected, enabled: isToday && passive.isEnabled,
                    help: !isToday
                        ? (isProtected ? "Parts of this day were transcribed with Data Protection: microphone only." : "Data Protection can be switched only for today.")
                        : !passive.isEnabled ? "Turn on passive mode to use Data Protection for today."
                        : (isProtected ? DataProtectionToggle.onHelp : DataProtectionToggle.offHelp)
                            + " Applies to today from now on; the default is in Settings."
                ) { passive.setDataProtection($0) }
                // Copies what the open tab shows. Any part of either can also be selected and copied directly.
                Button { if tab == .notes { copyNotes() } else { copyTranscript() } } label: {
                    Label(tab == .notes ? "Copy notes" : "Copy transcript", systemImage: copied != nil ? "checkmark" : "doc.on.doc")
                }
                .help(tab == .notes ? "Copy the notes as Markdown" : "Copy the transcript with times and sources")
                .disabled(tab == .notes ? leading == nil : entries.isEmpty)
                Button { updateNotes() } label: { Label("Update notes", systemImage: "sparkles") }
                    .help(
                        !model.hasAPIKey ? "Add an Anthropic API key in Settings → Notes to write notes"
                            : isToday ? "Fold the new transcript into the day's notes now"
                            : "Write the day summary again from the transcript")
                    .disabled(isBusy || !model.hasAPIKey || entries.isEmpty)
                Menu {
                    Button("Update running notes now") { passive.updateDigest(day) }
                        .disabled(isBusy || !model.hasAPIKey)
                    Button("Write day summary now") { passive.writeSummary(day) }
                        .disabled(isBusy || !model.hasAPIKey)
                    if isToday, passive.isEnabled {
                        Divider()
                        if case .paused(.user) = passive.state {
                            Button("Resume listening") { passive.resume() }
                        } else {
                            PassivePauseItems()
                        }
                        Button("Forget last 15 minutes") { passive.forget(minutes: 15) }
                    }
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.folder(day)]) }
                    Divider()
                    Button("Delete…", role: .destructive) { passive.confirmDeleteDay = day }.disabled(isBusy)
                } label: { Label("More", systemImage: "ellipsis.circle") }
                Button { passive.confirmDeleteDay = day } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete this day's transcript and notes")
                    .disabled(isBusy || entries.isEmpty)
            }
        }
    }

    // MARK: Header

    private func header(_ state: DayState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Day notes").font(.system(size: 24, weight: .semibold))
            HStack(spacing: 10) {
                Label(dateText, systemImage: "calendar")
                if isToday {
                    Label(passive.isEnabled ? passive.statusText : "Passive mode is off", systemImage: passive.isListening ? "ear.badge.waveform" : "ear")
                        .foregroundStyle(passive.isListening ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Label(speech, systemImage: "waveform")
                if let at = state.digestUpdatedAt {
                    Label("Notes updated \(at.formatted(date: .omitted, time: .shortened))", systemImage: "sparkles")
                        .help("\(state.digestUpdates) updates so far" + (state.costUSD > 0 ? String(format: ", $%.3f", state.costUSD) : ""))
                }
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .labelsHidden()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if isToday && isProtected {
                DataProtectionNote(live: passive.isListening).font(.callout).foregroundStyle(.secondary)
            }
            if let busy = passive.busy[day] {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout)
                }
                .padding(.top, 2)
            } else if let error = state.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private var dateText: String {
        guard let date = DayStore.date(for: day) else { return day }
        let text = date.formatted(.dateTime.weekday().day().month().year())
        return isToday ? "Today, \(text)" : text
    }

    private var speech: String {
        let seconds = entries.filter { $0.kind == .speech }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min speech" : "\(minutes) min speech"
    }

    // MARK: Notes tab

    private func notesTab(_ state: DayState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let leading {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(summaryLeads ? "Day summary" : isToday ? "Running notes, updated as the day goes on" : "Running notes")
                            .font(.caption).foregroundStyle(.secondary)
                        MarkdownView(markdown: leading)
                    }
                } else {
                    placeholder(state)
                }
                if let other {
                    DisclosureGroup(summaryLeads ? "Running notes of that day" : "Day summary so far") {
                        MarkdownView(markdown: other).padding(.top, 8)
                    }
                    .font(.headline)
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func placeholder(_ state: DayState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.hasAPIKey {
                Text("The transcript is in the Transcript tab. To get written notes as well, add an Anthropic API key in Settings → Notes.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Show transcript") { tab = .transcript }
                    SettingsLink { Text("Open Settings…") }
                }
            } else if isBusy {
                Text("Notes will appear here in a moment.").foregroundStyle(.secondary)
            } else if entries.isEmpty {
                Text(isToday && passive.isEnabled
                    ? "Nothing transcribed yet today. Notes appear after the first conversation."
                    : "Nothing was transcribed on this day.")
                    .foregroundStyle(.secondary)
            } else if state.digestUpdates > 0 {
                Text("Nothing worth noting so far: everything transcribed was filtered out as noise.").foregroundStyle(.secondary)
                Button("Show transcript") { tab = .transcript }
            } else {
                Text(isToday
                    ? "Notes appear about 10 minutes after new speech, or after a 5-minute pause."
                    : "No notes yet for this day.")
                    .foregroundStyle(.secondary)
                Button("Write notes now") { updateNotes() }
            }
        }
    }

    // MARK: Transcript tab

    /// One line of the transcript: a stored entry, or (today) an utterance that is not stored yet.
    private struct Line: Identifiable {
        let id: UUID
        let start: Date
        let entry: DayEntry?
        let channel: Channel?
        let text: String
        let settled: Bool
    }

    private var lines: [Line] {
        var all = entries.map { Line(id: $0.id, start: $0.start, entry: $0, channel: $0.channel, text: $0.text, settled: true) }
        if isToday {
            let stored = Set(all.map(\.id))
            all += passive.previews.filter { !stored.contains($0.id) }.map {
                Line(id: $0.id, start: $0.start, entry: nil, channel: $0.channel, text: $0.text, settled: false)
            }
            all.sort { $0.start < $1.start }
        }
        return all.filter { line in
            let isMarker = line.entry.map { $0.kind != .speech } ?? false
            if let channel, !isMarker, line.channel != channel { return false }
            return search.isEmpty || line.text.localizedCaseInsensitiveContains(search)
        }
    }

    private var transcriptTab: some View {
        let shown = lines
        let live = isToday && passive.isEnabled
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcript", text: $search).textFieldStyle(.plain)
                Picker("", selection: $channel) {
                    Text("All").tag(Channel?.none)
                    Text("Mic").tag(Channel?.some(.me))
                    Text("Mac").tag(Channel?.some(.them))
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .labelsHidden()
                .help("Mic = what the microphone heard, Mac = sound your Mac played")
                if live { Toggle("Follow", isOn: $followLive).toggleStyle(.checkbox).font(.caption) }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        TranscriptText(
                            lines: shown.map(transcriptLine), timeWidth: 60,
                            empty: !search.isEmpty || channel != nil ? "No matching lines."
                                : live ? "Listening… the transcript appears as people speak." : "No transcript."
                        ) { url in
                            if url.scheme == "minutes-meeting", let id = UUID(uuidString: String(url.absoluteString.dropFirst("minutes-meeting:".count))) {
                                model.selection = id
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(24)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onAppear {
                    // Today opens at the newest line; a finished day reads from the top, like a meeting.
                    if isToday { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onChange(of: shown.count) { _, _ in
                    if live && followLive { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onChange(of: shown.last?.text) { _, _ in
                    if live && followLive { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        // Lines appear while they are spoken only as long as this tab is on screen (it costs extra work).
        .onAppear { if isToday { passive.transcriptVisible(true) } }
        .onDisappear { if isToday { passive.transcriptVisible(false) } }
    }

    private func transcriptLine(_ line: Line) -> TranscriptLine {
        if let entry = line.entry, entry.kind == .meeting {
            // A meeting recorded during the day: its own notes and transcript are one click away.
            let meeting = model.meetings.first { m in
                entry.meetingID.map { $0 == m.id }
                    ?? m.allParts.contains { abs($0.startedAt.timeIntervalSince(entry.start)) < 2 }
            }
            let range = "\(DayStore.clock(entry.start, seconds: false))–\(DayStore.clock(entry.end, seconds: false))"
            return TranscriptLine(
                text: "● Meeting recorded separately, \(range): \(meeting?.title ?? entry.text)" + (meeting == nil ? " (deleted)" : ""),
                isNote: true,
                link: meeting.flatMap { m in URL(string: "minutes-meeting:\(m.id.uuidString)").map { ("Open notes ›", $0) } })
        }
        if let entry = line.entry, entry.kind == .dataProtection {
            return TranscriptLine(
                time: DayStore.clock(entry.start, seconds: false),
                text: (entry.text == "on" ? "🔒 " : "") + DayStore.protectionText(entry.text == "on"), isNote: true)
        }
        return TranscriptLine(
            time: DayStore.clock(line.start), speaker: line.channel == .them ? "Mac" : "Mic",
            color: SpeakerColor.color(for: line.channel == .them ? "Them" : "Me"), text: line.text, settled: line.settled)
    }

    // MARK: Actions

    private func updateNotes() {
        if isToday { passive.updateDigest(day) } else { passive.writeSummary(day) }
    }

    private func copyNotes() {
        guard let leading else { return }
        copy("# Day notes \(day)\n\n\(leading)\n", as: "notes")
    }

    private func copyTranscript() {
        copy(entries.map { DayStore.markdownLine($0) }.joined(), as: "transcript")
    }

    private func copy(_ text: String, as kind: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = kind
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == kind { copied = nil } }
    }
}

/// Sidebar row for a day's passive notes; sits first in its date section, above that day's meetings.
struct DayRow: View {
    @EnvironmentObject var passive: PassiveModel
    let day: String

    private var isToday: Bool { day == passive.today }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: isToday && passive.isListening ? "ear.badge.waveform" : "ear")
                    .font(.callout)
                    .foregroundStyle(isToday && passive.isListening ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text("Day notes").font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                if passive.busy[day] != nil { ProgressView().controlSize(.mini) }
            }
            Text(passive.busy[day] ?? (isToday && passive.isEnabled ? passive.statusText : "Passive mode"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}
