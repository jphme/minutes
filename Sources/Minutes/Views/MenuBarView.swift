import MinutesCore
import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var passive: PassiveModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.isRecording {
                // Red dot + elapsed time, like a call indicator.
                Label(clock(model.elapsed), systemImage: "record.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red, .primary)
            } else if model.detectedApp != nil {
                Image(systemName: "waveform.badge.exclamationmark")
            } else if passive.isListening {
                // Always visible while passive mode captures: people nearby are being transcribed.
                Image(systemName: "ear.badge.waveform")
            } else if passive.isEnabled {
                Image(systemName: "ear.trianglebadge.exclamationmark")
            } else if model.stageText.isEmpty == false {
                Image(systemName: "waveform.badge.ellipsis")
            } else {
                Image(systemName: "waveform")
            }
        }
        .onAppear { WindowOpener.openWindow = openWindow }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let app = model.detectedApp, !model.isRecording {
                DetectionCard(app: app)
            }
            recordButton
            if !model.isRecording {
                // Only when a calendar event is running is there a choice to make; otherwise the button says it all.
                if let event = model.currentEvent {
                    HStack(spacing: 6) {
                        Label("Links to “\(event.title)”", systemImage: "calendar")
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Record without it") { Task { await model.startRecording(event: .none) } }
                            .buttonStyle(.borderless)
                            .help("Start a recording that is not linked to this calendar event")
                    }
                    .font(.callout)
                }
                if let m = model.resumable, model.detectedApp == nil {
                    Button { Task { await model.resumeRecording(m) } } label: {
                        Label("Continue “\(m.title)”", systemImage: "arrow.clockwise.circle").lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Divider()
            PassiveControl()
            if let status = model.modelStatus {
                Label(status, systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
                    .onTapGesture { model.lastError = nil }
            }
            if !model.otherEvents.isEmpty && !model.isRecording {
                Divider()
                upcoming
            }
            Divider()
            recent
            Divider()
            HStack {
                Button("Open Minutes") { WindowOpener.openMain() }
                Spacer()
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: { Label("Settings", systemImage: "gearshape") }
                .help("Notes and API key, background, calendar, passive mode, sync")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Minutes")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refreshEvents() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform").font(.title3).foregroundStyle(.tint)
            Text("Minutes").font(.headline)
            Spacer()
            if model.isRecording {
                LevelMeter(level: model.levels.me, label: "Me")
                LevelMeter(level: model.levels.them, label: "Them")
            }
        }
    }

    private var recordButton: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            HStack {
                Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                Text(model.isRecording ? "Stop · \(clock(model.elapsed))" : "Start recording")
                Spacer()
                Text("⇧⌘R").foregroundStyle(.secondary).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .tint(model.isRecording ? .red : .accentColor)
        .buttonStyle(.borderedProminent)
    }
}

/// "A call app is using the microphone": offer to transcribe. Shown in the menu bar window and the main window.
struct DetectionCard: View {
    @EnvironmentObject var model: AppModel
    let app: MicApp

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(app.name) is using the microphone", systemImage: "person.wave.2.fill")
                .font(.subheadline.weight(.medium))
            if let m = model.resumable {
                Text("Rejoined? Continue “\(m.title)” or start a new meeting.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let m = model.resumable {
                    Button("Continue") { Task { await model.resumeRecording(m) } }
                        .buttonStyle(.borderedProminent)
                    Button("New meeting") { Task { await model.startRecording() } }
                } else {
                    Button("Start transcribing") { Task { await model.startRecording() } }
                        .buttonStyle(.borderedProminent)
                }
                Button("Not now") { model.dismissDetection() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension MenuBarView {
    /// Today's other calendar events: click one to record under its title and attendees (when the event has not
    /// started yet, or the automatic match is wrong).
    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.currentEvent == nil ? "Record for an event in today's calendar" : "Other events today")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.otherEvents.prefix(6)) { event in
                Button {
                    Task { await model.startRecording(event: .event(event)) }
                } label: {
                    HStack {
                        Image(systemName: "record.circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(event.title).lineLimit(1)
                            Text("\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened)) · \(event.calendar)")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Start recording for this event")
                .padding(.vertical, 3)
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent").font(.caption).foregroundStyle(.secondary)
            if model.meetings.isEmpty {
                Text("No meetings yet").font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(model.meetings.prefix(6)) { meeting in
                Button {
                    model.selection = meeting.id
                    WindowOpener.openMain()
                } label: {
                    HStack {
                        StatusDot(status: meeting.status)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(meeting.title).lineLimit(1)
                            Text(meeting.startedAt, format: .dateTime.weekday().day().month().hour().minute())
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
    }
}

struct LevelMeter: View {
    var level: Float
    var label: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.green)
                        .frame(width: geo.size.width * CGFloat(min(1, sqrt(Double(level)) * 2.5)))
                }
            }
            .frame(width: 36, height: 5)
        }
    }
}

struct StatusDot: View {
    var status: Meeting.Status

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(status.rawValue)
    }

    private var color: Color {
        switch status {
        case .recording: return .red
        case .processing, .summarizing: return .orange
        case .done: return .green.opacity(0.7)
        case .failed: return .yellow
        }
    }
}

func clock(_ seconds: TimeInterval) -> String {
    [TranscriptSegment].clock(seconds)
}
