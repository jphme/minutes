import AVFoundation
import AppKit
import Combine
import FluidAudio
import Foundation
import MinutesCore
import SwiftUI

private let log = MinutesLog("PassiveMode")

/// Passive mode in the app: when to listen (the user's switch, pauses, meetings, battery, screen lock, sleep),
/// the day's live transcript for the UI, and when to update the digest and write the end-of-day summary.
@MainActor
final class PassiveModel: ObservableObject {
    static let shared = PassiveModel()

    /// Why capture is not running although passive mode is on. Several can hold at once.
    enum PauseReason: Hashable {
        case user, meeting, battery, locked, sleep
    }

    enum State: Equatable {
        case off
        case starting
        case listening(since: Date)
        case paused(PauseReason)
        case failed(String)
    }

    @Published private(set) var state: State = .off
    /// Entries of today, appended live while listening.
    @Published private(set) var todayEntries: [DayEntry] = []
    /// Days with data, newest first.
    @Published private(set) var days: [String] = []
    /// What the digest/summary step is doing right now, keyed by day.
    @Published private(set) var busy: [String: String] = [:]
    /// Bumped when a digest, summary or transcript file changes so views reload.
    @Published private(set) var revision = 0
    @Published private(set) var userPauseUntil: Date?
    /// Today's utterances that are not stored yet: still being spoken, or waiting for the echo check.
    @Published private(set) var previews: [PassiveRecorder.Preview] = []
    /// Day waiting for the user to confirm deletion.
    @Published var confirmDeleteDay: String?

    /// True while today's transcript is on screen: only then are running utterances transcribed every 2 s.
    private var transcriptOnScreen = false
    private var livePreview = false

    private var reasons: Set<PauseReason> = []
    private var recorder: PassiveRecorder?
    /// A recorder that is still draining after a stop; "Forget" must reach its last utterances too.
    private var stopping: PassiveRecorder?
    private var transition: Task<Void, Never>?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var settingsSink: AnyCancellable?
    /// When an automatic call last failed, per day, so failures are retried after a pause instead of every tick.
    private var digestFailedAt: [String: Date] = [:]
    private var finalizeAttemptedAt: [String: Date] = [:]
    private static let retryInterval: TimeInterval = 15 * 60
    /// Day whose entries `todayEntries` holds.
    private var loadedDay = ""
    private static let consentKey = "passiveModeConsentAccepted"
    private static let pauseKey = "passivePauseUntil"

    private var app: AppModel { AppModel.shared }
    private var settings: AppSettings { app.settings }
    private var cachedStore: DayStore?
    /// One store per library, shared by recorder, digester and views, so its lock covers all of them.
    var store: DayStore {
        let library = URL(fileURLWithPath: settings.libraryPath)
        if let s = cachedStore, s.root == DayStore(library: library).root { return s }
        let s = DayStore(library: library)
        cachedStore = s
        return s
    }
    var today: String { DayStore.key(for: Date()) }
    /// On only with the setting and the consent notice accepted (a copied settings file alone does not start capture).
    var isEnabled: Bool { snapshotListening || (settings.passiveMode && UserDefaults.standard.bool(forKey: Self.consentKey)) }
    var isListening: Bool { if case .listening = state { return true } else { return false } }

    private init() {}

    // MARK: Lifecycle

