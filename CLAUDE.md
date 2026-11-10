# Minutes: notes for coding agents

Read README.md first for what the app does and how the pipeline fits together. PROGRESS.md has the open work.

## Build gotchas (Command Line Tools only, no Xcode)

- **No `@State` in SwiftUI views.** On the macOS 27 SDK `@State` is a macro whose plugin ships only with Xcode; the build fails with "plugin for module 'SwiftUIMacros' not found". Use `@Local` (Sources/Minutes/Views/Local.swift), a drop-in built on `@StateObject`. `@StateObject`, `@Published`, `@EnvironmentObject` are fine.
- **Swift builds need the Claude Code sandbox off**: SwiftPM writes into `.build/checkouts/*/.git` and starts its own sandbox, both blocked inside Claude Code's sandbox.
- Inside the Claude Code sandbox, `say`, `open`, `afplay`, `log`, `iconutil` and `screencapture` do not work (`iconutil` only says "Failed to generate ICNS"), and writes to `.git` are blocked, so `git add`/`commit`/`push` need the sandbox off. `screencapture` also lacks Screen Recording permission; use `Minutes --snapshot DIR` to look at the UI.
- In zsh, `log` may be shadowed; call `/usr/bin/log`. Info-level unified logs are not persisted: read `~/Library/Application Support/Minutes/logs/app.log`.

## Permissions and signing

- TCC keys microphone, system-audio and calendar permissions to the code signature. Ad-hoc signing changes every build, so **each rebuild re-triggers the permission prompts**. `scripts/create-signing-cert.sh` (run by the human; agents cannot add keychain identities) makes local signatures stable, and `scripts/build-app.sh` uses it automatically. Releases are built with `scripts/make-release.sh` (ad-hoc, or Developer ID plus notarization); `.github/workflows/release.yml` runs it on every push to main and publishes a release when the Info.plist version has none yet, so bump `CFBundleShortVersionString` only when a release is intended. The runner (`xcode-27` image) must build with the same macOS SDK as local development: built with the macOS 26 SDK, SwiftUI drew the selected sidebar row as a black bar. When the local SDK moves on, move the runner image too. Each run uploads offscreen screenshots of the demo library as an artifact; look at them before announcing a release.
- The user runs the released app from `/Applications`. `scripts/build-app.sh` installs to `~/Applications`, which makes a second "Minutes" in Spotlight and Launchpad: use `--no-install` (the bundle lands in `build.noindex/`, which Spotlight skips) unless the user asked to install a dev build, and say so when you do.
- **Keychain prompts block silently.** `codesign` with the local certificate, or another binary reading the app's keychain item, can open a SecurityAgent dialog that waits for the user; the command then hangs. Killing SecurityAgent turns signing into `errSecInternalComponent`. The CLI therefore reads `ANTHROPIC_API_KEY` only from the environment or `./.env`.
- System-audio permission has no request API: the prompt appears when a process tap first runs. Denial is silent (all-zero buffers); `RecordingSession.checkSilence` warns about it.
- Calendar access is tied to the app bundle: a CLI cannot read the calendar. Use `open -n -a ~/Applications/Minutes.app --args --calendar-report <file> [days]`.

## Testing without a human

