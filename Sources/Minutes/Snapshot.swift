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
        }
        exit(0)
    }

    /// Drags the mouse from the top to the bottom of the notes in an offscreen window and prints how much text got
    /// selected. Notes must be selectable across paragraphs (SwiftUI `Text` only selects within one), and this
    /// cannot be seen in a picture.
    private static func checkSelection<V: View>(in view: V, size: NSSize) {
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
            print("selection check: no notes text view found")
            return
        }
        let frame = notes.convert(notes.bounds, to: nil)
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
            "selection check: a click on the notes reaches \(reachesText ? "the text" : String(describing: hit.map { type(of: $0) })); dragging over them selected \(selected.count) of \(notes.string.count) characters in \(paragraphs) paragraphs")
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
