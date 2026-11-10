# Progress

## State

Used daily in real calls (Google Meet, Teams, phone with speakers) since 2026-11-09. Working: detection, capture,
live transcript, final transcript with speakers, notes with Claude Haiku 5.5 (or transcript only without a key),
calendar linking, continue/merge after dropped calls, encrypted git sync, history UI, release DMG script.

Not yet verified by a human:
- the "Continue previous meeting" flow on a real rejoin and the notification actions,
- automatic sync after a meeting from inside the app (verified from the CLI: init, encrypted push, decrypt round-trip),
- a release DMG opened on another Mac (Gatekeeper flow for an ad-hoc signed app).

## Passive mode

All-day transcription into a daily digest (README → Passive mode). Verified by agent: CLI capture with speech
through the speakers (Minutes + coreaudiod: 5.5 % of one core with speech, 2.4 % in silence, after raising the IO
buffers to 4096 frames; flat memory over 15 min), echo filtering, digest and day summary on a synthetic noisy day
(noise filtered, tasks and decisions kept, ≈ $0.003 per update), UI snapshots, app launch with passive mode on.
Live preview verified from files (`minutes-cli passive --me-file … --preview`): lines show about 2 s into an
utterance instead of up to 30 s after it. Used by a human since 2026-11-10 with the redesigned window (Day notes in
the sidebar, live preview).

Not yet verified by a human:
- live preview switching off when the transcript is hidden or covered by other windows,
- a full working day: digest quality on real noise, number of updates and cost per day, battery drain on battery,
- screen-lock and sleep pauses, the battery threshold, pause/resume and "Forget last 15 min" in the menu bar,
- the meeting hand-off (passive pauses during a recording, marker in the day, resumes after),
- the Bluetooth-headset rule (built-in mic used while AirPods are the default input).

## Next steps, roughly in order

1. First release: the repository is public (github.com/jphme/minutes, since 2026-11-10); publish a first DMG
   (`scripts/make-release.sh`, ad-hoc signed; no Developer ID for now, so users approve the first launch under
   Privacy & Security) as a GitHub release, which the README's install steps link to. Name stays "Minutes", bundle
   identifier `me.jph.minutes`.
2. First-run onboarding window (permissions, API key, background), launch at login (SMAppService).
3. Real-call test with speakers instead of headphones; check echo removal (`FinalTranscriber.removeEcho`). If speaker use is common, add FluidAudio's LocalVQE echo cancellation on the mic using the tap as reference.
4. Speaker recognition across meetings: match new speakers against named ones in earlier meetings' `speakers.json` (`SpeakerMatcher` already does this within a meeting).
5. Background knowledge: feed relevant past meeting notes into the summary.
6. Optional live diarization (LS-EEND/Sortformer) so the live view shows speakers, not just "Them".