    func launch() {
        if let until = UserDefaults.standard.object(forKey: Self.pauseKey) as? Date, until > Date() {
            userPauseUntil = until
            reasons.insert(.user)
        }
        lastSettings = settings
        refreshDays()
        reloadToday()
        observeSystem()
        settingsSink = app.$settings.dropFirst().sink { [weak self] new in
            // @Published fires before the property changes; read the new value on the next turn.
            DispatchQueue.main.async { self?.settingsChanged(new) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { PassiveModel.shared.tick() }
        }
        checkBattery()
        reconcile()
        tick()
    }

    func shutdown() async {
        timer?.invalidate()
        settingsSink = nil
        reasons.insert(.sleep)
        reconcile()
        await transition?.value
    }

    private var lastSettings: AppSettings?

    private func settingsChanged(_ new: AppSettings) {
        defer { lastSettings = new }
        guard let old = lastSettings else {
            checkBattery()
            reconcile()
            return
        }
        if old.libraryPath != new.libraryPath { refreshDays(); reloadToday() }
        if old.passiveBatteryThreshold != new.passiveBatteryThreshold { checkBattery() }
        if old.passivePauseWhenLocked != new.passivePauseWhenLocked, !new.passivePauseWhenLocked { reasons.remove(.locked) }
        if old.libraryPath != new.libraryPath {
            // Write into the new library: stop the running recorder, then start again.
            let previous = transition
            transition = Task { [weak self] in
                await previous?.value
                guard let self, let rec = self.recorder else { return }
                self.recorder = nil
                self.stopping = rec
                await rec.stop()
                self.stopping = nil
            }
        }
        if old.passiveMode != new.passiveMode || old.passiveBatteryThreshold != new.passiveBatteryThreshold
            || old.passivePauseWhenLocked != new.passivePauseWhenLocked || old.libraryPath != new.libraryPath
        {
            reconcile()
        }
    }

    // MARK: Switching on and off

    /// Turns passive mode on after the one-time consent notice, or off.
    func setEnabled(_ on: Bool) {
        guard on else {
            app.settings.passiveMode = false
            return
        }
        if !UserDefaults.standard.bool(forKey: Self.consentKey) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Turn on passive mode?"
            alert.informativeText = """
                Minutes will transcribe everything your microphone hears and your Mac plays while passive mode is on, \
                including people who do not know they are being transcribed. In Germany, recording non-public speech \
                without consent is a criminal offence (§ 201 StGB); similar rules apply elsewhere. Tell the people \
                around you, and pause passive mode when someone does not agree.

                Audio is never stored: it is transcribed on this Mac and only the text is kept, in Days/ in your \
                library. Every few minutes the new text is sent to Claude (Anthropic API) to update the day's digest.

                The menu bar shows an ear while Minutes listens. Pause from the menu bar at any time; "Forget last \
                15 minutes" deletes recent text.
                """
            alert.addButton(withTitle: "Turn On")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(true, forKey: Self.consentKey)
        }
        app.settings.passiveMode = true
        reconcile()
    }

    func pause(minutes: Int?) {
        let until: Date
        if let minutes {
            until = Date().addingTimeInterval(Double(minutes) * 60)
        } else {
            // Until the next 7:00 (this morning if it is still night).
            let sevenToday = Calendar.current.startOfDay(for: Date()).addingTimeInterval(7 * 3600)
            until = sevenToday > Date() ? sevenToday : Calendar.current.date(byAdding: .day, value: 1, to: sevenToday)!
        }
        userPauseUntil = until
        UserDefaults.standard.set(until, forKey: Self.pauseKey)
        reasons.insert(.user)
        reconcile()
    }

    func resume() {
        userPauseUntil = nil
        UserDefaults.standard.removeObject(forKey: Self.pauseKey)
        reasons.remove(.user)
        reconcile()
    }

    /// Called by AppModel as soon as a meeting recording begins: the meeting gets its own full pipeline.
    func meetingStarted() {
        reasons.insert(.meeting)
        reconcile()
    }

    /// Called when a meeting recording could not start: resume without a marker.
    func meetingCancelled() {
        reasons.remove(.meeting)
        reconcile()
    }

    /// Called when the meeting recording stops: marks it in the day transcript and resumes listening.
    func meetingEnded(_ meeting: Meeting) {
        if isEnabled {
            let entry = DayEntry(
                kind: .meeting, start: meeting.allParts.last?.startedAt ?? meeting.startedAt, end: meeting.endedAt ?? Date(),
                text: meeting.title, meeting: meeting.folderName, meetingID: meeting.id)
            store.append(entry)
            received(entry)
            refreshDays()
        }
        reasons.remove(.meeting)
        reconcile()
    }

    /// Starts or stops capture to match the switch and the pause reasons. Transitions run one at a time.
    private func reconcile() {
        let previous = transition
        transition = Task { [weak self] in
            await previous?.value
            await self?.applyState()
        }
    }

    private func applyState() async {
        let shouldRun = isEnabled && reasons.isEmpty
        if shouldRun, recorder == nil {
            state = .starting
            guard let models = await app.speechModels() else {
                state = .failed(app.modelStatus ?? "Speech model not loaded")
                return
            }
            let (asr, vad) = models
            // Re-check: something may have changed while the models loaded.
            guard isEnabled, reasons.isEmpty else { return updateIdleState() }
            let store = store
            let rec = PassiveRecorder(
                store: store,
                onPreview: { preview in Task { @MainActor in PassiveModel.shared.received(preview) } }
            ) { entry in
                Task { @MainActor in PassiveModel.shared.received(entry) }
            }
            do {
                try await rec.start(asr: asr, vad: vad)
                recorder = rec
                livePreview = false
                updateLivePreview()
                state = .listening(since: Date())
                for w in rec.warnings { app.lastError = w }
            } catch {
                await rec.stop()
                log.error("passive start failed: \(error.localizedDescription)")
                state = .failed(
                    AVCaptureDeviceAuthorized() ? error.localizedDescription
                        : "Microphone access is off for Minutes. Enable it in System Settings → Privacy & Security → Microphone.")
            }
        } else if !shouldRun, let rec = recorder {
            recorder = nil
            stopping = rec
            updateIdleState()
            await rec.stop()
            stopping = nil
            // Everything the recorder still held is stored or dropped now.
            previews = []
        } else if !shouldRun {
            updateIdleState()
        }
    }

