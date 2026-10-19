# Jarvis ambient memory

Branch `feature/jarvis-ambient-memory` (64 commits on top of `main`), plus the local repo
`/Users/yashmangal/homebrew-tap` (commits `fe5f20c`, `b410c46`, no remote yet). Built 17–18 Oct 2026 as
29 tickets in 10 waves. The run's working files are in `.agentic/jarvis-ambient-memory/` (git-ignored):
`spec.md`, `blueprint.md`, `tickets/`, `implement/`, `review/`, `qa/`, `run.json`, `RESUME.md`. The binding
decision record is `DECISIONS.md` at the repo root.

## 1. Final architecture

There are two SwiftPM targets (tools 6.0, language mode 5, macOS 13 floor) and one test target.

- **JarvisCore** (library, no UI): the whole pipeline, all of its rules and every engine.
- **JarvisApp** (executable): a SwiftUI `MenuBarExtra` app. It shows things and forwards input: the icon,
  the menu, the Settings and Ask windows, permission prompts, the ⌥Space Carbon hotkey, the AirPods stem
  trigger, the system sounds and `AVSpeechSynthesizer`. Every rule it needs is in JarvisCore (DEC-20).
- **JarvisCoreTests**: Swift Testing.

JarvisCore folders:

| Folder | Holds |
|---|---|
| `Pipeline/` | the four protocols (`Transcriber`, `NoteWriter`, `Embedder`, `CommandRunner`), `SilenceGate`, `CapturePipeline`, `TranscriptText` |
| `Model/` | `AudioChunk`, `AudioSource` → `SpeakerLabel` ("Me"/"Others"), `TimeSource` |
| `Storage/` | `JarvisPaths` (`~/Library/Application Support/Jarvis`, DEC-41; adopts a pre-0.1 `~/Jarvis` once), `TranscriptStore` (JSONL per day), `Settings`/`SettingsStore` |
| `Session/` | `ListeningSession` (Listening/Paused/Stopped, gaps, quiet hours, lock), `SleepGuard`, `ScreenLockObserver`, `SpeakingTracker` |
| `Audio/` | `MicSource`, `SystemAudioSource`, `RoomMicSource`, `ChunkAssembler`, `RollingAudioBuffer`, `AudioRouteMonitor` |
| `Notes/` | `PromptStore`, `NoteStore`, `HourlyNoteScheduler`, `RollupScheduler`, `LaunchMaintenance` |
| `Search/` | `NoteIndex` (`index/vectors.json`), `MemorySearch` |
| `Memory/` | `ForgetLastHour`, `ForgottenWindows` |
| `Commands/` | `CommandSession`, `VoiceIntent`, `VoiceControlRouter`, `WakeWordListener`, `CommandCapture` |
| `Import/` | `FolderWatcher`, `ScanScheduler`, `ImportCoordinator`, `InboxImporter`, `VoiceMemosLocator`/`Importer`, `ImportLedger`, `RecordingDate`, `AudioFileDecoder` |
| `Engines/` | `Whisper/`, `Apple/` (SpeechAnalyzer, Foundation Models, Core AI, NLContextual, NLEmbedding), `Claude/`, `Ollama/`, `EngineProbes`, `EngineSelector` |
| `Process/` | `ChildProcess` (bounded waits for `claude` and `whisper-cli`) |
| root | `Jarvis.swift` (the facade), `SourceFactory.swift` |

```
 JarvisApp (menu, windows, hotkey, stem, sounds, speech)
        │  binds @ObservedObject, calls methods
        ▼
 Jarvis (facade) ── owns ──► ListeningSession ─► which sources run
   │                          CapturePipeline ─► TranscriptStore
   │                          HourlyNoteScheduler / RollupScheduler ─► NoteStore ─► NoteIndex
   │                          VoiceControlRouter ─► CommandSession ─► CommandRunner
   │                          InboxImporter / VoiceMemosImporter ─► ImportCoordinator
   └── engines: () -> (any Protocol)?   chosen by EngineSelector.select(EngineProbes.live())
```

