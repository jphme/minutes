import AppKit
import MinutesCore
import SwiftUI

/// Renders the main views offscreen to PNG files (`Minutes --snapshot <dir>`), for checking the UI in
/// development and CI without screen-recording permission. Passive mode is shown as listening unless
/// `--passive-off` is given; calendar events are made up so both states of the record controls are covered.
@MainActor
enum Snapshot {
    static func run(to directory: URL) async {
        let model = AppModel.shared
        let passive = PassiveModel.shared
        passive.snapshotListening = !CommandLine.arguments.contains("--passive-off")
        passive.prepareForSnapshot()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func main() -> some View { MainView().environmentObject(model).environmentObject(passive) }
        func menu() -> some View {
            MenuBarView().environmentObject(model).environmentObject(passive).background(Color(nsColor: .windowBackgroundColor))
        }
        let mainSize = NSSize(width: 1200, height: 780)
        // The selection check drags over all of the notes, so they must fit in the window.
        let tall = NSSize(width: 1200, height: 3000)

        // No calendar event: one obvious way to start.
        model.setEventsForSnapshot(current: nil, upcoming: [])
        model.selection = (model.meetings.first { model.summary(for: $0) != nil } ?? model.meetings.first)?.id
        render(main(), size: mainSize, to: directory.appendingPathComponent("main.png"))
        checkNotesWidth(in: main(), size: mainSize, model: model)
        render(menu(), size: NSSize(width: 320, height: 0), to: directory.appendingPathComponent("menubar.png"))

        // An event is running and two more follow.
        let now = Date()
        func event(_ title: String, _ start: Double, _ minutes: Double) -> CalendarService.EventInfo {
            .init(
                id: title, eventID: title, calendar: "Work", title: title, start: now.addingTimeInterval(start * 60),
                end: now.addingTimeInterval((start + minutes) * 60))
        }
        let events = [event("Weekly sync", -5, 30), event("Design review", 60, 45), event("1:1 with Anna", 150, 30)]
        model.setEventsForSnapshot(current: events[0], upcoming: events)
        render(menu(), size: NSSize(width: 320, height: 0), to: directory.appendingPathComponent("menubar-event.png"))
        model.setEventsForSnapshot(current: nil, upcoming: Array(events.dropFirst()))
        render(menu(), size: NSSize(width: 320, height: 0), to: directory.appendingPathComponent("menubar-later-events.png"))
        model.setEventsForSnapshot(current: nil, upcoming: [])

        if let day = passive.days.first ?? (passive.isEnabled ? passive.today : nil) {
            let selection = model.selection
            model.selection = DayID.id(day)
            render(main(), size: mainSize, to: directory.appendingPathComponent("day-notes.png"))
            checkSelection(in: main(), size: tall)
            render(
                DayView(day: day, tab: .transcript).environmentObject(model).environmentObject(passive),
                size: NSSize(width: 900, height: 1500), to: directory.appendingPathComponent("day-transcript.png"))
            checkSelection(
                in: DayView(day: day, tab: .transcript).environmentObject(model).environmentObject(passive), size: tall,
                label: "day transcript")
            // A finished day leads with its summary.
            if let past = passive.days.first(where: { $0 != passive.today }) {
                model.selection = DayID.id(past)
                render(main(), size: mainSize, to: directory.appendingPathComponent("day-notes-past.png"))
                checkSelection(in: main(), size: tall)
            }
            model.selection = selection
        }
        let tabs: [(String, AnyView)] = [
            ("general", AnyView(GeneralSettings())), ("background", AnyView(ContextSettings())),
            ("notes", AnyView(SummarySettings())), ("sync", AnyView(SyncSettings())),
            ("window", AnyView(SettingsView())),
        ]
        for (name, view) in tabs {
            render(view.environmentObject(model).environmentObject(passive), size: NSSize(width: 640, height: 760), to: directory.appendingPathComponent("settings-\(name).png"))
        }
        if let meeting = model.meeting(model.selection) {
            render(
                TranscriptView(meeting: meeting, live: false).environmentObject(model),
                size: NSSize(width: 900, height: 700), to: directory.appendingPathComponent("transcript.png"))
            checkSelection(in: TranscriptView(meeting: meeting, live: false).environmentObject(model), size: tall, label: "meeting transcript")
            // The same meeting as if recorded with Data Protection (header line, transcript without the others),
            // and the toolbar switch in both states (offscreen windows have no toolbar).
            var protected = meeting
            protected.dataProtection = true
            render(
                MeetingDetailView(meeting: protected).environmentObject(model).environmentObject(passive),
                size: NSSize(width: 900, height: 520), to: directory.appendingPathComponent("meeting-data-protection.png"))
            render(
                HStack(spacing: 16) {
                    DataProtectionToggle(isOn: false, enabled: true, help: "") { _ in }
                    DataProtectionToggle(isOn: true, enabled: true, help: "") { _ in }
                    DataProtectionToggle(isOn: true, enabled: false, help: "") { _ in }
                }
                .padding(12),
                size: NSSize(width: 520, height: 0), to: directory.appendingPathComponent("toggle-data-protection.png"))
        }
        checkTranscriptSpeed()
        exit(0)
    }

