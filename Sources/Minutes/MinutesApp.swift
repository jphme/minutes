import AppKit
import MinutesCore
import SwiftUI

@main
struct MinutesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var passive = PassiveModel.shared

    init() {
        // Snapshots and isolated test runs (MINUTES_SUPPORT_DIR) leave the user's keychain alone: reading it from an
        // unsigned build opens an access dialog that blocks until someone answers it.
        if CommandLine.arguments.contains("--snapshot") || ProcessInfo.processInfo.environment["MINUTES_SUPPORT_DIR"] != nil {
            Keychain.enabled = false
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(passive)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
                .environmentObject(passive)
        }
        .menuBarExtraStyle(.window)

        Window("Minutes", id: "main") {
            MainView()
                .environmentObject(model)
                .environmentObject(passive)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                    Task { await model.toggleRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(passive)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon until the main window is open (see WindowOpener).
        NSApp.setActivationPolicy(.accessory)
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            Task { @MainActor in await Snapshot.run(to: dir) }
            return
        }
        // `open -a Minutes --args --calendar-report <file> [days]`: write visible calendars and upcoming events, then quit.
        // Launched through LaunchServices so calendar permission is checked for the app, not the terminal.
        if let i = CommandLine.arguments.firstIndex(of: "--calendar-report"), i + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let days = i + 2 < CommandLine.arguments.count ? Double(CommandLine.arguments[i + 2]) ?? 5 : 5
            Task {
                let calendar = CalendarService()
                _ = await calendar.requestAccess()
                let start = Calendar.current.startOfDay(for: Date())
                let end = start.addingTimeInterval(days * 86_400)
                try? calendar.report(from: start, to: end).write(to: url, atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        Task { @MainActor in AppModel.shared.launch() }
        if !CommandLine.arguments.contains("--background") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { WindowOpener.openMain() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppModel.shared.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// minutes://start, minutes://stop, minutes://toggle, minutes://open, minutes://pause, minutes://resume — for
    /// Shortcuts, Raycast, hotkeys and tests.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "minutes" {
            Task { @MainActor in
                let model = AppModel.shared
                switch url.host ?? url.path {
                case "start": await model.startRecording()
                case "stop": await model.stopRecording()
                case "toggle": await model.toggleRecording()
                // Passive mode: minutes://pause (optionally ?minutes=N, default 15) and minutes://resume, e.g. on a hotkey.
                case "pause":
                    let minutes = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first { $0.name == "minutes" }?.value.flatMap(Int.init) ?? 15
                    PassiveModel.shared.pause(minutes: minutes)
                case "resume": PassiveModel.shared.resume()
                default: WindowOpener.openMain()
                }
            }
        }
    }
}

/// Opens or focuses the main window from anywhere (notifications, menu bar), and shows the Dock icon while it is open.
@MainActor
enum WindowOpener {
    static var openWindow: OpenWindowAction?

    static func openMain() {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