**The facade.** `Jarvis` is the only entry point. `Jarvis.live()` probes the Mac, selects engines, builds the
real sources and starts the whisper servers in the background. `start()` makes the folder layout, runs
launch maintenance, rebuilds the index, starts the session and importers, and runs a 30 s tick.
`shutdown()` stops everything, and the app's quit waits for it. The app reads published state from it
(icon state, Engines line, menu lines, `lastMemoryAnswer`, `isSpeaking`) and calls its methods
(`askMemory`, `askToForgetLastHour`/`forgetLastHour`, `chooseTopMenuItem`, `beginHoldCommand`/`endHoldCommand`,
`stemPressed`, `setStemTrigger`, `speechStarted`/`speechEnded`).

**Engines** are injected as optional closures, and `nil` means off (DEC-5). The selector is a pure function
over what the probes found, and the probes are the only part with side effects:

| Role | Order |
|---|---|
| Transcriber | SpeechAnalyzer (macOS 26+, every preferred locale covered, built with Swift ≥ 6.2) → whisper.cpp (`whisper-server`, `whisper-cli` fallback) → none |
| Wake word | SpeechAnalyzer if chosen above, else a second whisper server on the wake model (`base.en`) |
| Note writer | Claude Code CLI → Apple Foundation Models (macOS 26+) → Ollama (server answering) → off |
| Embedder | Core AI (macOS 27, model file present; dormant today) → `NLContextualEmbedding` "Apple contextual" (macOS 14+, assets present) → `NLEmbedding` |
| Command runner | Claude Code CLI, or none |

The transcriber swaps live. Speech starts when the whisper model download finishes, with no relaunch. The
embedder stays fixed for the whole launch (DEC-5 amended). Settings shows the result as
`Speech: … · Notes: … · Search: …`.

## 2. Files changed

There are 125 files and +14,024 lines in the jarvis repo, with nothing deleted, because the repo was empty
apart from `docs/`.

| Area | Files | Lines | Notes |
|---|---|---|---|
| `Package.swift`, `.gitignore`, `LICENSE` | 3 | 48 | MIT (DEC-34). `models/*.bin` is ignored |
| `Sources/JarvisCore/` facade + `SourceFactory` | 2 | 637 | `Jarvis.swift` is 587 lines |
| `Sources/JarvisCore/Engines/` | 19 | 1,306 | Whisper 5, Apple 7, Claude 3, Ollama 2, selector/probes 2 |
| `Sources/JarvisCore/Audio/` | 7 | 675 | |
| `Sources/JarvisCore/Commands/` | 5 | 669 | |
| `Sources/JarvisCore/Import/` | 9 | 679 | |
| `Sources/JarvisCore/Notes/` | 5 | 409 | |
| `Sources/JarvisCore/Session/` | 4 | 349 | |
| `Sources/JarvisCore/Storage/`, `Model/`, `Pipeline/`, `Search/`, `Memory/`, `Process/` | 14 | 909 | |
| `Sources/JarvisApp/` | 12 | 720 | 11 Swift files + `Info.plist` |
| `Tests/JarvisCoreTests/` | 39 | 6,393 | the largest are `SwappabilityTests` (809), `WhisperTranscriberTests` (547), `ListeningSessionTests` (413) |
| `install.sh`, `install/install.sh`, `install/uninstall.sh` | 3 | 377 | |
| `README.md`, `docs/guide.html`, `DECISIONS.md` | 3 | 853 | the guide is published by GitHub Pages (DEC-29) |
| homebrew-tap `Formula/jarvis.rb` | 1 | 108 | separate repo |

## 3. Implementation flow

**Audio to transcript.** `MicSource` puts an `AVAudioEngine` tap on the default input, converts it to 16 kHz mono
Float32 and splits the result two ways. One copy goes to `ChunkAssembler`, which makes 30 s chunks. The other is
a stream of 250 ms frames for the wake word. `SystemAudioSource` (ScreenCaptureKit, audio only,
`excludesCurrentProcessAudio`) is a separate stream. In Meeting mode, `RoomMicSource` adds a second engine pinned
to the built-in mic, and it refuses to start when the built-in mic is already the default input. The mic is
labelled "Me". System audio and the room mic are "Others".

