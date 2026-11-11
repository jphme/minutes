import MinutesCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
                ContextSettings().tabItem { Label("Background", systemImage: "person.text.rectangle") }
                SummarySettings().tabItem { Label("Notes", systemImage: "sparkles") }
                SyncSettings().tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            }
            Divider()
            VersionFooter()
        }
        .environmentObject(model)
        .frame(width: 640, height: 630)
    }
}

/// Version and links, visible on every Settings tab.
struct VersionFooter: View {
    var body: some View {
        HStack(spacing: 14) {
            Text("Minutes \(AppInfo.versionText)").textSelection(.enabled).foregroundStyle(.secondary)
                .help("Version and the git commit it was built from")
            Spacer()
            Link("New versions", destination: AppInfo.releases)
            Link("GitHub", destination: AppInfo.repository)
            Button("About…") { AppInfo.showAbout() }.buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Data Protection") {
                Toggle("Transcribe only my microphone (Data Protection)", isOn: $model.settings.dataProtection)
                Text("On: meetings and passive mode never capture what your Mac plays, so the other side of calls is not recorded at all; only what you say is transcribed, and the notes are written from your side of the conversation. This is the default for new meetings and days; switch it per meeting or day with the shield in the toolbar. Use headphones: through speakers, the microphone hears the other side too. People in the same room are still picked up by the microphone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Meetings") {
                Toggle("Detect meetings when a call app uses the microphone", isOn: $model.settings.detectMeetings)
                Toggle("Record detected calls without asking", isOn: $model.settings.autoStartRecording)
                    .disabled(!model.settings.detectMeetings)
                Text("Off: when a call app (Zoom, Teams, Meet in a browser, …) starts using the microphone, Minutes shows a notification and a card in its windows, and records only when you click Record. On: it starts recording right away without a notification; the menu bar icon turns red while it records.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Stop when the meeting app releases the microphone", isOn: $model.settings.autoStopRecording)
                Toggle("Use Calendar for meeting titles and attendees", isOn: $model.settings.useCalendar)
            }
            PassiveSettingsSection()
            Section("Transcription") {
                Picker("Speech model", selection: $model.settings.asrModel) {
                    ForEach(AsrModelKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("Parakeet Ultra had the lowest German error rate in our FLEURS test (4.4 % vs 5.8 % for v3) at the same speed. All models run on the Neural Engine and support 25 European languages with automatic switching.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Keep audio recordings", isOn: $model.settings.keepAudio)
                Text("Off: audio exists only while recording and processing, then is deleted and only the transcript is kept. Turn on for debugging or to re-transcribe later (AAC, about 15 MB per hour and channel). Check the consent rules that apply to you before keeping recordings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Library") {
                HStack {
                    Text(model.settings.libraryPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                    Button("Change…") { chooseLibrary() }
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: model.settings.libraryPath)) }
                }
                Text("Every meeting is a folder with Markdown notes and transcript, readable by any tool.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { model.settings.libraryPath = url.path }
    }
}

struct SummarySettings: View {
    @EnvironmentObject var model: AppModel
    @Local private var apiKey = ""
    @Local private var keyStatus = ""

    var body: some View {
        Form {
            Section("Notes") {
                Toggle("Write notes after each meeting", isOn: Binding(
                    get: { model.settings.llmProvider == .anthropic },
                    set: { model.settings.llmProvider = $0 ? .anthropic : .none }))
                Picker("Notes language", selection: $model.settings.summaryLanguage) {
                    Text("Same as meeting").tag("auto")
                    Text("German").tag("German")
                    Text("English").tag("English")
                }
                Text("Notes are written by Claude Haiku 5.5 through the Anthropic API, about one cent per meeting hour. Only the transcript text, your notes, calendar attendees and your background are sent; audio and transcription stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    SecureField("API key", text: $apiKey, prompt: Text(Keychain.apiKey() == nil ? "sk-ant-…" : "Stored in keychain"))
                    Button("Save") { save() }
                        .disabled(apiKey.isEmpty)
                    Button("Remove") {
                        Keychain.setAPIKey(nil)
                        model.refreshKeyState()
                        keyStatus = "Removed."
                    }
                    .disabled(Keychain.apiKey() == nil)
                }
                if !keyStatus.isEmpty { Text(keyStatus).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Anthropic API key")
            } footer: {
                Text("Create a key at console.anthropic.com → API keys. It is stored encrypted in your macOS keychain, never in a file, and is used instead of an ANTHROPIC_API_KEY environment variable. Without a key, meetings get a transcript but no notes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Advanced") {
                HStack {
                    Text("Custom instructions replace the built-in prompt.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit prompt…") { editPrompt() }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Stores the key and checks it with a tiny request, so a typo shows up here and not after the next meeting.
    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = ""
        guard Keychain.setAPIKey(key) else {
            keyStatus = "Could not save to the keychain."
            return
        }
        model.refreshKeyState()
        keyStatus = "Saved. Checking the key…"
        Task {
            do {
                _ = try await AnthropicClient(apiKey: key, model: AppSettings.summaryModel)
                    .complete(system: "Reply with OK.", user: "Ping", maxTokens: 64)
                keyStatus = "Saved to the keychain. The key works."
            } catch {
                keyStatus = "Saved, but the check failed: \(error.localizedDescription)"
            }
        }
    }

    private func editPrompt() {
        let url = AppPaths.summaryPrompt
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Summarizer.defaultInstructions.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
}

/// Background for the notes model (who the user is, abbreviations, people, projects) and the vocabulary list.
/// Saved as you type.
struct ContextSettings: View {
    @EnvironmentObject var model: AppModel
    @Local private var vocabulary = AppPaths.readText(AppPaths.vocabulary)
    @Local private var context = AppPaths.readText(AppPaths.context)

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $model.settings.userName, prompt: Text("e.g. Maria Schmidt"))
                TextField("Role and company", text: $model.settings.userAbout, prompt: Text("e.g. Head of product at Acme, a logistics startup in Hamburg"), axis: .vertical)
                    .lineLimit(1...4)
            } header: {
                Text("About you")
            } footer: {
                Text("In transcripts you are “Me”; the notes use your name.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                editor($context, placeholder: """
                    Abbreviations: KI = künstliche Intelligenz, GF = Geschäftsführer, OKR = objectives and key results
                    People: Tom (CTO), Anna (sales), Dr. Weber (our lawyer)
                    Projects and customers: Project Atlas (warehouse app), Müller GmbH (pilot customer)
                    """)
                    .onChange(of: context) { _, new in try? new.write(to: AppPaths.context, atomically: true, encoding: .utf8) }
            } header: {
                Text("Background")
            } footer: {
                Text("Sent with every meeting so the notes model can resolve names, abbreviations and misheard terms.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                editor($vocabulary, placeholder: "Acme: akme, ack me\nKubernetes: cuber netties\nMüller GmbH", monospaced: true)
                    .onChange(of: vocabulary) { _, new in try? new.write(to: AppPaths.vocabulary, atomically: true, encoding: .utf8) }
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Names and terms, one per line; known misrecognitions after a colon. Corrects the transcript and is given to the notes model as a glossary.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func editor(_ text: Binding<String>, placeholder: String, monospaced: Bool = false) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110)
            if text.wrappedValue.isEmpty {
                Text(placeholder).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
            }
        }
    }
}

/// Mirrors finished meetings into a git repository, encrypted with git-crypt.
struct SyncSettings: View {
    @EnvironmentObject var model: AppModel
    @Local private var url = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Repository", text: $url, prompt: Text("https://github.com/you/meeting-notes"))
                        .onSubmit { apply() }
                    Button("Save") { apply() }.disabled(url == model.settings.notesRepository)
                }
                if !model.settings.notesRepository.isEmpty {
                    HStack {
                        Text(model.syncStatus ?? "Changes are pushed a few seconds after a meeting's notes are ready.")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        Button("Sync all now") { model.syncAll() }
                    }
                }
            } header: {
                Text("Git repository")
            } footer: {
                Text("Notes, transcripts and your own notes are committed as Markdown and pushed after each meeting, so other tools and agents can read them. Contents are encrypted with git-crypt; folder names hold only date and time. Audio is never pushed. Leave empty to turn syncing off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text(NotesRepository.keyFile.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([NotesRepository.keyFile]) }
                        .disabled(!FileManager.default.fileExists(atPath: NotesRepository.keyFile.path))
                }
            } header: {
                Text("Encryption key")
            } footer: {
                Text("Created when the repository is set up. Store a copy in your password manager: without it nobody, including you on another Mac, can read the notes. To use an existing repository, put its key file here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { url = model.settings.notesRepository }
    }

    private func apply() {
        model.settings.notesRepository = url.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