    /// Drags the mouse from the top to the bottom of the notes in an offscreen window and prints how much text got
    /// selected. Notes must be selectable across paragraphs (SwiftUI `Text` only selects within one), and this
    /// cannot be seen in a picture.
    private static func checkSelection<V: View>(in view: V, size: NSSize, label: String = "notes") {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        func textViews(_ v: NSView) -> [NSTextView] {
            (v as? NSTextView).map { [$0] } ?? v.subviews.flatMap(textViews)
        }
        guard let notes = textViews(host).filter({ !$0.isEditable }).max(by: { $0.string.count < $1.string.count }) else {
            print("selection check (\(label)): FAILED, no selectable text view found")
            return
        }
        // A transcript's text view sits in its own scroll view: only the part on screen.
        let frame = notes.convert(notes.enclosingScrollView?.documentView === notes ? notes.visibleRect : notes.bounds, to: nil)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let top = NSPoint(x: frame.minX + 2, y: frame.maxY - 2)
        let bottom = NSPoint(x: frame.maxX - 2, y: frame.minY + 2)
        // A click must land on the text view, not on something SwiftUI laid over it.
        let click = NSPoint(x: frame.minX + 20, y: frame.maxY - 6)
        let hit = host.hitTest(host.superview?.convert(click, from: nil) ?? click)
        let reachesText = hit === notes || hit?.isDescendant(of: notes) == true
        // The text view tracks the drag in its own event loop, so the later events must already be queued. The
        // mouse-down goes to the view directly: a window in the background swallows its first click.
        NSApp.postEvent(mouse(.leftMouseDragged, bottom), atStart: false)
        NSApp.postEvent(mouse(.leftMouseUp, bottom), atStart: false)
        notes.mouseDown(with: mouse(.leftMouseDown, top))
        let selected = (notes.string as NSString).substring(with: notes.selectedRange())
        let paragraphs = selected.split(separator: "\n").count
        print(
            "selection check (\(label)): a click on the text reaches \(reachesText ? "the text" : String(describing: hit.map { type(of: $0) })); dragging over them selected \(selected.count) of \(notes.string.count) characters in \(paragraphs) paragraphs")
        window.orderOut(nil)
    }

    /// Switches between meetings with notes in one window and checks that the notes are laid out at the full width of
    /// their view. A size probe once left the text in a 50 pt column after such a switch; a fresh render does not
    /// show it.
    private static func checkNotesWidth<V: View>(in view: V, size: NSSize, model: AppModel) {
        let withNotes = model.meetings.filter { model.summary(for: $0) != nil }.prefix(4).map(\.id)
        guard withNotes.count >= 2 else { return print("notes width check: needs two meetings with notes") }
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        let original = model.selection
        var worst: (view: CGFloat, text: CGFloat)?
        for id in withNotes + withNotes.reversed() {
            model.selection = id
            for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
            host.layoutSubtreeIfNeeded()
            func textViews(_ v: NSView) -> [NSTextView] { (v as? NSTextView).map { [$0] } ?? v.subviews.flatMap(textViews) }
            for tv in textViews(host) where !tv.isEditable && !tv.string.isEmpty {
                let textWidth = tv.textContainer?.size.width ?? 0
                if abs(textWidth - tv.bounds.width) > 1, worst == nil || textWidth < worst!.text {
                    worst = (tv.bounds.width, textWidth)
                }
            }
        }
        model.selection = original
        window.orderOut(nil)
        if let worst {
            print("notes width check: FAILED, text laid out at \(Int(worst.text)) pt in a \(Int(worst.view)) pt wide view")
        } else {
            print("notes width check: notes fill their view after switching between \(withNotes.count) meetings")
        }
    }

