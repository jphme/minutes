import AppKit
import FluidAudio
import Foundation
import MinutesCore
import SwiftUI
import os

private let log = MinutesLog("App")

/// Central state and orchestration for the app: detection → recording → live transcript → final pass → notes.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings: AppSettings { didSet { if settings != oldValue { settingsChanged(from: oldValue) } } }
    @Published private(set) var meetings: [Meeting] = []
    @Published var selection: Meeting.ID?
    @Published private(set) var recording: RecordingSession?
    @Published private(set) var liveSegments: [TranscriptSegment] = []
    @Published private(set) var detectedApp: MicApp?
    @Published private(set) var modelStatus: String?
    @Published private(set) var stageText: [UUID: String] = [:]
    @Published private(set) var streamingSummary: [UUID: String] = [:]
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levels: (me: Float, them: Float) = (0, 0)
    @Published var lastError: String?
    /// Calendar events to offer when starting a recording (running now and the rest of today).
    @Published private(set) var upcomingEvents: [CalendarService.EventInfo] = []
    /// The calendar event a recording started now would be linked to (running now or about to start), if any.
    @Published private(set) var currentEvent: CalendarService.EventInfo?
    /// A meeting that just ended and can be continued when the call app comes back (e.g. after a dropped call).
    @Published private(set) var resumable: Meeting?
    @Published private(set) var syncStatus: String?
    /// Meeting waiting for the user to confirm deletion (toolbar, context menu, Delete key).
    @Published var confirmDelete: Meeting?
    /// Whether an Anthropic API key is available; without one, meetings get a transcript but no notes.
    @Published private(set) var hasAPIKey = Keychain.hasKey

    func refreshKeyState() { hasAPIKey = Keychain.hasKey }
    /// Bumped when files of a meeting change on disk so detail views reload.
    @Published private(set) var revision = 0

    private(set) var store: MeetingStore
    private var asr: AsrEngine
    private var vad: VadManager?
    private var processor: MeetingProcessor
    private let calendar = CalendarService()
    private var detector: MeetingDetector?
    private var recordingTrigger: MicApp?
    private var ticker: Timer?
    private var processingQueue: [UUID] = []
    /// Meetings whose next processing run should only transcribe parts not yet transcribed (after a resume).
    private var pendingOnly: Set<UUID> = []
    private var processingTask: Task<Void, Never>?
    private var calendarTimer: Timer?
    private var syncPending: Set<UUID> = []
    private var syncRemoved: Set<UUID> = []
    private var syncTask: Task<Void, Never>?

    private init() {
        AppPaths.ensureDefaults()
        let settings = AppPaths.loadSettings()
        self.settings = settings
        store = MeetingStore(root: URL(fileURLWithPath: settings.libraryPath))
        asr = AsrEngine(kind: settings.asrModel)
        processor = MeetingProcessor(store: store, asr: asr)
        reloadMeetings()
        recoverInterruptedMeetings()
    }

    // MARK: Lifecycle

    func launch() {
        NotificationManager.shared.setup()
        configureDetector()
        Task {
            await prepareModels()
            PassiveModel.shared.launch()
        }
        Task { await primePermissions() }
        if settings.useCalendar {
            Task {
                if await calendar.requestAccess() {
                    log.info("calendars visible: \(calendar.visibleCalendars().joined(separator: " | "))")
                    refreshEvents()
                } else {
                    log.warning("calendar access not granted")
                }
            }
        }
        calendarTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.refreshEvents() }
        }
    }

    func refreshEvents() {
        guard !eventsFixed else { return }
        upcomingEvents = settings.useCalendar ? calendar.eventsAroundNow() : []
        currentEvent = settings.useCalendar ? calendar.currentEvent() : nil
    }

    private var eventsFixed = false

    /// Today's events other than the one a recording would be linked to anyway.
    var otherEvents: [CalendarService.EventInfo] {
        upcomingEvents.filter { $0.eventID != currentEvent?.eventID }
    }

    /// For `--snapshot`: show the UI as if these calendar events existed.
    func setEventsForSnapshot(current: CalendarService.EventInfo?, upcoming: [CalendarService.EventInfo]) {
        eventsFixed = true
        currentEvent = current
        upcomingEvents = upcoming
    }

    /// Events that overlap a meeting's time (± 2 h), for linking a recording to a different event.
    func events(near meeting: Meeting) -> [CalendarService.EventInfo] {
        guard settings.useCalendar else { return [] }
        return calendar.events(
            from: meeting.startedAt.addingTimeInterval(-2 * 3600), to: (meeting.endedAt ?? Date()).addingTimeInterval(2 * 3600))
    }

    /// Asks for microphone and system-audio access at first launch instead of at the first meeting.
    /// System audio has no request API: the prompt appears when a process tap first runs, so a tap is started briefly once.
    private func primePermissions() async {
        _ = await MicrophoneCapture.requestAccess()
        let key = "primedSystemAudioPermission"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let tap = SystemAudioCapture()
        do {
            try tap.start { _, _ in }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            tap.stop()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            log.error("system audio permission priming failed: \(error.localizedDescription)")
        }
    }

    func shutdown() async {
        if recording != nil { await stopRecording() }
        await PassiveModel.shared.shutdown()
    }

    /// Downloads/loads the speech models in the background so the first recording starts instantly.
    func prepareModels() async {
        modelStatus = "Loading speech model…"
        do {
            try await asr.load()
            if vad == nil { vad = try await VadManager(config: VadConfig(defaultThreshold: 0.5)) }
            modelStatus = nil
        } catch {
            modelStatus = "Speech model failed to load: \(error.localizedDescription)"
            log.error("model load failed: \(error.localizedDescription)")
        }
    }

    /// The loaded speech models, for passive mode (nil if they failed to load).
    func speechModels() async -> (asr: AsrEngine, vad: VadManager)? {
        let asr = asr
        if await !asr.isLoaded || vad == nil { await prepareModels() }
        let loaded = await asr.isLoaded
        guard let vad, loaded else { return nil }
        return (asr, vad)
    }

    private func settingsChanged(from old: AppSettings) {
        AppPaths.save(settings)
        if settings.libraryPath != old.libraryPath || settings.asrModel != old.asrModel {
            store = MeetingStore(root: URL(fileURLWithPath: settings.libraryPath))
            if settings.asrModel != old.asrModel {
                asr = AsrEngine(kind: settings.asrModel)
                Task { await prepareModels() }
            }
            processor = MeetingProcessor(store: store, asr: asr)
            reloadMeetings()
        }
        if settings.detectMeetings != old.detectMeetings || settings.ignoredApps != old.ignoredApps
            || settings.extraMeetingApps != old.extraMeetingApps
        {
            configureDetector()
        }
        if settings.useCalendar != old.useCalendar {
            Task {
                if settings.useCalendar { _ = await calendar.requestAccess() }
                refreshEvents()
            }
        }
        if settings.notesRepository != old.notesRepository, !settings.notesRepository.isEmpty { syncAll() }
    }

    // MARK: Library

    func reloadMeetings() {
        meetings = store.list()
        if let sel = selection, DayID.day(sel) == nil, !meetings.contains(where: { $0.id == sel }) { selection = meetings.first?.id }
    }

    func meeting(_ id: Meeting.ID?) -> Meeting? { meetings.first { $0.id == id } }

    private func update(_ meeting: Meeting) {
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[i] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
        revision += 1
    }

    /// Meetings left in "recording"/"processing" after a crash or quit get processed from their saved audio.
    private func recoverInterruptedMeetings() {
        for var m in meetings where [.recording, .processing, .summarizing].contains(m.status) {
            if m.endedAt == nil { m.endedAt = (try? FileManager.default.attributesOfItem(atPath: store.folder(for: m).path)[.modificationDate] as? Date) ?? Date() }
            m.status = .processing
            try? store.save(m)
            update(m)
            enqueueProcessing(m.id)
        }
    }

    func rename(_ meeting: Meeting, to title: String) {
        guard !title.isEmpty, title != meeting.title, let m = try? store.rename(meeting, to: title) else { return }
        update(m)
        scheduleSync(m.id)
    }

    func renameSpeaker(_ speaker: String, to name: String, in meeting: Meeting) {
        var m = meeting
        m.speakerNames[speaker] = name.isEmpty ? nil : name
        try? store.save(m)
        if let segs = Optional(store.loadTranscript(for: m)), !segs.isEmpty { try? store.saveTranscript(segs, for: m) }
        update(m)
        scheduleSync(m.id)
    }

    func delete(_ meeting: Meeting) {
        guard recording?.meeting.id != meeting.id else { return }
        try? store.delete(meeting)
        if resumable?.id == meeting.id { resumable = nil }
        reloadMeetings()
        scheduleSync(removed: meeting.id)
    }

    /// Links a recording to a calendar event (title, attendees), or unlinks it with nil.
    func link(_ meeting: Meeting, to event: CalendarService.EventInfo?) {
        var m = meeting
        // Take the event's title only over a placeholder or an earlier event title, not over generated notes' title
        // (scheduling tools produce titles like "30 minute meeting (Name)").
        let replaceTitle = meeting.title == meeting.calendarEventTitle || MeetingProcessor.isGenericTitle(meeting.title)
        m.calendarEventTitle = event?.title
        m.calendarEventID = event?.eventID
        m.attendees = event?.attendees ?? []
        try? store.save(m)
        if let event, replaceTitle, let renamed = try? store.rename(m, to: event.title) { m = renamed }
        update(m)
        scheduleSync(m.id)
    }

    /// The meeting recorded just before this one, if any (candidate for merging).
    func previousMeeting(before meeting: Meeting) -> Meeting? {
        meetings.filter { $0.startedAt < meeting.startedAt && $0.status == .done }.max { $0.startedAt < $1.startedAt }
    }

    /// Appends `meeting` to the meeting recorded before it and writes the notes again.
    func mergeWithPrevious(_ meeting: Meeting) {
        guard let previous = previousMeeting(before: meeting), recording?.meeting.id != meeting.id else { return }
        do {
            let merged = try store.merge(meeting, into: previous)
            if resumable?.id == meeting.id { resumable = nil }
            reloadMeetings()
            selection = merged.id
            scheduleSync(removed: meeting.id)
            regenerateSummary(merged)
        } catch {
            lastError = "Merge failed: \(error.localizedDescription)"
        }
    }

    func notes(for meeting: Meeting) -> String { store.read("notes.md", for: meeting) ?? "" }

    func saveNotes(_ text: String, for meeting: Meeting) {
        guard text != notes(for: meeting) else { return }
        try? store.write(text, to: "notes.md", for: meeting)
        if recording?.meeting.id != meeting.id, meeting.status == .done { scheduleSync(meeting.id) }
    }

    func summary(for meeting: Meeting) -> String? { store.read("summary.md", for: meeting) }

    func transcript(for meeting: Meeting) -> [TranscriptSegment] {
        if let session = recording, session.meeting.id == meeting.id {
            // After a resume, earlier parts already have a final transcript.
            let earlier = session.part > 0 ? (store.loadFinalTranscript(for: meeting) ?? []) : []
            return earlier + liveSegments.filter { !$0.text.isEmpty }
        }
        return store.loadTranscript(for: meeting)
    }

    func hasAudio(_ meeting: Meeting) -> Bool { store.hasAudio(meeting) }

    func folder(for meeting: Meeting) -> URL { store.folder(for: meeting) }

    // MARK: Detection

    private func configureDetector() {
        detector?.stop()
        detector = nil
        detectedApp = nil
        guard settings.detectMeetings else { return }
        let d = MeetingDetector { [weak self] event in self?.handle(event) }
        d.ignoredApps = Set(settings.ignoredApps)
        d.extraApps = settings.extraMeetingApps
        d.start()
        detector = d
    }

    private func handle(_ event: MeetingDetector.Event) {
        switch event {
        case .started(let app):
            guard recording == nil else { return }
            // The same call app back within 15 minutes of an automatic stop: most likely a rejoin.
            let resume = resumable.flatMap { m in
                m.sourceApp == app.name && Date().timeIntervalSince(m.endedAt ?? .distantPast) < 15 * 60 ? m : nil
            }
            if resume == nil { resumable = nil }
            if settings.autoStartRecording {
                Task {
                    if let resume { await resumeRecording(resume, trigger: app) } else { await startRecording(trigger: app) }
                }
            } else {
                detectedApp = app
                NotificationManager.shared.postMeetingDetected(
                    app: app, eventTitle: currentEventTitle(), resumeTitle: resume?.title)
            }
        case .ended(let app):
            if detectedApp?.bundleID == app.bundleID {
                detectedApp = nil
                NotificationManager.shared.removeMeetingDetected()
            }
            if settings.autoStopRecording, recording != nil, recordingTrigger?.bundleID == app.bundleID {
                NotificationManager.shared.postInfo(
                    title: "Meeting ended",
                    body: "\(app.name) released the microphone. Writing your notes… If you rejoin, Minutes offers to continue this meeting.")
                Task { await stopRecording(automatic: true) }
            }
        }
    }

    func dismissDetection() {
        detectedApp = nil
        NotificationManager.shared.removeMeetingDetected()
    }

    private func currentEventTitle() -> String? {
        settings.useCalendar ? calendar.currentEvent()?.title : nil
    }

    // MARK: Recording

    var isRecording: Bool { recording != nil }

    enum EventChoice {
        /// The calendar event running now, if any.
        case automatic
        case none
        case event(CalendarService.EventInfo)
    }

    func startRecording(trigger: MicApp? = nil, event choice: EventChoice = .automatic) async {
        guard recording == nil else { return }
        let app = trigger ?? detectedApp ?? detector?.currentMeetingApp
        detectedApp = nil
        resumable = nil
        NotificationManager.shared.removeMeetingDetected()
        let event: CalendarService.EventInfo?
        switch choice {
        case .automatic: event = settings.useCalendar ? calendar.currentEvent() : nil
        case .none: event = nil
        case .event(let e): event = e
        }
        let title = event?.title ?? (app.map { "\($0.name) meeting" } ?? "Meeting")
        do {
            var meeting = Meeting(
                title: title, sourceApp: app?.name, calendarEventTitle: event?.title,
                attendees: event?.attendees ?? [])
            meeting.calendarEventID = event?.eventID
            meeting = try store.create(meeting)
            try await begin(meeting, part: 0, app: app)
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
            recording = nil
        }
    }

    /// Continues a finished meeting as a new recording part; the transcript and notes cover all parts.
    func resumeRecording(_ meeting: Meeting, trigger: MicApp? = nil) async {
        guard recording == nil else { return }
        let app = trigger ?? detectedApp ?? detector?.currentMeetingApp
        detectedApp = nil
        resumable = nil
        NotificationManager.shared.removeMeetingDetected()
        // If its processing is still queued, it is skipped and runs once over all parts after this stop.
        do {
            var m = store.reload(meeting) ?? meeting
            let part = try store.addPart(to: &m)
            try await begin(m, part: part, app: app)
        } catch {
            lastError = "Could not resume recording: \(error.localizedDescription)"
            recording = nil
        }
    }

    private func begin(_ meeting: Meeting, part: Int, app: MicApp?) async throws {
        do {
            let session = RecordingSession(
                meeting: meeting, store: store, part: part, timeOffset: meeting.offset(ofPart: part)
            ) { [weak self] segment in
                Task { @MainActor in self?.receive(segment) }
            }
            session.onWarning = { message in Task { @MainActor in AppModel.shared.lastError = message } }
            liveSegments = []
            recordingTrigger = app
            recording = session
            PassiveModel.shared.meetingStarted()
            update(meeting)
            selection = meeting.id
            let loaded = await asr.isLoaded
            if vad == nil || !loaded { await prepareModels() }
            let ready = await asr.isLoaded
            do {
                try await session.start(asr: ready ? asr : nil, vad: vad)
            } catch {
                PassiveModel.shared.meetingCancelled()
                throw error
            }
            for w in session.warnings { lastError = w }
            startTicker()
        }
    }

    /// Stops right away from the user's point of view: a new recording can start while this one is finalized.
    func stopRecording(automatic: Bool = false) async {
        guard let session = recording else { return }
        ticker?.invalidate()
        ticker = nil
        recording = nil
        recordingTrigger = nil
        levels = (0, 0)
        detector?.reset()
        var m = store.reload(session.meeting) ?? session.meeting
        let now = Date()
        m.endedAt = now
        if var parts = m.parts, !parts.isEmpty {
            parts[parts.count - 1].endedAt = now
            m.parts = parts
        }
        m.status = .processing
        try? store.save(m)
        update(m)
        if automatic { resumable = m }
        PassiveModel.shared.meetingEnded(m)
        await session.stop()
        if session.part > 0 { pendingOnly.insert(m.id) }
        enqueueProcessing(m.id)
    }

    func toggleRecording() async {
        if isRecording { await stopRecording() } else { await startRecording() }
    }

    private func receive(_ segment: TranscriptSegment) {
        guard recording != nil else { return }
        if let i = liveSegments.firstIndex(where: { $0.id == segment.id }) {
            if segment.isFinal && segment.text.isEmpty {
                liveSegments.remove(at: i)
            } else {
                liveSegments[i] = segment
            }
        } else if !segment.text.isEmpty {
            let i = liveSegments.firstIndex { $0.start > segment.start } ?? liveSegments.endIndex
            liveSegments.insert(segment, at: i)
        }
    }

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.recording else { return }
                self.elapsed = session.elapsed
                self.levels = (session.level(.me), session.level(.them))
            }
        }
    }

    // MARK: Processing

    private func enqueueProcessing(_ id: UUID) {
        if !processingQueue.contains(id) { processingQueue.append(id) }
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            while let self, let next = self.processingQueue.first {
                if let m = self.meeting(next) { await self.runProcessing(m) }
                self.processingQueue.removeFirst()
            }
            self?.processingTask = nil
        }
    }

    private func runProcessing(_ meeting: Meeting) async {
        let id = meeting.id
        // Resumed again before processing started: the recording's own stop enqueues it once more.
        guard recording?.meeting.id != id else { return }
        stageText[id] = "Preparing…"
        streamingSummary[id] = nil
        let onlyPending = pendingOnly.remove(id) != nil
        let result = await processor.process(meeting, settings: settings, onlyPending: onlyPending) { progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch progress {
                case .stage(let s):
                    self.stageText[id] = s
                    if s.hasPrefix("Writing"), var m = self.meeting(id) {
                        m.status = .summarizing
                        self.update(m)
                    }
                case .summaryDelta(let d): self.streamingSummary[id, default: ""] += d
                }
            }
        }
        stageText[id] = nil
        streamingSummary[id] = nil
        if let session = recording, session.meeting.id == id {
            // Resumed while this run was going: keep the new part, which the processor did not know about.
            var r = result
            r.parts = result.allParts + session.meeting.allParts.dropFirst(result.allParts.count)
            r.status = .recording
            r.endedAt = nil
            try? store.save(r)
            update(r)
            return
        }
        update(result)
        if resumable?.id == id { resumable = result }
        if result.status == .done {
            NotificationManager.shared.postNotesReady(meeting: result)
            scheduleSync(id)
        } else if let e = result.error {
            lastError = e
        }
    }

    func regenerateSummary(_ meeting: Meeting) {
        let id = meeting.id
        Task {
            stageText[id] = "Writing notes…"
            streamingSummary[id] = ""
            var m = meeting
            m.status = .summarizing
            update(m)
            do {
                m = try await processor.summarize(m, settings: settings) { progress in
                    Task { @MainActor [weak self] in
                        switch progress {
                        case .stage(let s): self?.stageText[id] = s
                        case .summaryDelta(let d): self?.streamingSummary[id, default: ""] += d
                        }
                    }
                }
                m.error = nil
            } catch {
                m.error = "Summary failed: \(error.localizedDescription)"
                lastError = m.error
            }
            m.status = .done
            try? store.save(m)
            stageText[id] = nil
            streamingSummary[id] = nil
            update(m)
            scheduleSync(id)
        }
    }

    // MARK: Notes repository

    /// Pushes changed meetings to the notes repository a few seconds after the last change.
    func scheduleSync(_ id: UUID? = nil, removed: UUID? = nil) {
        guard !settings.notesRepository.isEmpty else { return }
        if let id { syncPending.insert(id) }
        if let removed { syncRemoved.insert(removed) }
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await self?.runSync()
        }
    }

    /// Exports every finished meeting (first setup, or after changing the repository).
    func syncAll() {
        for m in meetings where m.status == .done { syncPending.insert(m.id) }
        scheduleSync()
    }

    private func runSync() async {
        let ids = syncPending
        let removed = syncRemoved
        syncPending = []
        syncRemoved = []
        let exports = ids.compactMap { meeting($0) }.filter { $0.status == .done }
            .map { NotesRepository.Export(meeting: $0, store: store) }
        let repo = NotesRepository(remote: settings.notesRepository)
        syncStatus = "Syncing…"
        do {
            let result = try await Task.detached { try await repo.sync(exports, removedIDs: Array(removed)) }.value
            syncStatus = "\(result) \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            log.error("notes sync failed: \(error.localizedDescription)")
            syncStatus = "Sync failed: \(error.localizedDescription)"
            syncPending.formUnion(ids)
            syncRemoved.formUnion(removed)
        }
        syncTask = nil
        if !syncPending.isEmpty || !syncRemoved.isEmpty, !(syncStatus ?? "").hasPrefix("Sync failed") { scheduleSync() }
    }

    func retranscribe(_ meeting: Meeting) {
        var m = meeting
        m.status = .processing
        try? store.save(m)
        update(m)
        enqueueProcessing(m.id)
    }

    /// Imports existing audio files (one mixed recording, or separate mic/system tracks) as a new meeting.
    func importAudio(_ urls: [URL]) {
        Task {
            do {
                var m = try store.create(Meeting(title: urls.first?.deletingPathExtension().lastPathComponent ?? "Import", status: .processing))
                for (i, url) in urls.prefix(2).enumerated() {
                    let channel: Channel = urls.count == 1 ? .them : (i == 0 ? .me : .them)
                    try AudioImport.convert(url, to: store.file("audio-\(channel.rawValue).caf", for: m))
                }
                m.endedAt = m.startedAt.addingTimeInterval(AudioImport.duration(urls[0]))
                try store.save(m)
                update(m)
                selection = m.id
                enqueueProcessing(m.id)
            } catch {
                lastError = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}
