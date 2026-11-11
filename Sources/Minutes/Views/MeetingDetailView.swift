import AppKit
import MinutesCore
import SwiftUI

struct MeetingDetailView: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting

    enum Tab: String, CaseIterable { case notes = "Notes", transcript = "Transcript" }
    @Local private var tab: Tab = .notes
    @Local private var title = ""
    @Local private var userNotes = ""
    @Local private var notesSaveTask: Task<Void, Never>?
    @Local private var copied: String?

    private var isLive: Bool { model.recording?.meeting.id == meeting.id }
    private var isBusy: Bool { model.stageText[meeting.id] != nil || [.processing, .summarizing].contains(meeting.status) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 10)
            Divider()
            Group {
                switch tab {
                case .notes: notesTab
                case .transcript: TranscriptView(meeting: meeting, live: isLive)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            title = meeting.title
            userNotes = model.notes(for: meeting)
            if isLive { tab = .notes }
        }
        .onChange(of: meeting.title) { _, new in title = new }
        .onDisappear { flushNotes() }
        .toolbar {
            ToolbarItemGroup {
                DataProtectionToggle(
                    isOn: meeting.isProtected, enabled: isLive,
                    help: isLive
                        ? (meeting.isProtected
                            ? DataProtectionToggle.onHelp + " Turn off to record the other participants from now on."
                            : DataProtectionToggle.offHelp + " Turning it on also drops what was recorded of them so far.")
                        : meeting.isProtected
                            ? "Recorded with Data Protection: only your microphone was transcribed."
                            : "Data Protection can be switched only while recording."
                ) { model.setDataProtection($0, for: meeting) }
                Button { copyNotes() } label: {
                    Label("Copy notes", systemImage: copied == "notes" ? "checkmark" : "doc.on.doc")
                }
                .help("Copy the notes as Markdown")
                .disabled(model.summary(for: meeting)?.isEmpty ?? true)
                Button { copyTranscript() } label: {
                    Label("Copy transcript", systemImage: copied == "transcript" ? "checkmark" : "text.quote")
                }
                .help("Copy the raw transcript with timestamps and speakers")
                if !isLive {
                    Button { model.regenerateSummary(meeting) } label: { Label("Regenerate notes", systemImage: "sparkles") }
                        .help(model.hasAPIKey
                            ? "Write the notes again from the transcript, your notes and the background"
                            : "Add an Anthropic API key in Settings → Notes to write notes")
                        .disabled(isBusy || !model.hasAPIKey)
                    Menu {
                        Button("Continue recording") { Task { await model.resumeRecording(meeting) } }
                            .disabled(model.isRecording)
                        if let previous = model.previousMeeting(before: meeting) {
                            Button("Merge with “\(previous.title)”") { model.mergeWithPrevious(meeting) }.disabled(isBusy)
                        }
                        Button("Re-transcribe from audio") { model.retranscribe(meeting) }
                            .disabled(isBusy || !model.hasAudio(meeting))
                        Divider()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.folder(for: meeting)]) }
                        Divider()
                        Button("Delete…", role: .destructive) { model.confirmDelete = meeting }
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                    Button { model.confirmDelete = meeting } label: { Label("Delete", systemImage: "trash") }
                        .help("Delete this meeting (also from the notes repository)")
                        .disabled(isBusy)
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .semibold))
                .onSubmit { model.rename(meeting, to: title) }
            HStack(spacing: 10) {
                Label(meeting.startedAt.formatted(.dateTime.weekday().day().month().year().hour().minute()), systemImage: "calendar")
                if isLive {
                    Label(clock(model.elapsed), systemImage: "record.circle.fill").foregroundStyle(.red)
                } else if let d = meeting.duration {
                    Label("\(Int(max(1, d / 60))) min", systemImage: "clock")
                }
                if let app = meeting.sourceApp { Label(app, systemImage: "video") }
                eventMenu
                if !meeting.attendees.isEmpty {
                    Label(meeting.attendees.prefix(4).joined(separator: ", ") + (meeting.attendees.count > 4 ? " +\(meeting.attendees.count - 4)" : ""), systemImage: "person.2")
                        .lineLimit(1)
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
            if meeting.isProtected {
                DataProtectionNote(live: isLive).font(.callout).foregroundStyle(.secondary)
            }
            if let stage = model.stageText[meeting.id] {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(stage).font(.callout)
                }
                .padding(.top, 2)
            } else if let error = meeting.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    /// Shows the linked calendar event and lets the user pick another one (or none).
    private var eventMenu: some View {
        Menu {
            let events = model.events(near: meeting)
            if events.isEmpty { Text("No calendar events around this time") }
            ForEach(events) { event in
                Button {
                    model.link(meeting, to: event)
                } label: {
                    let mark = meeting.calendarEventID == event.eventID ? "✓ " : ""
                    Text("\(mark)\(event.start.formatted(date: .omitted, time: .shortened))  \(event.title) (\(event.calendar))")
                }
            }
            Divider()
            Button("No calendar event") { model.link(meeting, to: nil) }.disabled(meeting.calendarEventTitle == nil)
        } label: {
            Label(meeting.calendarEventTitle == nil ? "Link event" : "Event", systemImage: "calendar.badge.clock")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(meeting.calendarEventTitle.map { "Linked to “\($0)”. Pick another calendar event." } ?? "Link this recording to a calendar event")
    }

    // MARK: Notes tab

    @ViewBuilder private var notesTab: some View {
        if isLive {
            HSplitView {
                notesEditor(prompt: "Write your own notes. They guide the summary after the meeting.")
                    .frame(minWidth: 300)
                TranscriptView(meeting: meeting, live: true, compact: true)
                    .frame(minWidth: 280)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let streaming = model.streamingSummary[meeting.id], !streaming.isEmpty {
                        MarkdownView(markdown: Summarizer.parse(streaming).markdown)
                    } else if let summary = model.summary(for: meeting), !summary.isEmpty {
                        MarkdownView(markdown: summary)
                    } else if isBusy {
                        Text("Notes will appear here when the transcript is ready.").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            if model.hasAPIKey {
                                Text("No notes yet.").foregroundStyle(.secondary)
                                Button("Generate notes") { model.regenerateSummary(meeting) }
                            } else {
                                Text("The transcript is ready in the Transcript tab. To get written notes as well, add an Anthropic API key in Settings → Notes, then click Generate notes.")
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("Show transcript") { tab = .transcript }
                                    SettingsLink { Text("Open Settings…") }
                                }
                            }
                        }
                    }
                    DisclosureGroup("My notes") {
                        notesEditor(prompt: "Your own notes for this meeting.")
                            .frame(minHeight: 140)
                    }
                    .font(.headline)
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
                .id(model.revision)
            }
        }
    }

    private func notesEditor(prompt: String) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $userNotes)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(12)
                .onChange(of: userNotes) { _, _ in scheduleNotesSave() }
            if userNotes.isEmpty {
                Text(prompt).foregroundStyle(.tertiary).padding(.horizontal, 17).padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func scheduleNotesSave() {
        notesSaveTask?.cancel()
        let text = userNotes
        let m = meeting
        notesSaveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            model.saveNotes(text, for: m)
        }
    }

    private func flushNotes() {
        notesSaveTask?.cancel()
        model.saveNotes(userNotes, for: meeting)
    }

    private func copyNotes() {
        let text = "# \(meeting.title)\n\n" + (model.summary(for: meeting) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        copy(text, as: "notes")
    }

    private func copyTranscript() {
        let segs = model.transcript(for: meeting)
        let text = segs.map { "[\(clock($0.start))] \(meeting.displayName(for: $0.speaker)): \($0.text)" }.joined(separator: "\n")
        copy(text, as: "transcript")
    }

    private func copy(_ text: String, as kind: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = kind
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == kind { copied = nil } }
    }
}
