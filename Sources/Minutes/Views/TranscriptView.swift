import AppKit
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
                    LevelMeter(channel: .me, label: "Me")
                    ThemMeterOrShield()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider()
            }
            TranscriptText(
                lines: segments.map(line), compact: compact,
                empty: !filter.isEmpty ? "No matching lines."
                    : live ? "Listening… the transcript appears as people speak." : "No transcript.",
                follow: live && followLive
            ) { url in
                guard url.scheme == "minutes-speaker",
                    let speaker = url.absoluteString.dropFirst("minutes-speaker:".count).removingPercentEncoding
                else { return }
                newName = meeting.speakerNames[speaker] ?? ""
                renaming = speaker
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
struct TranscriptLine: Equatable {
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
    var link: Link?

    struct Link: Equatable {
        var title: String
        var url: URL
    }
}

/// Turns transcript lines into an attributed string, so a transcript selects and copies like a document: across
/// lines, with times and speakers ("10:41:42  Anna" above the text). Meetings and passive days share it so both
/// transcripts look the same. Each line renders on its own, so a growing transcript renders only what changed.
struct TranscriptRenderer: Equatable {
    var compact = false
    /// Whether any line has a time: then all text is indented to one column after the times.
    var hasTime = true
    var timeWidth: CGFloat = 44

    init(compact: Bool = false, timeWidth: CGFloat = 44, for lines: [TranscriptLine]) {
        self.compact = compact
        self.timeWidth = timeWidth
        hasTime = lines.contains { $0.time != nil }
    }

    func render(_ lines: [TranscriptLine]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, line) in lines.enumerated() { out.append(render(line, first: i == 0)) }
        return out
    }

    /// One line, starting with the line break that separates it from the one before (none for the first).
    func render(_ line: TranscriptLine, first: Bool) -> NSAttributedString {
        let column: CGFloat = hasTime ? timeWidth + 10 : 0
        let small = NSFont.systemFont(ofSize: 10)
        let body = NSFont.systemFont(ofSize: compact ? 12 : 13)
        func style(indent: CGFloat, head: CGFloat, before: CGFloat, after: CGFloat = 0) -> NSParagraphStyle {
            let s = NSMutableParagraphStyle()
            s.firstLineHeadIndent = indent
            s.headIndent = head
            s.paragraphSpacingBefore = first ? 0 : before
            s.paragraphSpacing = after
            s.tabStops = [NSTextTab(textAlignment: .left, location: column)]
            s.lineBreakMode = .byWordWrapping
            return s
        }
        let out = NSMutableAttributedString(string: first ? "" : "\n")
        let start = out.length
        if line.isNote {
            out.append(NSAttributedString(
                string: [line.time, line.text].compactMap { $0 }.joined(separator: "  "),
                attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
            if let link = line.link {
                out.append(NSAttributedString(string: "  "))
                out.append(NSAttributedString(
                    string: link.title, attributes: [.font: small, .foregroundColor: NSColor.linkColor, .link: link.url]))
            }
            out.addAttribute(
                .paragraphStyle, value: style(indent: column, head: column, before: compact ? 8 : 12),
                range: NSRange(location: start, length: out.length - start))
            return out
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
        header.addAttribute(
            .paragraphStyle, value: style(indent: 0, head: column, before: compact ? 8 : 12, after: 2),
            range: NSRange(location: 0, length: header.length))
        out.append(header)
        out.append(NSAttributedString(
            string: "\n" + line.text,
            attributes: [
                .font: body, .foregroundColor: line.settled ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: style(indent: column, head: column, before: 0),
            ]))
        return out
    }
}

/// A transcript in its own scroll view, or a placeholder when it is empty. Meetings and passive days share it.
///
/// The text is one AppKit text view in a native scroll view, so it selects across lines and only the part on screen
/// is laid out: a long call opens and scrolls as fast as a short one. Do not put it into a SwiftUI `ScrollView`:
/// there the text view must lay out all of its text to report its height, which made long transcripts slow to open
/// and scroll and, redone on every change, stalled the app and the live transcript during long recordings.
struct TranscriptText: View {
    let lines: [TranscriptLine]
    var compact = false
    var timeWidth: CGFloat = 44
    var empty: String
    /// Keeps the newest line in view as lines arrive, as long as the reader has not scrolled up.
    var follow = false
    /// Opens at the newest line instead of the first.
    var startAtBottom = false
    var onLink: ((URL) -> Void)?

    var body: some View {
        if lines.isEmpty {
            Text(empty).foregroundStyle(.secondary)
                .padding(compact ? 14 : 24)
                .padding(.top, 20)
                .frame(maxWidth: compact ? .infinity : 860, maxHeight: .infinity, alignment: .topLeading)
                .frame(maxWidth: .infinity)
        } else {
            TranscriptScrollView(
                lines: lines, renderer: TranscriptRenderer(compact: compact, timeWidth: timeWidth, for: lines),
                padding: compact ? 14 : 24, maxTextWidth: compact ? .greatestFiniteMagnitude : 860 - 48,
                follow: follow, startAtBottom: startAtBottom || follow, onLink: onLink)
        }
    }
}

private struct TranscriptScrollView: NSViewRepresentable {
    let lines: [TranscriptLine]
    let renderer: TranscriptRenderer
    let padding: CGFloat
    /// The text column is centered and at most this wide, like the notes.
    let maxTextWidth: CGFloat
    let follow: Bool
    let startAtBottom: Bool
    let onLink: ((URL) -> Void)?

    final class TextView: NSTextView {
        var padding: CGFloat = 24
        var maxTextWidth: CGFloat = .greatestFiniteMagnitude

        override func setFrameSize(_ size: NSSize) {
            let inset = NSSize(width: max(padding, (size.width - maxTextWidth) / 2), height: padding)
            if textContainerInset != inset { textContainerInset = inset }
            super.setFrameSize(size)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onLink: ((URL) -> Void)?
        /// What the text view shows: these lines, rendered with `renderer`, line i starting at `offsets[i]`.
        var lines: [TranscriptLine] = []
        var offsets: [Int] = []
        var renderer: TranscriptRenderer?
        /// Whether the reader is at the newest line. Set when they scroll, not computed when lines arrive: by then
        /// the text has grown below the visible part.
        var atBottom = true

        private var scrollingToEnd = false

        @objc func scrolled(_ note: Notification) {
            guard !scrollingToEnd, let clip = note.object as? NSClipView, let doc = clip.documentView else { return }
            atBottom = clip.bounds.maxY >= doc.frame.maxY - 40
        }

        func scrollToEnd(_ view: NSTextView) {
            guard let scroll = view.enclosingScrollView else { return }
            let clip = scroll.contentView
            scrollingToEnd = true
            defer { scrollingToEnd = false }
            // TextKit 2 only estimates the height of text it has not laid out, so the first scroll can land short of
            // the end; laying out what is then on screen corrects the height, and the next scroll reaches it.
            for _ in 0..<5 {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, view.frame.maxY - clip.bounds.height)))
                scroll.reflectScrolledClipView(clip)
                view.textLayoutManager?.textViewportLayoutController.layoutViewport()
                if clip.bounds.maxY >= view.frame.maxY - 1 || view.frame.height <= clip.bounds.height { break }
            }
            atBottom = true
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let onLink, let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            onLink(url)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // TextKit 2 lays out only what is on screen (plus estimates for the rest).
        let view = TextView(usingTextLayoutManager: true)
        view.padding = padding
        view.maxTextWidth = maxTextWidth
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isAutomaticLinkDetectionEnabled = false
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.delegate = context.coordinator
        scroll.documentView = view
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onLink = onLink
        guard let view = scroll.documentView as? TextView, let storage = view.textStorage else { return }
        if view.padding != padding || view.maxTextWidth != maxTextWidth {
            view.padding = padding
            view.maxTextWidth = maxTextWidth
            view.setFrameSize(view.frame.size)
        }
        // Keep the lines up to the first one that changed. A live transcript changes only at its end, so an update
        // costs one line, not the whole call, and a selection above the change survives.
        var from = 0
        if c.renderer == renderer {
            let shared = min(c.lines.count, lines.count)
            while from < shared, c.lines[from] == lines[from] { from += 1 }
            if from == lines.count, from == c.lines.count { return }
        }
        let firstFill = c.lines.isEmpty
        let start = from < c.offsets.count ? c.offsets[from] : storage.length
        let tail = NSMutableAttributedString()
        var offsets = Array(c.offsets.prefix(from))
        for i in from..<lines.count {
            offsets.append(start + tail.length)
            tail.append(renderer.render(lines[i], first: i == 0))
        }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: tail)
        storage.endEditing()
        c.lines = lines
        c.offsets = offsets
        c.renderer = renderer
        if firstFill ? startAtBottom : follow && c.atBottom {
            c.scrollToEnd(view)
            // The first time, the scroll view has no size yet.
            if firstFill { DispatchQueue.main.async { c.scrollToEnd(view) } }
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
