import AppKit
import SwiftUI

/// Renders the subset of Markdown the summarizer produces: headings, bullets, task items, paragraphs, inline styles.
///
/// The whole document is one AppKit text view, so text can be selected across paragraphs and copied like in any
/// document (SwiftUI's `Text` only selects within a single paragraph).
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        SelectableText(text: MarkdownRenderer.render(markdown))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A read-only, selectable text view that takes the height its text needs at the offered width.
struct SelectableText: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticLinkDetectionEnabled = false
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        // Replacing the text clears the selection, so only do it when the text changed.
        if view.textStorage?.isEqual(to: text) != true { view.textStorage?.setAttributedString(text) }
    }

    /// SwiftUI asks for sizes at many widths (down to zero) before it places the view. Measuring must not touch the
    /// displayed view's text container: a probe at a narrow width left the text laid out in a 50 pt column whenever
    /// the view's frame did not change afterwards. A separate layout stack does the measuring.
    final class Coordinator {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer()

        init() {
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
        }

        func size(of text: NSAttributedString, width: CGFloat) -> CGSize {
            if !storage.isEqual(to: text) { storage.setAttributedString(text) }
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            return layout.usedRect(for: container).size
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let proposed = proposal.width ?? 600
        // Unlimited width: the widest line, unwrapped.
        if !proposed.isFinite {
            let size = context.coordinator.size(of: text, width: .greatestFiniteMagnitude)
            return CGSize(width: ceil(size.width), height: ceil(size.height))
        }
        let width = max(50, proposed)
        return CGSize(width: width, height: ceil(context.coordinator.size(of: text, width: width).height))
    }
}

/// Markdown lines to an attributed string with the app's text styles.
enum MarkdownRenderer {
    private enum Block {
        case heading(Int, String)
        case bullet(Int, String)
        case task(Bool, String)
        case paragraph(String)
        case rule
    }

    private static func blocks(_ markdown: String) -> [Block] {
        var out: [Block] = []
        for raw in markdown.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " }.count / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- [ ] ") || line.hasPrefix("* [ ] ") {
                out.append(.task(false, String(line.dropFirst(6))))
            } else if line.lowercased().hasPrefix("- [x] ") {
                out.append(.task(true, String(line.dropFirst(6))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                out.append(.bullet(indent, String(line.dropFirst(2))))
            } else if line == "---" || line == "***" {
                out.append(.rule)
            } else {
                out.append(.paragraph(line))
            }
        }
        return out
    }

    private static let bodySize: CGFloat = 13
    private static let gap: CGFloat = 8  // space between blocks
    private static let marker: CGFloat = 16  // width of the bullet / checkbox column

    static func render(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let all = blocks(markdown)
        for (i, block) in all.enumerated() {
            let last = i == all.count - 1
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = last ? 0 : gap
            style.lineBreakMode = .byWordWrapping
            let line = NSMutableAttributedString()
            switch block {
            case .heading(let level, let text):
                let size: CGFloat = level <= 1 ? 17 : level == 2 ? 15 : bodySize
                style.paragraphSpacingBefore = i == 0 ? 0 : (level <= 2 ? 10 : 4)
                line.append(inline(text, font: .systemFont(ofSize: size, weight: .semibold)))
            case .bullet(let indent, let text):
                let left = CGFloat(indent) * 18
                hang(style, at: left)
                line.append(NSAttributedString(
                    string: (indent > 0 ? "◦" : "•") + "\t",
                    attributes: [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: NSColor.secondaryLabelColor]))
                line.append(inline(text, font: .systemFont(ofSize: bodySize)))
            case .task(let done, let text):
                hang(style, at: 0)
                line.append(NSAttributedString(
                    string: (done ? "☑" : "☐") + "\t",
                    attributes: [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: NSColor.secondaryLabelColor]))
                line.append(inline(text, font: .systemFont(ofSize: bodySize)))
            case .paragraph(let text):
                line.append(inline(text, font: .systemFont(ofSize: bodySize)))
            case .rule:
                line.append(NSAttributedString(
                    string: String(repeating: "─", count: 24),
                    attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.separatorColor]))
            }
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            out.append(line)
            if !last { out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: NSFont.systemFont(ofSize: bodySize)])) }
        }
        return out
    }

    /// Marker at `left`, text in a column after it; wrapped lines stay in the text column.
    private static func hang(_ style: NSMutableParagraphStyle, at left: CGFloat) {
        style.firstLineHeadIndent = left
        style.headIndent = left + marker
        style.tabStops = [NSTextTab(textAlignment: .left, location: left + marker)]
    }

    /// Inline Markdown (bold, italic, code, links) in the given base font.
    private static func inline(_ text: String, font: NSFont) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return NSAttributedString(string: text, attributes: base) }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes = base
            var traits: NSFontDescriptor.SymbolicTraits = []
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if intent.contains(.code) {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
            } else if !traits.isEmpty {
                let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                attributes[.font] = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }
}
