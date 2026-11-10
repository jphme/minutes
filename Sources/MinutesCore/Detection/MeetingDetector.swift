import AppKit
import CoreAudio
import Foundation
import os

private let log = MinutesLog("Detection")

/// An app currently holding the microphone open.
public struct MicApp: Hashable, Sendable {
    public var bundleID: String
    public var name: String
    public var pid: pid_t
}

/// Detects meetings by polling Core Audio (`kAudioHardwarePropertyProcessObjectList`) for processes that are
/// capturing from an input device, and matching their bundle IDs against call apps and browsers.
/// No bot, no screen access, no network.
@MainActor
public final class MeetingDetector {
    public enum Event: Sendable {
        /// A meeting app has been using the microphone for `startDelay` seconds.
        case started(MicApp)
        /// The app that triggered `started` has not used the microphone for `endDelay` seconds.
        case ended(MicApp)
    }

    /// Bundle IDs that count as meeting apps (prefix match, so helper processes such as
    /// "com.google.Chrome.helper" count too). Browsers are included because Google Meet and the web versions of
    /// Teams and Zoom run in them. Users can add more in settings.json (`extraMeetingApps`).
    public static let knownApps: [String: String] = [
        // Call and chat apps
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Microsoft Teams", "com.microsoft.teams": "Microsoft Teams",
        "com.tinyspeck.slackmacgap": "Slack", "com.cisco.webexmeetingsapp": "Webex", "com.webex.meetingmanager": "Webex",
        "com.apple.FaceTime": "FaceTime", "net.whatsapp.WhatsApp": "WhatsApp", "com.hnc.Discord": "Discord",
        "org.whispersystems.signal-desktop": "Signal", "ru.keepcoder.Telegram": "Telegram", "com.skype.skype": "Skype",
        "app.tuple.app": "Tuple",
        // Browsers
        "com.google.Chrome": "Chrome", "com.google.Chrome.beta": "Chrome Beta", "org.mozilla.firefox": "Firefox",
        "com.apple.Safari": "Safari", "com.microsoft.edgemac": "Microsoft Edge", "com.brave.Browser": "Brave",
        "company.thebrowser.Browser": "Arc", "com.vivaldi.Vivaldi": "Vivaldi", "com.operasoftware.Opera": "Opera",
    ]

    public var startDelay: TimeInterval = 3
    public var endDelay: TimeInterval = 20
    /// Extra bundle IDs the user wants treated as meeting apps.
    public var extraApps: [String: String] = [:]
    /// Bundle IDs the user never wants prompts for.
    public var ignoredApps: Set<String> = []

    public private(set) var activeApps: [MicApp] = []
    private var firstSeen: [String: Date] = [:]
    private var lastSeen: [String: Date] = [:]
    private var announced: MicApp?
    private var timer: Timer?
    private let handler: (Event) -> Void

    public init(handler: @escaping (Event) -> Void) {
        self.handler = handler
    }

    public func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Forget the current meeting so the same app can trigger again (after the user dismissed or stopped).
    public func reset() {
        announced = nil
        firstSeen.removeAll()
    }

    /// The meeting app (if any) that is using the microphone right now.
    public var currentMeetingApp: MicApp? { activeApps.first }

    /// All processes currently capturing audio input, mapped to their app.
    public static func processesUsingMicrophone() -> [MicApp] {
        let own = getpid()
        var apps: [MicApp] = []
        for object in CoreAudioUtils.processObjects where CoreAudioUtils.processIsRunningInput(object) {
            guard let pid = CoreAudioUtils.processPID(object), pid != own else { continue }
            var bundleID = CoreAudioUtils.processBundleID(object) ?? ""
            var name = bundleID
            // Helpers (e.g. "Google Chrome Helper") report their own bundle ID; map to the owning app when possible.
            if let app = NSRunningApplication(processIdentifier: pid) {
                bundleID = app.bundleIdentifier ?? bundleID
                name = app.localizedName ?? name
            }
            if !bundleID.isEmpty { apps.append(MicApp(bundleID: bundleID, name: name, pid: pid)) }
        }
        return apps
    }

    func matchMeetingApp(_ bundleID: String) -> String? {
        if ignoredApps.contains(where: { bundleID.hasPrefix($0) }) { return nil }
        let all = Self.knownApps.merging(extraApps) { a, _ in a }
        // Longest prefix wins ("com.google.Chrome.beta" before "com.google.Chrome").
        return all.filter { bundleID == $0.key || bundleID.hasPrefix($0.key + ".") }
            .max { $0.key.count < $1.key.count }?.value
    }

    private func poll() {
        let now = Date()
        var meetingApps: [MicApp] = []
        for app in Self.processesUsingMicrophone() {
            guard let name = matchMeetingApp(app.bundleID) else { continue }
            let key = app.bundleID
            if !meetingApps.contains(where: { $0.bundleID == key }) {
                meetingApps.append(MicApp(bundleID: key, name: name, pid: app.pid))
            }
            lastSeen[key] = now
            if firstSeen[key] == nil { firstSeen[key] = now }
        }
        for key in firstSeen.keys where !meetingApps.contains(where: { $0.bundleID == key }) {
            if now.timeIntervalSince(lastSeen[key] ?? .distantPast) > endDelay { firstSeen[key] = nil }
        }
        activeApps = meetingApps

        if announced == nil {
            if let app = meetingApps.first(where: { now.timeIntervalSince(firstSeen[$0.bundleID] ?? now) >= startDelay }) {
                announced = app
                log.info("meeting detected: \(app.name) (\(app.bundleID))")
                handler(.started(app))
            }
        } else if let app = announced, now.timeIntervalSince(lastSeen[app.bundleID] ?? .distantPast) > endDelay {
            announced = nil
            log.info("meeting ended: \(app.name)")
            handler(.ended(app))
        }
    }
}