- `open "minutes://start"`, play a file with `afplay`, `open "minutes://stop"`, then inspect the newest folder in the library and `logs/app.log`. Make sure nothing else is playing audio, and avoid speakers when Siri is enabled (synthetic speech once triggered it).
- For pipeline changes prefer the CLI on files (`minutes-cli process`, `bench/make_meeting.py`), with `MINUTES_SUPPORT_DIR` and `--library` pointing at scratch folders so real settings, vocabulary, meetings and the notes repository stay untouched.
- With `MINUTES_SUPPORT_DIR` set, and with `--snapshot`, the app does not touch the keychain: a keychain read from a build the item's ACL does not list opens a SecurityAgent dialog and the app hangs until someone answers it.
- UI: `Minutes --snapshot DIR` renders every screen offscreen with made-up calendar events and passive mode shown as listening (`--passive-off` for the other state), and prints a "selection check" line: it drags the mouse over the notes in the offscreen window to prove text can be selected across paragraphs, and a "notes width check" line: it switches between meetings in one window and fails if the notes are laid out narrower than their view (a SwiftUI size probe once left them in a 50 pt column; `SelectableText` must measure with its own layout objects, never the displayed text view's). Nothing comes to the foreground. The menu bar window is rendered at its natural height, like the real one.
- README screenshots (`docs/screenshots/`) come from the fictional library in `docs/demo-library/`, never from a real library (meeting titles and notes are private): `MINUTES_SUPPORT_DIR=<dir with settings.json {"libraryPath": "<abs path>/docs/demo-library", "useCalendar": false}> .build/release/Minutes --snapshot <out>`, then copy main.png → meeting-notes.png, transcript.png, day-notes.png and menubar.png → menu-bar.png. The demo dates are fixed (2026-11-09/10), so on later dates they show as older days; move them if "Today" matters.
- Passive mode: `minutes-cli passive --seconds N --library DIR [--digest]` captures like the app and prints CPU and Neural Engine time; with `--me-file`/`--them-file` it plays files through the same pipeline in real time (no microphone, nothing audible) and prints when each line is previewed and stored. For digest prompt changes, rerun `minutes-cli digest --library DIR --day D --reset --final` on a noisy test day (media, small talk, other people's talk, a personal call, one recorded meeting) and check that noise stays out and tasks stay in.

## Design decisions worth keeping

- Transcription is local only; notes go to the Anthropic API with the user's key. Raw HTTP in `AnthropicClient` because there is no official Swift SDK; keep `anthropic-version` and the refusal handling current with the Messages API docs.
- The notes model is fixed (`AppSettings.summaryModel` = Haiku 5.5, `summaryEffort` = high) after a blind comparison on a real call; no model setting in the UI. `minutes-cli compare --models model:effort,...` reruns one. Without an API key the app works as a transcriber only.
- The key from Settings (keychain) wins over `ANTHROPIC_API_KEY`.
- Audio is deleted after the final transcript unless `keepAudio` is on (legal default).
- Microphone capture uses a HAL IOProc, not AVAudioEngine: AVAudioEngine stopped on every route change and restarting it caused a restart loop.
- `RateTracker` checks the real delivery rate against the host clock because tap and device formats go stale (a 16 kHz stream read as 48 kHz produced unusable audio).
- Stopping a recording must never wait on Core Audio teardown (`SystemAudioCapture.detach`): a Bluetooth headset disconnecting mid-call made the teardown hang for minutes.
- Passive mode stores text only (`Days/<date>/`), never audio, and pauses while a meeting records. The system tap delivers no buffers until some app first plays sound (measured; afterwards it delivers zeros), so without an audio file `ChannelPipeline` skips long gaps instead of padding them with silence (hours of zeros would be gigabytes of memory). It records from the built-in mic when the default input is Bluetooth (an open headset mic forces the call profile on all audio), and asks for 4096-frame IO buffers: with the default 512 frames an open mic alone cost 4.4 % of a core in `coreaudiod` (measure `coreaudiod`'s CPU time too, not only Minutes').
- Passive mode transcribes each utterance once, when it ends; partial lines every 2 s run only while today's transcript is on screen in a visible window (`PassiveModel.updateLivePreview`), because they roughly double the transcription work. What the user sees early are previews (`PassiveRecorder.Preview`), never stored; storing a microphone line still waits 30 s for the echo check.
- One UI for meetings and passive days: `DayView` mirrors `MeetingDetailView` (header, Notes/Transcript tabs, the same toolbar order), both transcripts use `TranscriptRow`, and the menu bar window and the sidebar footer share `PassiveControl`. A feature added in one place belongs in the other. Notes render in one `NSTextView` (`MarkdownView`) so text selects across paragraphs. Sidebar sections are `.collapsible(false)`: a click on a section header otherwise hides that day's meetings.
- Custom vocabulary rescoring uses an English CTC model that over-fires on German; `AsrEngine.isPlausible` only accepts replacements that are textually close to the term or listed aliases. Do not loosen it without re-running the synthetic meeting diff.
- Meeting detection uses Core Audio's process list and a hand-curated list of call apps and browsers (`MeetingDetector.knownApps`). Keep the project independent of other products: no code, prompts or data taken from them.
- Notes sync (`NotesRepository`): never push a meeting file that is not a git-crypt blob. Readable titles in folder names and commit messages are intended; git-crypt encrypts contents only.

## Working conventions

- Edit files with the Write/Edit tools, not python or sed scripts. Run `git add`, `git commit` and `git push` as separate plain commands, and disable the sandbox only for the single command that needs it.
- `origin` uses SSH, which fails from a sandboxed agent shell. Push over HTTPS with the `gh` credential helper:
  `git -c credential.helper= -c credential.helper='!gh auth git-credential' push https://github.com/jphme/minutes.git <branch>`.