`Jarvis` passes a chunk to `CapturePipeline` only if `ListeningSession.storesMemory`. Sources cut their chunk at
every listening boundary (DEC-24), so a chunk is wholly inside listening or wholly outside it. The pipeline drops
chunks below −50 dBFS, transcribes the rest and cleans the text (it drops bracket tokens such as `[BLANK_AUDIO]`).
It skips any time in `ForgottenWindows` and appends one line to `transcripts/YYYY-MM-DD.jsonl`. No audio is
written to disk, with one exception: the `whisper-cli` fallback writes a short-lived temp WAV (DEC-11).

**Session.** Every state change goes through one `transition(to:)`. It records gaps ("14:05–14:40: not listening (AirPods disconnected)"), holds the
IOKit idle-sleep assertion only while listening, and publishes the icon, status line and top menu item. AirPods
loss pauses and reconnect resumes. Screen lock and quiet hours stop. User pause and stop are sticky. Quiet hours
override everything automatic (DEC-14). A deliberate "Start listening" overrides them until the window ends
(DEC-27).

**Notes and roll-ups.** On each 30 s tick, `HourlyNoteScheduler` writes the last finished hour (or 2-minute slot in
Demo mode) to `notes/hourly/<id>.md`, if it had speech and a writer exists. It uses the editable
`prompts/hourly.md` and appends a `## Gaps` section. An id is never rewritten. Once an hour, after the hourly
note, `LaunchMaintenance` purges transcripts older than 7 days and `RollupScheduler` writes the missing daily notes
(from hourly notes) and weekly notes (ISO weeks, from daily notes). A period counts as finished 5 minutes after it
ends.

**Search.** `NoteStore.onWrite` feeds `NoteIndex`. It keeps one JSON file, rewritten atomically, with one vector and a
SHA-256 of the note text per note, keyed by the embedder's name (DEC-8). At launch, `rebuild` re-embeds notes whose
text changed and drops deleted ones. `MemorySearch.answer` embeds the question and takes the top-k cosine hits
(vDSP). It sends them, each headed by its note id, to the note writer with `prompts/answer.md`, and returns
`MemoryAnswer(text, usedNoteIDs)`. A spoken question is answered aloud. Every answer is published as
`lastMemoryAnswer` for the Ask panel.

**Wake word, commands and read-back.** `WakeWordListener` keeps an 8 s `RollingAudioBuffer` in memory. About once a
second it sends the last 2.5 s to the wake engine, skipping silent windows. When it hears "jarvis" it chimes, and
`CommandCapture` collects audio from the start of that utterance until 1 s of silence (15 s at most). The text
after "jarvis" becomes the command. ⌥Space hold uses `beginHoldCommand`/`endHoldCommand` (a 120 s cap, and it works
while Stopped: DEC-22). The stem squeeze is press-to-talk: a second squeeze or 5 s of silence ends it.
`VoiceIntentParser` sorts the text into one of three kinds:
- a built-in control (pause, resume, meeting or demo mode on/off, forget the last hour), matched only when it is the
  whole utterance;
- a memory question, matched on a leading phrase;
- a tool command, which is everything else.

`VoiceControlRouter` runs controls directly. It sends "forget the last hour" and tool commands to
`CommandSession`: Claude drafts one sentence with no tools, Jarvis speaks it, and the reply window is 15 s. A yes
runs `execute` with only the ticked tools. A no says "Cancelled.". Anything else is a correction and gets a new
draft, and the third correction drops the command. Claude runs are locked down (DEC-9): `--setting-sources ""`,
`--permission-mode dontAsk`, unticked MCP servers on `--disallowedTools`, and a private cwd. `SpeakingTracker` mutes
the wake word while Jarvis speaks, for at most 2 minutes if the speech never reports that it ended.

**Imports.** `InboxImporter` watches the data home's `inbox` for m4a, mp3, wav, caf, aiff, aac and mp4. `ScanScheduler`
runs one scan at a time, waits until a file's size is stable for 2 s, and retries every 5 s up to 12 times.
`ImportCoordinator.importFile` dates the recording (asset metadata, then Spotlight, then file creation date),
decodes it to 30 s chunks labelled "Me" (DEC-18) and runs them through the same pipeline. It deletes the file only
after a successful transcription (DEC-23). Undecodable files move to `inbox/failed/`.
`HourlyNoteScheduler.renote` then rewrites the notes of the finished hours the recording touched (DEC-26).
`VoiceMemosImporter` probes the group container's `Recordings/`, which can be readable, need Full Disk Access, or
be absent. The first time the folder can be read, the memos already there are recorded as the baseline (DEC-19).
Each new memo is copied to `imports/`, imported, and recorded in `index/imported.json`. The originals are only
read.

