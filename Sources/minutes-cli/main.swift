import AVFoundation
import FluidAudio
import Foundation
import MinutesCore

// Developer CLI: benchmarks and runs the meeting pipeline on audio files without the GUI.

func usage() -> Never {
    print(
        """
        usage:
          minutes-cli transcribe --model <\(AsrModelKind.allCases.map(\.rawValue).joined(separator: "|"))> [--jsonl out.jsonl] file...
          minutes-cli process [--library dir] [--title T] [--me me.wav] [--them them.wav] [--no-summary] [--data-protection]
              Imports the recordings as a meeting and runs the post-meeting pipeline (final transcript, speakers, notes).
              --data-protection marks it as recorded in Data Protection mode: the --them track is dropped unheard
              and the notes are written from the microphone side only.
          minutes-cli record --seconds N [--library dir] [--live]
              Records system audio + microphone into a new meeting folder (raw CAF, no post-processing).
          minutes-cli store-api-key
              Saves ANTHROPIC_API_KEY from the environment or ./.env to the keychain for the app.
          minutes-cli summarize --library dir --meeting <folder name>
              Regenerates the notes for an existing meeting.
          minutes-cli merge --library dir --meeting <folder> --with <folder> [--summarize]
              Appends the second meeting to the first (one transcript, speakers matched by voice).
          minutes-cli compare --library dir --meeting <folder> [--models model[:effort],...] [--languages German,English] --out file.json
              Generates notes with each model (optionally at an effort level) and language without saving them,
              with tokens, cost and time.
          minutes-cli delete --library dir --meeting <folder>
              Moves a meeting to the Trash and removes it from the notes repository.
          minutes-cli sync-notes [--library dir] [--repo url]
              Exports all finished meetings and passive days to the notes git repository (git-crypt encrypted) and pushes.
          minutes-cli passive --seconds N [--library dir] [--channels me|them|both] [--digest] [--preview]
                              [--me-file mic.wav] [--them-file system.wav] [--data-protection]
              Passive mode without the app: transcribes mic + system audio into <library>/Days/<date>/ (text only),
              prints work statistics (CPU, Neural Engine time), and with --digest updates the day's digest at the end.
              With --me-file/--them-file, plays files through the pipeline in real time instead of capturing.
              --preview turns on live preview (partial lines while an utterance is spoken).
          minutes-cli digest [--library dir] [--day YYYY-MM-DD] [--reset] [--final]
              Updates a day's rolling digest from its transcript (--reset starts it over); --final also writes
              the end-of-day summary.
        """)
    exit(2)
}

// Read ANTHROPIC_API_KEY (and other variables) from ./.env if present.
// Only this process sees the values; existing environment variables win. The CLI never reads the app's keychain
// item: its access dialog would block the command.
Keychain.environmentOnly = true
if let env = try? String(contentsOfFile: ".env", encoding: .utf8) {
    for line in env.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].hasPrefix("#") else { continue }
        let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        setenv(parts[0].replacingOccurrences(of: "export ", with: ""), value, 0)
    }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

