import MinutesCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var passive: PassiveModel
    @Local private var search = ""
    @Local private var importing = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            if let day = DayID.day(model.selection) {
                DayView(day: day)
                    .id(day)
            } else if let meeting = model.meeting(model.selection) {
                MeetingDetailView(meeting: meeting)
                    .id(meeting.id)
            } else {
                EmptyStateView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    importing = true
                } label: { Label("Import audio", systemImage: "square.and.arrow.down") }
                .help("Transcribe an existing recording (one mixed file, or mic + system tracks)")
                RecordButton()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
                model.importAudio(urls)
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
            }
        }
        .onAppear {
            if model.selection == nil { model.selection = model.meetings.first?.id }
            model.refreshEvents()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        .confirmationDialog(
            "Delete “\(model.confirmDelete?.title ?? "")”?",
            isPresented: Binding(get: { model.confirmDelete != nil }, set: { if !$0 { model.confirmDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let m = model.confirmDelete { model.delete(m) }
                model.confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { model.confirmDelete = nil }
        } message: {
            Text(model.settings.notesRepository.isEmpty
                ? "The meeting folder moves to the Trash."
                : "The meeting folder moves to the Trash and the meeting is removed from the notes repository (it stays in the repository's history).")
        }
    }

    private var filtered: [Meeting] {
        guard !search.isEmpty else { return model.meetings }
        return model.meetings.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || ($0.calendarEventTitle ?? "").localizedCaseInsensitiveContains(search)
                || $0.attendees.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    /// One date in the sidebar: the day's passive notes (if any) and its meetings.
    private struct DateSection: Identifiable {
        let id: Date
        let label: String
        /// Day key if passive mode has data for this date (or is on today).
        let day: String?
        let meetings: [Meeting]
    }

    private var sections: [DateSection] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.startedAt) }
        // Day notes are not searched, so they only show in the unfiltered list.
        var passiveDays: [Date: String] = [:]
        if search.isEmpty {
            for day in passive.days + (passive.isEnabled ? [passive.today] : []) {
                if let date = DayStore.date(for: day) { passiveDays[cal.startOfDay(for: date)] = day }
            }
        }
        return Set(groups.keys).union(passiveDays.keys).sorted(by: >).map { date in
            let label: String
            if cal.isDateInToday(date) {
                label = "Today"
            } else if cal.isDateInYesterday(date) {
                label = "Yesterday"
            } else {
                label = date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
            }
            return DateSection(
                id: date, label: label, day: passiveDays[date],
                meetings: (groups[date] ?? []).sorted { $0.startedAt > $1.startedAt })
        }
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            if model.isRecording, let rec = model.recording {
                Section {
                    HStack {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        Text(rec.meeting.title).lineLimit(1)
                        Spacer()
                        Text(clock(model.elapsed)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(rec.meeting.id)
                } header: { Text("Recording now") }
                .collapsible(false)
            }
            ForEach(sections) { section in
                Section(section.label) {
                    if let day = section.day {
                        DayRow(day: day).tag(DayID.id(day))
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([passive.store.folder(day)]) }
                                Divider()
                                Button("Delete…", role: .destructive) { passive.confirmDeleteDay = day }
                            }
                    }
                    ForEach(section.meetings) { meeting in
                        if model.recording?.meeting.id != meeting.id {
                            MeetingRow(meeting: meeting).tag(meeting.id)
                                .contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.folder(for: meeting)]) }
                                    Button("Regenerate notes") { model.regenerateSummary(meeting) }
                                    Button("Continue recording") { Task { await model.resumeRecording(meeting) } }
                                        .disabled(model.isRecording)
                                    if model.previousMeeting(before: meeting) != nil {
                                        Button("Merge with previous meeting") { model.mergeWithPrevious(meeting) }
                                    }
                                    Button("Re-transcribe from audio") { model.retranscribe(meeting) }
                                        .disabled(!model.hasAudio(meeting))
                                    Divider()
                                    Button("Delete…", role: .destructive) { model.confirmDelete = meeting }
                                }
                        }
                    }
                }
                // Sidebar sections fold away with one click on their header, which hides that day's meetings.
                .collapsible(false)
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search meetings")
        .onDeleteCommand {
            if let day = DayID.day(model.selection) {
                passive.confirmDeleteDay = day
            } else if let m = model.meeting(model.selection), model.recording?.meeting.id != m.id {
                model.confirmDelete = m
            }
        }
        .overlay {
            if sections.isEmpty && !model.isRecording {
                if search.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "waveform", description: Text("Join a call or press ⇧⌘R."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .confirmationDialog(
            "Delete the day notes of \(dayLabel(passive.confirmDeleteDay))?",
            isPresented: Binding(get: { passive.confirmDeleteDay != nil }, set: { if !$0 { passive.confirmDeleteDay = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let day = passive.confirmDeleteDay { passive.deleteDay(day) }
                passive.confirmDeleteDay = nil
            }
            Button("Cancel", role: .cancel) { passive.confirmDeleteDay = nil }
        } message: {
            Text("The day's passive transcript and notes move to the Trash. Meetings recorded on that day are kept.")
        }
    }

    /// Passive mode and Settings, always reachable from the main window (the menu bar window has the same controls).
    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let app = model.detectedApp, !model.isRecording {
                    DetectionCard(app: app)
                }
                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
                        .help("Click to dismiss")
                        .onTapGesture { model.lastError = nil }
                }
                PassiveControl(showOpenToday: false)
                Divider()
                HStack {
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                        .help("Notes and API key, background, calendar, passive mode, sync (⌘,)")
                    Spacer()
                    if let status = model.modelStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func dayLabel(_ day: String?) -> String {
        guard let day, let date = DayStore.date(for: day) else { return "" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// Record / Stop for the main window's toolbar. The arrow offers the same choices as the menu bar window.
struct RecordButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.isRecording {
            Button {
                Task { await model.stopRecording() }
            } label: { Label("Stop", systemImage: "stop.circle.fill") }
            .tint(.red)
            .help("Stop recording (⇧⌘R)")
        } else if model.currentEvent == nil && model.otherEvents.isEmpty {
            Button {
                Task { await model.startRecording() }
            } label: { Label("Record", systemImage: "record.circle") }
            .help("Start recording (⇧⌘R)")
        } else {
            Menu {
                RecordChoices()
            } label: {
                Label("Record", systemImage: "record.circle")
            } primaryAction: {
                Task { await model.startRecording() }
            }
            .help(
                model.currentEvent.map { "Start recording (⇧⌘R), linked to “\($0.title)”. The arrow offers other events, or none." }
                    ?? "Start recording (⇧⌘R). The arrow links it to one of today's calendar events.")
        }
    }
}

/// What a new recording can be linked to: the calendar event running now, another of today's events, or nothing.
struct RecordChoices: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let current = model.currentEvent {
            Button("Record “\(current.title)” (in your calendar now)") { Task { await model.startRecording() } }
            Button("Record without a calendar event") { Task { await model.startRecording(event: .none) } }
        } else {
            Button("Record without a calendar event") { Task { await model.startRecording(event: .none) } }
        }
        if !model.otherEvents.isEmpty {
            Section(model.currentEvent == nil ? "Record for an event in today's calendar" : "Other events today") {
                ForEach(model.otherEvents) { event in
                    Button("\(event.start.formatted(date: .omitted, time: .shortened))  \(event.title)") {
                        Task { await model.startRecording(event: .event(event)) }
                    }
                }
            }
        }
    }
}

struct MeetingRow: View {
    @EnvironmentObject var model: AppModel
    var meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(meeting.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                if meeting.status != .done { StatusDot(status: meeting.status) }
            }
            HStack(spacing: 6) {
                Text(meeting.startedAt, format: .dateTime.hour().minute())
                if let d = meeting.duration { Text("· \(Int(max(1, d / 60))) min") }
                if let app = meeting.sourceApp { Text("· \(app)") }
            }
            .lineLimit(1)
            .font(.caption)
            .foregroundStyle(.secondary)
            if let stage = model.stageText[meeting.id] {
                Text(stage).font(.caption2).foregroundStyle(.orange).lineLimit(1)
            }
        }
        // A list row can be laid out with a stale, very narrow width after its content changes (a new title, a
        // stage line that comes and goes); filling the row and never wrapping keeps it readable.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Minutes").font(.largeTitle.weight(.semibold))
            Text("Meetings are detected automatically when a call app uses your microphone.\nOr start recording yourself.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                Task { await model.startRecording() }
            } label: { Label("Start recording", systemImage: "record.circle") }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if let status = model.modelStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(40)
    }
}