## 4. Important decisions

`DECISIONS.md` holds DEC-1…DEC-40, with each one's reason and whom it binds. Check it before changing behaviour.
These are the ones a reader is most likely to trip over:

| DEC | What it fixes |
|---|---|
| 2, 38 | Runs on macOS 13+, but building needs Swift 6 (macOS 14.5+). The Homebrew formula requires Sonoma |
| 5 | Engines are optional closures. The transcriber swaps live, the embedder only at launch |
| 7 | Search tiers: Core AI (no model exists, so the slot is dormant), then Apple contextual, then NLEmbedding |
| 9, 32 | Claude runs are locked down. The privacy wording: audio never leaves the Mac, but transcript text and command words go to Anthropic when Claude is the engine |
| 11, 13 | No audio on disk except the CLI temp WAV. Jarvis's own voice is kept out of system audio, not out of the mic |
| 12, 30 | One shared `ForgottenWindows`. Forget deletes exactly the hour it named |
| 14, 22, 27 | Quiet hours stop everything automatic. A ⌥Space hold and a menu Start are deliberate and still work |
| 15, 16, 17 | A control said during a read-back wins. "Resume" with the AirPods gone uses the MacBook mic. A late reply is a new request |
| 19, 23, 26 | Voice Memos backlog is skipped. Imports are deleted only after a successful transcription. Only finished hours are noted again |
| 24, 25 | Chunks are cut at listening boundaries. Quiet hours and lock are checked at launch |
| 28, 31 | Screen Recording is asked for once. A denied mic shows a menu line |
| 33 | The stem squeeze is opt-in |
| 35, 39, 40 | Ad-hoc signing resets permissions after a reinstall. Installs never replace a running Jarvis. Homebrew copies the models on the first `jarvis` run |

## 5. Deviations from the approved blueprint

Each row compares a blueprint section (D-1…D-9 and the per-ticket sections) with what landed. **Source** says where
the reason is written: *S* is the ticket Summary or Review fixes, *N* is the implementer's `notes_for_human`, *R* is
a review finding, *H* is a human decision in `run.json`/`DECISIONS.md`. The rows without a reason are collected at
the end of this section.

### Cross-cutting

| Blueprint | Landed | Why · source |
|---|---|---|
| D-4: every engine injected as a closure | `CapturePipeline` first took a fixed `any Transcriber`, so a model download only took effect at the next launch. It now takes `() -> (any Transcriber)?` and the facade swaps it live. `NoteIndex` still holds a fixed embedder | T-24 F-H3. DEC-5 amended ("A-lite") · R, H |
| D-9 DAG: one added edge (T-21 waits on T-4) | Another edge was added: T-19 waits on T-5 | Missing edge found by the owned-path check before wave 2 · `run.json` dag-correction |
| Platform table: `DECISIONS.md` created by the first review with something to record | Created at `b146150`, after wave 6, with the earlier decisions backfilled from `run.json` | none recorded (see the end of this section) |
| Not planned | Gate repair `1901080`: `Process.terminateAndWait`, because `waitUntilExit` could hang, and a fix for the Voice Memos mid-write race | The wave-6 gate failed · `run.json` gate-6:repair, DEC-10 |
| D-1/D-9.2: one wave-9 file per ticket | The T-26 and T-27 fix passes ran as one agent and landed as one commit (`3a5238b`). The T-27 fix edited `SettingsView.swift` (owned by T-26) and `MenuContent.swift` (owned by T-25) | none recorded (see the end of this section) |
| D-1: the app holds no logic | The T-25/T-26/T-27 fix passes added JarvisCore pieces for rules the app had held: `ListeningSession.chooseTopMenuItem`/`isStopped`, quiet-hours override, `Settings.screenRecordingAsked`/`stemTrigger`/`QuietHours.suggested`, `Jarvis.lastMemoryAnswer`, `NoteStore.file(id:)`, `SpeakingTracker`, `holdKeyUnavailable`, `microphoneAccessOff`, `callAudioNeedsScreenRecording`. `Jarvis.init` gained `permissions:` | Review findings "logic in the UI". DEC-20, 27, 28, 31, 33 · S, R |