    /// Measures a long transcript (a made-up three-hour call): opening it, streaming lines into it the way a live
    /// recording does, and scrolling through it. A transcript re-rendered and laid out in full on every change once
    /// froze the app during long calls and stopped the live transcript.
    static func checkTranscriptSpeed() {
        let words = "so we looked at the numbers again and the second quarter is fine but the pipeline for next year needs more work and I would like to talk about hiring too".split(separator: " ")
        func line(_ i: Int, settled: Bool = true) -> TranscriptLine {
            let text = (0..<45).map { words[($0 * 7 + i) % words.count] }.joined(separator: " ")
            return TranscriptLine(
                time: clock(Double(i) * 7), speaker: "Speaker \(i % 4 + 1)", color: SpeakerColor.color(for: "Speaker \(i % 4 + 1)"),
                text: text, settled: settled)
        }
        let count = 1500
        let box = LinesBox(lines: (0..<count).map { line($0) })
        let size = NSSize(width: 900, height: 700)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        func settle() {
            RunLoop.main.run(until: Date())
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        var t = Date()
        let host = NSHostingView(rootView: TranscriptFeed(box: box).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        settle()
        let open = Date().timeIntervalSince(t)

        // Streaming: a line grows a few times, then settles and the next one starts.
        let updates = 60
        t = Date()
        for i in 0..<updates {
            var next = line(count + i / 3, settled: i % 3 == 2)
            next.text = String(next.text.prefix(80 * (i % 3 + 1)))
            if i % 3 == 0 { box.lines.append(next) } else { box.lines[box.lines.count - 1] = next }
            settle()
        }
        let update = Date().timeIntervalSince(t) / Double(updates)

        func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrollViews) }
        var scroll = "no scroll view"
        if let sv = scrollViews(host).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
            let doc = sv.documentView
        {
            // Following live: the newest line must be on screen.
            let shows = (doc as? NSTextView).map { tv in
                tv.string.hasSuffix(box.lines.last!.text) && sv.contentView.bounds.maxY >= tv.frame.maxY - 2
            }
            print("transcript follow check: the newest line is \(shows == true ? "in view" : "NOT in view (FAILED)") after streaming")
            let steps = 100
            let height = doc.frame.height - sv.contentView.bounds.height
            t = Date()
            for s in 0...steps {
                sv.contentView.scroll(to: NSPoint(x: 0, y: height * Double(s) / Double(steps)))
                sv.reflectScrolledClipView(sv.contentView)
                window.display()
            }
            scroll = String(format: "%.1f ms per scroll step over %.0f pt", Date().timeIntervalSince(t) * 1000 / Double(steps + 1), height)
            // A reader who scrolled up to read stays where they are when the next line arrives.
            sv.contentView.scroll(to: NSPoint(x: 0, y: height / 2))
            sv.reflectScrolledClipView(sv.contentView)
            settle()
            box.lines.append(line(count + updates))
            settle()
            let stays = abs(sv.contentView.bounds.minY - height / 2) < 1
            print("transcript follow check: a reader who scrolled up \(stays ? "stays in place" : "is pulled to the end (FAILED)") when a line arrives")
        }
        print(String(format: "transcript speed check (%d lines): open %.0f ms, %.1f ms per live update, %@", count, open * 1000, update * 1000, scroll))
        window.orderOut(nil)
    }

    private static func render<V: View>(_ view: V, size: NSSize, to url: URL) {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        // Height 0: the window takes the view's own size, like the menu bar window does.
        let host = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height > 0 ? size.height : nil)
                .background(Color(nsColor: .windowBackgroundColor)))
        window.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: size.height > 0 ? size : host.fittingSize)
        window.setContentSize(host.frame.size)
        window.contentView = host
        window.orderFrontRegardless()
        // Let SwiftUI lay out and AppKit-backed controls (lists, text views) draw.
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}

/// Lines that change while a view shows them, for the transcript speed check.
@MainActor
final class LinesBox: ObservableObject {
    @Published var lines: [TranscriptLine]
    init(lines: [TranscriptLine]) { self.lines = lines }
}

/// A transcript shown the way `TranscriptView` shows a live one.
struct TranscriptFeed: View {
    @ObservedObject var box: LinesBox

    var body: some View { TranscriptText(lines: box.lines, empty: "", follow: true) }
}
