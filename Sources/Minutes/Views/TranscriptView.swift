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
                    VStack(alignment: .leading, spacing: 0) {
                        TranscriptText(
                            lines: segments.map(line), compact: compact,
                            empty: !filter.isEmpty ? "No matching lines."
                                : live ? "Listening… the transcript appears as people speak." : "No transcript."
                        ) { url in
                            guard url.scheme == "minutes-speaker",
                                let speaker = url.absoluteString.dropFirst("minutes-speaker:".count).removingPercentEncoding
                            else { return }
                            newName = meeting.speakerNames[speaker] ?? ""
                            renaming = speaker
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

    private func line(_ seg: TranscriptSegment) -> TranscriptLine {
        let canRename = seg.channel == .them && !live
        var link: URL?
        if canRename, let encoded = seg.speaker.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            link = URL(string: "minutes-speaker:" + encoded)
        }
        return TranscriptLine(
            time: compact ? nil : clock(seg.start), speaker: meeting.displayName(for: seg.speaker),
            color: SpeakerColor.color(for: seg.speaker), text: seg.text, settled: seg.isFinal, speakerLink: link)
    }

    private func commitRename(_ speaker: String) {
        model.renameSpeaker(speaker, to: newName.trimmingCharacters(in: .whitespaces), in: meeting)
        renaming = nil
    }
}

/// One entry of a transcript: an utterance (time, speaker, text) or a note line such as a meeting marker.
struct TranscriptLine {
    var time: String?
    var speaker = ""
    var color: Color = .secondary
    var text: String
    /// false for text that may still change (an utterance in progress, or one not stored yet).
    var settled = true
    /// Makes the speaker name clickable (renaming a speaker).
    var speakerLink: URL?
    /// A note line instead of an utterance: small grey text, optionally followed by a link ("Open notes").
    var isNote = false
    var link: (title: String, url: URL)?
}

/// Turns transcript lines into one attributed string for `SelectableText`, so a transcript selects and copies like
/// a document: across lines, with times and speakers ("10:41:42  Anna" above the text). Meetings and passive days
/// share it so both transcripts look the same.
enum TranscriptRenderer {
    static func render(_ lines: [TranscriptLine], compact: Bool = false, timeWidth: CGFloat = 44) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let hasTime = lines.contains { $0.time != nil }
        let column: CGFloat = hasTime ? timeWidth + 10 : 0
        let small = NSFont.systemFont(ofSize: 10)
        let body = NSFont.systemFont(ofSize: compact ? 12 : 13)
        func style(first: CGFloat, head: CGFloat, before: CGFloat, after: CGFloat = 0) -> NSParagraphStyle {
            let s = NSMutableParagraphStyle()
            s.firstLineHeadIndent = first
            s.headIndent = head
            s.paragraphSpacingBefore = out.length == 0 ? 0 : before
            s.paragraphSpacing = after
            s.tabStops = [NSTextTab(textAlignment: .left, location: column)]
            s.lineBreakMode = .byWordWrapping
            return s
        }
        for line in lines {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            let start = out.length
            if line.isNote {
                let p = style(first: column, head: column, before: compact ? 8 : 12)
                out.append(NSAttributedString(
                    string: [line.time, line.text].compactMap { $0 }.joined(separator: "  "),
                    attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
                if let link = line.link {
                    out.append(NSAttributedString(string: "  "))
                    out.append(NSAttributedString(
                        string: link.title,
                        attributes: [.font: small, .foregroundColor: NSColor.linkColor, .link: link.url]))
                }
                out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: start, length: out.length - start))
                continue
            }
            // "10:41:42<tab>Anna", then the text indented to the same column.
            let header = NSMutableAttributedString()
            if let time = line.time {
                header.append(NSAttributedString(
                    string: time + "\t",
                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]))
            } else if hasTime {
                header.append(NSAttributedString(string: "\t", attributes: [.font: small]))
            }
            var speaker: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor(line.color)]
            if let url = line.speakerLink { speaker[.link] = url; speaker[.toolTip] = "Click to name this speaker" }
            header.append(NSAttributedString(string: line.speaker, attributes: speaker))
            header.addAttribute(.paragraphStyle, value: style(first: 0, head: column, before: compact ? 8 : 12, after: 2), range: NSRange(location: 0, length: header.length))
            out.append(header)
            out.append(NSAttributedString(
                string: "\n" + line.text,
                attributes: [
                    .font: body, .foregroundColor: line.settled ? NSColor.labelColor : NSColor.secondaryLabelColor,
                    .paragraphStyle: style(first: column, head: column, before: 0),
                ]))
        }
        return out
    }
}

/// A transcript as one selectable text view, or a placeholder when it is empty.
struct TranscriptText: View {
    let lines: [TranscriptLine]
    var compact = false
    var timeWidth: CGFloat = 44
    var empty: String
    var onLink: ((URL) -> Void)?

    var body: some View {
        if lines.isEmpty {
            Text(empty).foregroundStyle(.secondary).padding(.top, 20)
        } else {
            SelectableText(
                text: TranscriptRenderer.render(lines, compact: compact, timeWidth: timeWidth), linkAttributes: nil,
                onLink: onLink)
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