switch command {
case "transcribe":
    guard let modelName = option("--model"), let kind = AsrModelKind(rawValue: modelName) else { usage() }
    let jsonlPath = option("--jsonl")
    let engine = AsrEngine(kind: kind)
    let loadStart = Date()
    try await engine.load()
    FileHandle.standardError.write("loaded \(kind.rawValue) in \(String(format: "%.1f", Date().timeIntervalSince(loadStart)))s\n".data(using: .utf8)!)
    let converter = AudioConverter()
    var lines: [String] = []
    var totalAudio = 0.0
    var totalProc = 0.0
    for path in args {
        let samples = try converter.resampleAudioFile(path: path)
        let out = try await engine.transcribe(samples)
        let dur = Double(samples.count) / 16000
        totalAudio += dur
        totalProc += out.processingTime
        let obj: [String: Any] = [
            "file": (path as NSString).lastPathComponent, "text": out.text, "duration": dur,
            "proc": out.processingTime,
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        let line = String(data: data, encoding: .utf8)!
        lines.append(line)
        if jsonlPath == nil { print(line) }
    }
    if let jsonlPath {
        try (lines.joined(separator: "\n") + "\n").write(toFile: jsonlPath, atomically: true, encoding: .utf8)
    }
    FileHandle.standardError.write(
        "audio \(String(format: "%.0f", totalAudio))s, processing \(String(format: "%.1f", totalProc))s, RTFx \(String(format: "%.0f", totalAudio / max(totalProc, 0.001)))\n"
            .data(using: .utf8)!)
case "process":
    var settings = AppPaths.loadSettings()
    let library = option("--library").map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: settings.libraryPath)
    let title = option("--title") ?? "Imported meeting"
    let me = option("--me")
    let them = option("--them")
    if args.contains("--no-summary") { settings.llmProvider = .none }
    let store = MeetingStore(root: library)
    var meeting = Meeting(title: title, status: .processing)
    if args.contains("--data-protection") { meeting.dataProtection = true }
    meeting = try store.create(meeting)
    for (channel, path) in [(Channel.me, me), (Channel.them, them)] {
        guard let path else { continue }
        // Normalize to 16 kHz mono CAF, as the recorder would have written it.
        let samples = try AudioConverter().resampleAudioFile(path: path)
        let url = store.file("audio-\(channel.rawValue).caf", for: meeting)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buf)
        meeting.endedAt = meeting.startedAt.addingTimeInterval(Double(samples.count) / 16_000)
    }
    try store.save(meeting)
    let asr = AsrEngine(kind: settings.asrModel)
    let processor = MeetingProcessor(store: store, asr: asr)
    let t0 = Date()
    meeting = await processor.process(meeting, settings: settings) { p in
        switch p {
        case .stage(let s): FileHandle.standardError.write("[\(String(format: "%5.1f", Date().timeIntervalSince(t0)))s] \(s)\n".data(using: .utf8)!)
        case .summaryDelta(let d): FileHandle.standardError.write(d.data(using: .utf8)!)
        }
    }
    print("\nstatus: \(meeting.status.rawValue) \(meeting.error ?? "")")
    print("folder: \(store.folder(for: meeting).path)")
case "record":
    let seconds = Double(option("--seconds") ?? "10") ?? 10
    let library = option("--library").map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "bench/out/rec")
    let live = args.contains("--live")
    let store = MeetingStore(root: library)
    let meeting = try store.create(Meeting(title: "CLI recording"))
    var asr: AsrEngine?
    var vad: VadManager?
    if live {
        asr = AsrEngine(kind: AppPaths.loadSettings().asrModel)
        try await asr!.load()
        vad = try await VadManager()
    }
    let session = RecordingSession(meeting: meeting, store: store) { seg in
        if seg.isFinal { print(String(format: "%6.1f %@ %@", seg.start, seg.speaker, seg.text)) }
    }
    try await session.start(asr: asr, vad: vad)
    for w in session.warnings { print("warning: \(w)") }
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    await session.stop()
    print("folder: \(store.folder(for: meeting).path)")
case "store-api-key":
    // Copies ANTHROPIC_API_KEY (environment or ./.env) into the keychain item the app reads. Never prints it.
    guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
        print("ANTHROPIC_API_KEY is not set (environment or ./.env)"); exit(1)
    }
    let app = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Minutes.app").path
    print(Keychain.setAPIKey(key, trustedApps: [app]) ? "stored in keychain (\(key.count) characters)" : "keychain write failed")
case "summarize":
    let settings = AppPaths.loadSettings()
    guard let lib = option("--library"), let folder = option("--meeting") else { usage() }
    let store = MeetingStore(root: URL(fileURLWithPath: lib))
    guard var meeting = store.list().first(where: { $0.folderName == folder }) else { print("not found"); exit(1) }
    let processor = MeetingProcessor(store: store, asr: AsrEngine(kind: settings.asrModel))
    let t0 = Date()
    do {
        meeting = try await processor.summarize(meeting, settings: settings) { p in
            if case .stage(let s) = p { FileHandle.standardError.write("[\(String(format: "%5.1f", Date().timeIntervalSince(t0)))s] \(s)\n".data(using: .utf8)!) }
        }
        FileHandle.standardError.write("summary done in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s\n".data(using: .utf8)!)
        print(store.read("summary.md", for: meeting) ?? "")
    } catch {
        print("error: \(error.localizedDescription)")
    }
