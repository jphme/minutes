import MinutesCore
import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    var live: Bool
    var compact = false

    @Local private var filter = ""
    @Local private var renaming: String?
    @Local private var newName = ""
    @Local private var followLive = true

    private var segments: [TranscriptSegment] {
        _ = model.revision
        let all = model.transcript(for: meeting)
        guard !filter.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(filter) || meeting.displayName(for: $0.speaker).localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !compact {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search transcript", text: $filter).textFieldStyle(.plain)
                    if live {
                        Toggle("Follow", isOn: $followLive).toggleStyle(.checkbox).font(.caption)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                Divider()
            } else {
                HStack {
                    Text("Live transcript").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    LevelMeter(level: model.levels.me, label: "Me")
                    ThemMeterOrShield()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: compact ? 8 : 12) {
                        ForEach(segments) { seg in
                            row(seg).id(seg.id)
                        }
                        if segments.isEmpty {
                            Text(live ? "Listening… the transcript appears as people speak." : "No transcript.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(compact ? 14 : 24)
                    .frame(maxWidth: compact ? .infinity : 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.liveSegments.count) { _, _ in
                    if live && followLive { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onChange(of: model.liveSegments.last?.text) { _, _ in
                    if live && followLive { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .popover(item: Binding(get: { renaming.map(IdentifiedString.init) }, set: { renaming = $0?.value })) { item in
            VStack(alignment: .leading, spacing: 10) {
                Text("Name for \(item.value)").font(.headline)
                TextField("Name", text: $newName)
                    .frame(width: 220)
                    .onSubmit { commitRename(item.value) }
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }
                    Button("Rename") { commitRename(item.value) }.buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    private func row(_ seg: TranscriptSegment) -> some View {
        let canRename = seg.channel == .them && !live
        return TranscriptRow(
            time: compact ? nil : clock(seg.start), speaker: meeting.displayName(for: seg.speaker),
            color: SpeakerColor.color(for: seg.speaker), text: seg.text, settled: seg.isFinal, compact: compact,
            speakerHelp: canRename ? "Click to name this speaker" : nil,
            onSpeakerTap: canRename ? {
                newName = meeting.speakerNames[seg.speaker] ?? ""
                renaming = seg.speaker
            } : nil)
    }

    private func commitRename(_ speaker: String) {
        model.renameSpeaker(speaker, to: newName.trimmingCharacters(in: .whitespaces), in: meeting)
        renaming = nil
    }
}

/// One utterance: time, speaker label, text. Meetings and passive days share it so both transcripts look the same.
struct TranscriptRow: View {
    var time: String?
    var timeWidth: CGFloat = 44
    var speaker: String
    var color: Color
    var text: String
    /// false for text that may still change (an utterance in progress, or one not stored yet).
    var settled = true
    var compact = false
    var speakerHelp: String?
    var onSpeakerTap: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let time {
                Text(time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: timeWidth, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Button { onSpeakerTap?() } label: {
                    Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(color)
                }
                .buttonStyle(.plain)
                .allowsHitTesting(onSpeakerTap != nil)
                .help(speakerHelp ?? "")
                Text(text)
                    .font(compact ? .callout : .body)
                    .foregroundStyle(settled ? .primary : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct IdentifiedString: Identifiable {
    var value: String
    var id: String { value }
}

enum SpeakerColor {
    static let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo, .brown, .mint]

    static func color(for speaker: String) -> Color {
        if speaker == "Me" { return .green }
        if speaker == "Them" { return .blue }
        let n = Int(speaker.filter(\.isNumber)) ?? abs(speaker.hashValue)
        return palette[(n - 1 + palette.count) % palette.count]
    }
}