    private func updateIdleState() {
        if !isEnabled {
            state = .off
        } else if let reason = [PauseReason.meeting, .sleep, .locked, .battery, .user].first(where: reasons.contains) {
            state = .paused(reason)
        }
    }

    private func received(_ entry: DayEntry) {
        previews.removeAll { $0.id == entry.id }
        if loadedDay != today { reloadToday() } // midnight passed: the file already has this entry
        else if DayStore.key(for: entry.start) == today { todayEntries.append(entry) }
        if days.first != today { refreshDays() }
    }

    private func received(_ preview: PassiveRecorder.Preview) {
        if preview.text.isEmpty {
            previews.removeAll { $0.id == preview.id }
        } else if let i = previews.firstIndex(where: { $0.id == preview.id }) {
            previews[i] = preview
        } else if recorder != nil || stopping != nil, !todayEntries.contains(where: { $0.id == preview.id }) {
            // (A callback that arrives after its recorder has stopped would never be cleared again.)
            previews.append(preview)
        }
    }

    // MARK: Live preview

    /// Called by today's transcript view when it appears and disappears.
    func transcriptVisible(_ visible: Bool) {
        transcriptOnScreen = visible
        updateLivePreview()
    }

    /// Partial lines cost about as much as a meeting's live transcript, so they run only while today's transcript
    /// is in a window that is actually visible on screen.
    private func updateLivePreview() {
        let windowVisible = NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.occlusionState.contains(.visible) }
        let on = transcriptOnScreen && windowVisible
        guard on != livePreview, let recorder else { return }
        livePreview = on
        log.info("passive live preview \(on ? "on" : "off")")
        Task { await recorder.setLivePreview(on) }
    }

    // MARK: Deleting a day

    /// Moves a day's passive data to the Trash. Today keeps listening; new lines start a fresh transcript.
    func deleteDay(_ day: String) {
        guard busy[day] == nil else { return }
        if day == today {
            let now = Date()
            recorder?.forget(from: Calendar.current.startOfDay(for: now), to: now)
            previews = []
        }
        do {
            try store.delete(day)
            log.info("deleted passive day \(day)")
        } catch {
            app.lastError = "Could not delete the day: \(error.localizedDescription)"
        }
        refreshDays()
        reloadToday()
        revision += 1
        if app.selection == DayID.id(day) { app.selection = app.meetings.first?.id }
    }

    private func reloadToday() {
        loadedDay = today
        todayEntries = store.entries(loadedDay)
    }

    // MARK: Energy and privacy triggers

    private func observeSystem() {
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let m = PassiveModel.shared
                guard m.settings.passivePauseWhenLocked else { return }
                m.reasons.insert(.locked)
                m.reconcile()
            }
        })
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                PassiveModel.shared.reasons.remove(.locked)
                PassiveModel.shared.reconcile()
            }
        })
        let wnc = NSWorkspace.shared.notificationCenter
        observers.append(wnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                PassiveModel.shared.reasons.insert(.sleep)
                PassiveModel.shared.reconcile()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { PassiveModel.shared.updateLivePreview() }
        })
        observers.append(wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                PassiveModel.shared.reasons.remove(.sleep)
                PassiveModel.shared.checkBattery()
                PassiveModel.shared.reconcile()
            }
        })
    }

    private func checkBattery() {
        let pause = PowerSource.shouldPause(PowerSource.current(), threshold: settings.passiveBatteryThreshold)
        if pause != reasons.contains(.battery) {
            if pause { reasons.insert(.battery) } else { reasons.remove(.battery) }
            log.info(pause ? "pausing passive mode: low battery" : "battery ok, passive mode may resume")
            reconcile()
        }
    }

    /// Every 30 s: battery, end of a timed pause, digest updates, summaries of finished days.
    private func tick() {
        checkBattery()
        if let until = userPauseUntil, until <= Date() { resume() }
        // A failed start (permission still pending, model still loading) is retried.
        if case .failed = state, isEnabled, reasons.isEmpty { reconcile() }
        if loadedDay != today { reloadToday(); refreshDays() }
        guard app.hasAPIKey, settings.llmProvider == .anthropic else { return }
        let day = today
        let now = Date()
        if busy[day] == nil, isEnabled || !todayEntries.isEmpty,
            now.timeIntervalSince(digestFailedAt[day] ?? .distantPast) > Self.retryInterval
        {
            let store = store
            let digester = DayDigester(store: store, settings: settings)
            Task {
                // Parsing a full day's transcript is off the main thread.
                let due = await Task.detached { () -> Bool in
                    let (pending, state) = digester.pendingAndState(day)
                    return DayDigester.shouldUpdate(pending: pending, state: state, now: now)
                }.value
                if due { updateDigest(day, automatic: true) }
            }
        }
        // Finished days whose summary is missing or was written before the day ended (on demand): write the final one
        // (the Mac was off at midnight, the app was not running, or an earlier attempt failed).
        for past in days.prefix(3) where past < day && busy[past] == nil
            && now.timeIntervalSince(finalizeAttemptedAt[past] ?? .distantPast) > Self.retryInterval
        {
            let dayEnd = DayStore.date(for: past).flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0) } ?? now
            let written = store.loadState(past).summaryWrittenAt
            if written.map({ $0 < dayEnd }) ?? true, store.entries(past).contains(where: { $0.kind == .speech }) {
                finalizeAttemptedAt[past] = now
                writeSummary(past)
                break
            }
        }
    }

    // MARK: Digest and summary

    func updateDigest(_ day: String, automatic: Bool = false) {
        guard busy[day] == nil else { return }
        busy[day] = "Updating digest…"
        let digester = DayDigester(store: store, settings: settings)
        Task {
            do {
                _ = try await Task.detached { try await digester.update(day) }.value
                digestFailedAt[day] = nil
            } catch {
                log.error("digest update failed\(automatic ? ", retrying in 15 min" : ""): \(error.localizedDescription)")
                digestFailedAt[day] = Date()
            }
            busy[day] = nil
            revision += 1
        }
    }

    func writeSummary(_ day: String) {
        guard busy[day] == nil else { return }
        busy[day] = "Writing day summary…"
        let digester = DayDigester(store: store, settings: settings)
        let meetings = DayDigester.meetings(on: day, in: app.store)
        Task {
            do {
                try await Task.detached {
                    try await digester.update(day)
                    try await digester.finalize(day, meetings: meetings)
                }.value
            } catch {
                log.error("day summary failed: \(error.localizedDescription)")
                store.updateState(day) { $0.lastError = error.localizedDescription }
            }
            busy[day] = nil
            revision += 1
        }
    }

    /// Deletes the transcript of the last `minutes` minutes (and restarts the digest if it had seen it).
    func forget(minutes: Int) {
        let now = Date()
        let since = now.addingTimeInterval(-Double(minutes) * 60)
        recorder?.forget(from: since, to: now)
        stopping?.forget(from: since, to: now)
        // The window can reach back across midnight.
        var removed = 0
        for day in Set([DayStore.key(for: since), today]) { removed += store.forget(since: since, day: day) }
        previews.removeAll { $0.start >= since }
        reloadToday()
        revision += 1
        log.info("forgot \(removed) passive entries from the last \(minutes) min")
    }

    func refreshDays() {
        days = store.days()
    }

    /// For `--snapshot`: load the days and show the state passive mode would have, without capturing.
    func prepareForSnapshot() {
        refreshDays()
        todayEntries = store.entries(today)
        if isEnabled || snapshotListening {
            state = .listening(since: Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600))
            if let last = todayEntries.last {
                previews = [
                    .init(id: UUID(), channel: .me, start: last.end.addingTimeInterval(20), text: "This line has ended and waits for the echo check.", ended: true),
                    .init(id: UUID(), channel: .them, start: last.end.addingTimeInterval(26), text: "And this one is still being spoken", ended: false),
                ]
            }
        }
    }

    /// For `--snapshot` with an isolated library: show passive mode as on without the consent flag.
    var snapshotListening = false

    // MARK: Status text

    var statusText: String {
        switch state {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .listening(let since): return "Listening since \(since.formatted(date: .omitted, time: .shortened))"
        case .failed(let message): return message
        case .paused(let reason):
            switch reason {
            case .user:
                if let until = userPauseUntil {
                    let sameDay = Calendar.current.isDate(until, inSameDayAs: Date())
                    return "Paused until \(until.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened))"
                }
                return "Paused"
            case .meeting: return "Paused while a meeting is recorded"
            case .battery: return "Paused: battery low"
            case .locked: return "Paused while the screen is locked"
            case .sleep: return "Paused while the Mac sleeps"
            }
        }
    }
}

private func AVCaptureDeviceAuthorized() -> Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
}

/// Sidebar selection for a day: a fixed UUID pattern that carries the date ("…-0000YYYYMMDD"), so days can share
/// the meeting list's selection without colliding with meeting IDs.
enum DayID {
    static func id(_ day: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000" + day.replacingOccurrences(of: "-", with: ""))!
    }

    static func day(_ id: UUID?) -> String? {
        guard let s = id?.uuidString, s.hasPrefix("00000000-0000-0000-0000-0000") else { return nil }
        let d = String(s.suffix(8))
        return "\(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2))"
    }
}