case "merge":
    let settings = AppPaths.loadSettings()
    guard let lib = option("--library"), let a = option("--meeting"), let b = option("--with") else { usage() }
    let store = MeetingStore(root: URL(fileURLWithPath: lib))
    let all = store.list()
    guard let first = all.first(where: { $0.folderName == a }), let second = all.first(where: { $0.folderName == b }) else {
        print("not found"); exit(1)
    }
    var merged = try store.merge(second, into: first)
    print("merged into: \(merged.folderName) (\(merged.allParts.count) parts)")
    if args.contains("--summarize") {
        let processor = MeetingProcessor(store: store, asr: AsrEngine(kind: settings.asrModel))
        merged = try await processor.summarize(merged, settings: settings)
        print("title: \(merged.title)")
    }
case "compare":
    var settings = AppPaths.loadSettings()
    guard let lib = option("--library"), let folder = option("--meeting"), let out = option("--out") else { usage() }
    let models = (option("--models") ?? "claude-sonnet-5-5,claude-haiku-5-5").split(separator: ",").map(String.init)
    let languages = (option("--languages") ?? "auto").split(separator: ",").map(String.init)
    let store = MeetingStore(root: URL(fileURLWithPath: lib))
    guard let meeting = store.list().first(where: { $0.folderName == folder }) else { print("not found"); exit(1) }
    let processor = MeetingProcessor(store: store, asr: AsrEngine(kind: settings.asrModel))
    var results: [[String: Any]] = []
    for language in languages {
        settings.summaryLanguage = language
        for spec in models {
            let parts = spec.split(separator: ":").map(String.init)
            let effort = parts.count > 1 ? parts[1] : nil
            let (output, c) = try await processor.generateNotes(meeting, settings: settings, model: parts[0], effort: effort)
            results.append([
                "meeting": meeting.folderName, "language": language, "model": c.model, "effort": effort ?? "default",
                "title": output.title ?? "",
                "markdown": output.markdown, "inputTokens": c.inputTokens, "outputTokens": c.outputTokens,
                "seconds": c.seconds, "costUSD": c.costUSD,
            ])
            print("\(language) \(c.model) \(effort ?? "default"): \(String(format: "%.1f", c.seconds)) s, \(c.inputTokens)/\(c.outputTokens) tokens, $\(String(format: "%.4f", c.costUSD))")
        }
    }
    let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: out))
case "delete":
    let settings = AppPaths.loadSettings()
    guard let folder = option("--meeting") else { usage() }
    let store = MeetingStore(root: URL(fileURLWithPath: option("--library") ?? settings.libraryPath))
    guard let meeting = store.list().first(where: { $0.folderName == folder }) else { print("not found"); exit(1) }
    try store.delete(meeting)
    print("moved to Trash: \(folder)")
    if !settings.notesRepository.isEmpty {
        print(try await NotesRepository(remote: settings.notesRepository).sync([], removedIDs: [meeting.id]))
    }
case "sync-notes":
    let settings = AppPaths.loadSettings()
    let store = MeetingStore(root: URL(fileURLWithPath: option("--library") ?? settings.libraryPath))
    guard let url = option("--repo") ?? (settings.notesRepository.isEmpty ? nil : settings.notesRepository) else {
        print("no repository configured (Settings → Sync, or --repo)"); exit(1)
    }
    let repo = NotesRepository(remote: url)
    let meetings = store.list().filter { $0.status == .done }
    let dayStore = DayStore(library: store.root)
    let result = try await repo.sync(
        meetings.map { NotesRepository.Export(meeting: $0, store: store) }, removedIDs: [],
        days: dayStore.days().map { NotesRepository.DayExport(day: $0, store: dayStore) })
    print(result)