### Per ticket

| Ticket | Blueprint said | Landed | Why · source |
|---|---|---|---|
| T-1 | `.gitignore` without models; `Model/Clock.swift` | `models/*.bin` is ignored (the whisper model is 148 MB, over GitHub's 100 MB limit), so the installer downloads the wake model. The protocol is `TimeSource` | S. The rename avoids shadowing `Swift.Clock` (R F-3) |
| T-2 | Purge at `now − days·86400`; strict decode | Calendar-day arithmetic, which is safe across a daylight-saving change. A torn line is skipped. Append adds a missing newline. The day-file search is widened for zone changes | N; R F-1/F-2 |
| T-3 | Strict `Codable` | Per-field defaults. An unreadable file also goes to `.bak`. Equal start and end means never quiet | R F-1…F-4 · S |
| T-4 | Store the raw `text` | The cleaned text is stored. The rule moved to `Pipeline/TranscriptText` | R F-1/F-2 · S |
| T-5 | `quietHours` value; tick spares only `stopped(.user)` | An `isQuietTime` predicate. Quiet hours stop pauses too and restore the earlier state afterwards. A route loss while locked is remembered | H decision:quiet-hours; R F-1…F-4 · S |
| T-6 | `clock:` in init; bare gap lines; prompt read after the guards | No clock. `- ` bullets under `## Gaps`. All prompts seeded on the first tick. In-flight claim. Existence is checked by file, not by parsing | N; R F-1, F-2, F-4, F-5 · S |
| T-7 | Due at `end <= now`; errors thrown | 5-minute grace. Each period fails on its own and failures are reported | R F-1…F-3 · S |
| T-8 | Bare vectors; answer from every hit | `{vector, digest}` plus the embedder name. Hits with cosine ≤ 0 are dropped. Rebuild keeps the index in step with the notes. The default answer prompt still says "name the hour or day", not the note ids the ticket asked for | R F-1…F-5, T-18 F-2 · S. The score filter kept (R F-6 rejected). The prompt change was flagged and never made · N |
| T-9 | Delete the window | The window is first recorded in `ForgottenWindows` (`index/forgotten.json`, kept 8 days). The capture and notes recheck forgotten time line by line. Unreadable note files are matched by name | R F-1…F-5; per-line recheck accepted · N, H |
| T-10 | Hyphenated yes words; fixed drop text | Spoken forms plus dash normalisation. Generation counter. Cancellation is quiet. The drop text follows `maxCorrections` | N; R F-2…F-5 · S |
| T-11 | `parse → VoiceIntent`, lowercase; everything during a read-back goes to `heard` | Returns `VoiceIntent?`, keeps the original casing, and controls must be the whole utterance. A control during a read-back cancels the command and then runs. A late reply is a new request. A resume after the AirPods drop uses the Mac mic | N; DEC-15/16/17 · H, S |
| T-12 | `--allowedTools ""`; draft in plan mode; prompt as positional; one refusal sentence | `--tools ""` + `--strict-mcp-config`, input on stdin, `--no-session-persistence`, `--setting-sources ""` + `dontAsk` for all three calls. A non-zero exit says "Claude Code stopped with an error." Also searches `~/.local/bin` | N; R F-1 blocker, F-7 · S; DEC-9 |
| T-13 | `.cli(binary:)`; temp WAV for both backends; ready when `/` answers | `.cli(binary:model:)`, pidfiles and orphan reaping, ready only when `/health` returns 200, cancellable CLI. The server path posts from memory (T-21 F-1) | N; R F-1…F-6 · S |
| T-14 | Zero vector when the sentence model is missing | Zero only for blank text, otherwise averaged word vectors (300-d against 512-d, kept out of a mixed index by T-8). Ollama "installed" and "available" are separate checks | R F-1; N · S |
| T-15 | `#if canImport(Speech)`; `isUsable` behind the 26+ type | `canImport(Speech) && compiler(>=6.2)` (DEC-4). `LocaleCoverage` is unguarded, and any region of the language counts | R F-1…F-3 · S |
| T-16 | One merge call | `TranscriptChunker.reduce`, up to 3 rounds, then a clear error | R F-1 · N, S |
| T-17 | `load(from:)` sync; `ensureModel` | `load` is async. A model contract was fixed (`input_ids`→`embedding`). No `ensureModel`, because no model source exists. The slot is dormant | N; R F-2; open F-1 · S, DEC-7 |
| T-18 | `speechAnalyzerUsable: Bool`; `whisper(binary:model:)`; contextual awaited | `speechAnalyzerLocale: Locale?`, `whisper: (install, model)`, a new contextual probe that is not awaited (assets fetched in the background), a `NamedEmbedder` name for the Search line, Ollama only when answering. The whisper-cli fallback is kept (R F-4 rejected) | N; H decision:search-engine; R F-1, F-3, F-5 · S |
| T-19 | `ChunkAssembler(clock:)`, callback; route = default input leaving | No clock, returns chunks. `RouteTracker` reports a lost headset whichever notification comes first. Generation guard against stale taps | N; R F-1…F-5 · S |
| T-20 | `AudioError.redundantWithDefaultInput` | Landed as `RoomMicError`, then folded back into `AudioError`. Shared `InputTap`/`CoreAudioProperty`. SCK start timeout cleanup. `onStopped` | N; R F-1…F-3 · S |
| T-21 | `capture(from: Date)`; start at the end of the wake word; hold capped at 15 s | Position in the audio timeline. Capture from the utterance start, with the text up to "jarvis" dropped, because the engine gives no word times. Hold capped at 120 s. Captures always end | N; R F-3…F-6 · S |
| T-22 | `defer remove(url)`, also on partial failure | Keep a file with no stored line. Undecodable files go to `inbox/failed/`. Bounded retry. Report the span stored so far. Later replaced by DEC-23 (delete only after full success, resume within one run) | R F-1, F-6; T-24 F-H2 · S, H |
| T-23 | Import every memo; ledger with size and mtime; confirm the path on this Mac | Baseline (option A, an empty baseline if `Recordings/` is absent). Ledger stores paths only. `.qta` accepted. `start()` is `async throws`. **The real path is still unconfirmed** because no memo has synced yet | H decision:memo-backlog; R F-1…F-6 · S |
| T-24 | Thin facade; drop a chunk that overlaps a pause; `writeNote` per hour touched; router silent while Stopped | Chunks cut at boundaries (DEC-24). Launch checks quiet hours and lock (DEC-25). `renote` owned by the scheduler (DEC-26). Held commands route while Stopped (DEC-22). Live transcriber. `shutdown()`, `modelDownloadProgress`. `engines` became `@Published` | R F-1…F-7, F-H1…H4 · S, H |
| T-25 | `Info.plist + Resources/`; Screen Recording "when not preflighted"; app switches on state | No `Resources/` (nothing needs it). Asked once (DEC-28). Menu lines for mic denied, call audio off and hold key off. `Jarvis.live()` runs before the prompts. The app was never launched by the implementer | R F-2, F-5, F-7, F-8 · S, N |
| T-26 | Panel subscribes on open; app builds note paths | `Jarvis.lastMemoryAnswer` from launch. `noteFile(id:)`. Ticked-but-unlisted tools are shown so they can be unticked | R F-1…F-4 · S |
| T-27 | Bundled sounds; stem always on; play/pause/toggle all mapped | macOS system sounds Glass and Tink, so no `Resources/` or `Package.swift` change during the parallel wave. Stem opt-in, off by default, active only while listening or paused, toggle only (DEC-33) | Orchestrator note in the T-27 dispatch · N; R F-1/F-2 · H |
| T-28 | Copy `models/ggml-base.en.bin` from the repo; `find_tool` on PATH | The model is copied if present, otherwise downloaded (~148 MB), because it is git-ignored. Tools are looked up where the app looks (DEC-37). Swift ≥ 6.0 check, running-Jarvis guard, `--dry-run`, `--purge` confirmation (DEC-36), privacy wording (DEC-32) | N; R F-1…F-7 · S |
| T-29 | `post_install` copies models; `depends_on :ventura`, `"whisper-cpp"`; `brew audit` run | No `post_install` (Homebrew 7 rejects it, and its sandbox cannot write `~`). The `jarvis` launcher copies the models (DEC-40). `:sonoma` (DEC-38). Depends on `"whisper.cpp"`, the canonical name. A wake-model resource was added. `test` also verifies the signature. `--disable-sandbox` moved into `install.sh --bundle-only`. Audit and style not run (Homebrew 7 loads formulae only from a tap) | N; R F-2, F-4, F-5 · S, H |

### Unexplained deviations

Two deviations have no recorded reason:

1. **The T-26 and T-27 fix passes were merged into one.** `dispatch/_wave9-fixers.json` shows one agent keyed
   `T-26+T-27`, and the result is one commit (`3a5238b`). That pass edited `SettingsView.swift` and `MenuContent.swift`,
   which D-9.2 assigned to other tickets. Neither `run.json` nor the tickets say why. It caused no conflict, because
   one agent made every edit, but the two tickets now have no separate history.
2. **`DECISIONS.md` was created late.** The blueprint kept the sync gate "created by the first review that has
   something to record". Human decisions from waves 2–5 (quiet hours, search tier, Claude safety, memo backlog) were
   held only in `run.json` until `b146150` backfilled them.

The T-8 answer prompt is not in this list. Its reason was written down (an ownership limit during the wave), but the
follow-up was never done, so it is listed under section 9.

## 6. Experiment behaviour

Jarvis has no remote experiment flags and no feature-flag service. Three user-facing toggles behave like experiments:

| Toggle | Where | Default | Persisted | Effect |
|---|---|---|---|---|
| AirPods stem squeeze (experimental) | Settings › AirPods | **off** | `settings.json` `stemTrigger` | When on, Jarvis plays silence and shows as Now Playing, but only while listening or paused. A `togglePlayPause` starts press-to-talk. Side effects: it blocks idle sleep, keeps the AirPods on the Mac, takes Now Playing from Music, and the play/pause key or taking an AirPod out can trigger a command (DEC-33). Not yet verified on the stage AirPods |
| Demo mode | menu, or "Jarvis, demo mode on" | off | no, resets at launch | Hourly notes are written for every finished 2-minute slot (id `YYYY-MM-DD-HHmm`). Roll-ups count them |
| Meeting mode | menu, or "Jarvis, meeting mode on" | off | no, resets at launch | Adds the built-in room mic as an "Others" stream, unless the built-in mic is already the default input |

Environment switches exist only for developers and tests. `JARVIS_DISABLE_COREAI=1` forces the search fallback.
`JARVIS_HW_TESTS=1`, `JARVIS_CLAUDE_SMOKE=1` and `JARVIS_OLLAMA_SMOKE=1` turn on the hardware and real-engine smoke
tests.

## 7. Testing performed

**Automated.** The tests use Swift Testing (`swift build` then `swift test` from the repo root), with fake engines,
a fake clock and a temp data-home root. The last gate passed **323 tests in 40 suites**. Every wave gate ran the
whole suite. From the wave-6 repair through wave 9, each wave close ran it twice, and it passed again at the wave-10
close. `SwappabilityTests` drives the full loop with a fake in each of the four protocols. Real engines have smoke
tests that are skipped when the engine is missing (SpeechAnalyzer, Foundation Models, Core AI, contextual
embeddings, whisper). Foundation Models and SpeechAnalyzer passed on this Mac (macOS 27.0.1). Core AI's model test
is always skipped because no model exists.

**Waived (D-1 / DEC-20).** JarvisApp, `install/*.sh` and the formula have no automated loop. They were checked by
`swift build`, `bash -n`, dry runs under a scratch `HOME`, a real `--bundle-only` build (17.5 s incremental), a nested
`sandbox-exec` build, and `ruby -c`. No implementer launched the app.

**Manual hardware checks still pending:**

| Check | Owner ticket |
|---|---|
| Mic capture on the AirPods and on the MacBook mic. The order of the AirPods-loss notifications | T-19, T-24 |
| System audio produces "Others" chunks while a video plays | T-20 |
| Room mic in Meeting mode with the AirPods as the default input | T-20 |
| Wake word and command in one breath ("Jarvis what did …") | T-21, T-27 |
| A real synced Voice Memo: folder path, Full Disk Access line, recording-time date, original untouched | T-23 |
| Stem squeeze on the stage AirPods (which remote command arrives, ear-removal side effect) | T-27 |
| Launch while the screen is locked (undocumented `CGSSessionScreenIsLocked` key) | T-24, DEC-25 |
| Jarvis's own read-back absent from "Others" lines with call audio on | T-27, DEC-13 |
| A build with CLT 16 on macOS 15 (Speech and Foundation Models guards false) | T-1, T-15, T-16 |
| Full `./install.sh` stopwatch on a clean Mac | T-28 |
| `brew install --build-from-source`, `brew test`, `brew audit --strict --new`, `brew style`, `--HEAD`, the upgrade guard, after publishing | T-29 |

## 8. QA coverage

QA cases written: **225** · existing TC ids reused: **0 (unknown, not none: the coverage check was not run)** · acceptance lines left untestable: **3 open of 12**.

The 137 per-ticket cases (T-11, T-24…T-29) were written late, after the DAG had finished, not as each ticket closed.
The 88 spec cases were written at the spec gate.

## 9. Remaining cleanup

| Item | Where it is recorded |
|---|---|
| `VoiceControlRouter` repeats "Listening through the MacBook mic." instead of reusing `ListeningSession.chooseTopMenuItem`'s line | RESUME, T-25 fix N |
| `installSpeech` can start whisper servers after `shutdown()` (no guard, no test) | RESUME, T-25 fix N |
| Stale catch-branch comment in `VoiceMemosImporter` after DEC-23. That path is effectively unreachable | RESUME, T-24 fix N |
| DEC-23: a partly imported file is retried from the start after a relaunch and can duplicate lines | DEC-23 |
| DEC-35: ad-hoc signing resets permissions after a reinstall. A stable signing identity is deferred | DEC-35, T-28 N |
| Pin the Hugging Face model URLs to a commit (`resolve/<sha>/…`). `resolve/main` can change and break the sha256 check | T-29 N |
| Turn on GitHub Pages (default branch, `/docs`) so `guide.html#install` resolves | DEC-29 |
| `prompts/answer.md` default should tell the model to name the note ids it used | T-8 N |
| `ListeningSession.gapMarkers` is unused since the T-6 fix. Delete it or give it a zone | T-6 fix N |
| No logging hook: maintenance, index and importer errors are dropped with `try?` | T-7, T-24, T-27 N |
| Core AI slot has no model (T-17 F-1, open). Undecided: commit the AirPods sample as a test fixture | DECISIONS "Open" |
| `SettingsView` builds its own `SettingsStore(paths: .standard)` instead of asking `Jarvis` | T-26 fix N |
| Run `shellcheck` on the scripts once | T-28 N |
| Update the README stem squeeze line once the hardware result is in | T-27 N |
| LICENSE: **done** (`fb0665a`, DEC-34) | — |

**Before tagging, once, by hand:** run `JARVIS_HW_TESTS=1 swift test` on a Mac with Apple Intelligence, the
mic and Screen Recording allowed, and AirPods connected. The default gate skips the real-device tests (mic, room
mic, call audio, the on-device note model), because the hardware and the model's output vary (J-011). The gate
itself must be 10 full runs green in a row (J-010).

**Outward steps** (they must be done in this order, because the formula no longer patches `install.sh`):
merge this branch to `main` and push. Create and push the tap (`gh repo create yashMangal19/homebrew-tap --public
--source . --remote origin --push`). Tag `v0.1.0` and push the tag. Fill in the two sha256 placeholders in
`Formula/jarvis.rb` (the tarball and `ggml-small.bin`; the `base.en` value is already set and is checked against
`a03779c8…`), then commit and push. Then run the install and audit list in section 7. The exact commands are in
`implement/T-29.fix.json` `notes_for_human`.