case "passive":
    let settings = AppPaths.loadSettings()
    let seconds = Double(option("--seconds") ?? "60") ?? 60
    let library = URL(fileURLWithPath: option("--library") ?? "bench/out/passive")
    let store = DayStore(library: library)
    let asr = AsrEngine(kind: settings.asrModel)
    try await asr.load()
    let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.5))
    // --channels me|them|both (default both), to measure the cost of each capture.
    var channels: Set<Channel> = switch option("--channels") {
    case "me": [.me]
    case "them": [.them]
    default: [.me, .them]
    }
    // --data-protection: microphone only, with the marker the app writes, as in the app's Data Protection mode.
    if args.contains("--data-protection") {
        channels = [.me]
        store.append(.dataProtection(true))
    }
    // --me-file / --them-file: play audio files through the pipeline in real time instead of capturing (no
    // microphone, nothing audible), to test passive mode without talking. --preview turns live preview on.
    let files: [(Channel, String)] = [(.me, option("--me-file")), (.them, option("--them-file"))].compactMap { c, p in p.map { (c, $0) } }
    let started = Date()
    @Sendable func stamp() -> String { String(format: "%5.1f s", Date().timeIntervalSince(started)) }
    let recorder = PassiveRecorder(
        store: store, channels: channels,
        onPreview: { p in
            print("\(stamp())  preview \(p.channel == .me ? "Mic" : "Mac") \(p.text.isEmpty ? "(removed)" : p.ended ? "ended:   \(p.text)" : "partial: \(p.text)")")
        }
    ) { entry in
        print("\(stamp())  stored  [\(DayStore.clock(entry.start))] \(entry.source): \(entry.text)")
    }
    func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    let cpuStart = cpuSeconds()
    let wallStart = Date()
    try await recorder.start(asr: asr, vad: vad, capture: files.isEmpty)
    if args.contains("--preview") { await recorder.setLivePreview(true) }
    for w in recorder.warnings { print("warning: \(w)") }
    if files.isEmpty {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    } else {
        let tracks = try files.map { ($0.0, try AudioConverter().resampleAudioFile(path: $0.1)) }
        let chunk = 1_600  // 100 ms
        var offset = 0
        while Date().timeIntervalSince(started) < seconds {
            for (channel, samples) in tracks {
                // Silence after a file ends, so the last utterance closes and the echo hold can run out.
                let slice = offset < samples.count ? Array(samples[offset..<min(offset + chunk, samples.count)]) : [Float](repeating: 0, count: chunk)
                recorder.feed(channel, samples: slice)
            }
            offset += chunk
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    await recorder.stop()
    let wall = Date().timeIntervalSince(wallStart)
    let cpu = cpuSeconds() - cpuStart
    let s = await recorder.stats()
    print(
        String(
            format: "\nwall %.0f s, CPU %.2f s (%.2f %% of one core), ASR busy %.2f s (%.2f %%) in %d calls on %.0f s of speech, VAD %d calls, %d silent hops skipped, %d utterances",
            wall, cpu, 100 * cpu / wall, s.asrBusySeconds, 100 * s.asrBusySeconds / wall, s.asrCalls, s.asrAudioSeconds,
            s.vadCalls, s.silentHopsSkipped, s.segments))
    let power = PowerSource.current()
    print(
        "power: \(power.onBattery ? "battery" : "AC"), charge \(power.percent.map { "\($0) %" } ?? "n/a"), would pause at the default threshold: \(PowerSource.shouldPause(power, threshold: AppSettings().passiveBatteryThreshold))")
    let day = DayStore.key(for: Date())
    print("day folder: \(store.folder(day).path)")
    if args.contains("--digest") {
        let result = try await DayDigester(store: store, settings: settings).update(day)
        print(String(format: "digest: %d call(s), %d in / %d out tokens, $%.4f", result.calls, result.inputTokens, result.outputTokens, result.costUSD))
        print(store.read("digest.md", day: day) ?? "(no digest)")
    }
case "digest":
    let settings = AppPaths.loadSettings()
    let libraryPath = option("--library") ?? settings.libraryPath
    let store = DayStore(library: URL(fileURLWithPath: libraryPath))
    let day = option("--day") ?? DayStore.key(for: Date())
    if args.contains("--reset") {
        store.updateState(day) { $0.digestedEntries = 0 }
        try? FileManager.default.removeItem(at: store.file("digest.md", day: day))
    }
    let digester = DayDigester(store: store, settings: settings)
    let t0 = Date()
    let result = try await digester.update(day)
    print(
        String(
            format: "digest: %d call(s) (%d unchanged), %d in / %d out tokens, $%.4f, %.1f s", result.calls, result.unchanged,
            result.inputTokens, result.outputTokens, result.costUSD, Date().timeIntervalSince(t0)))
    print(store.read("digest.md", day: day) ?? "(no digest)")
    if args.contains("--final") {
        let meetings = DayDigester.meetings(on: day, in: MeetingStore(root: URL(fileURLWithPath: libraryPath)))
        let c = try await digester.finalize(day, meetings: meetings)
        print(String(format: "\nsummary: %d in / %d out tokens, $%.4f, %.1f s\n", c.inputTokens, c.outputTokens, c.costUSD, c.seconds))
        print(store.read("summary.md", day: day) ?? "")
    }
default:
    usage()
}
