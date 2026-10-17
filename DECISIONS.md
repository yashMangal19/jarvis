# Decisions — Jarvis ambient memory

The decision record for this repo. Every decision taken while building the feature is here, with why
and where it lives. **Before taking a new decision, check it against this list.** If it changes or
contradicts an entry, say which one, and either update that entry (marking it *Superseded by …*) or
choose differently. Never silently override an entry.

Status: **Active** unless marked. Dates are 2026-10-17 unless stated.

## How to add one

```
### DEC-n · <one-line decision>
- **Why:** the reason, in one or two lines
- **Decided by:** human | blueprint | review (ticket, finding)
- **Affects:** files or tickets it binds
- **Checked against:** DEC-x, DEC-y (or "none affected")
```

---

## Platform and build

### DEC-1 · Swift/macOS practice replaces the kit's Android rules
- **Why:** the build-feature kit targets Kotlin/Android; its rules don't fit a SwiftPM app.
- **Decided by:** human
- **Affects:** every ticket. Gate = `swift build` then `swift test` from the repo root. No Kotlin idiom
  or negatives scripts. Docs come from developer.apple.com, swift.org and github.com/swiftlang.

### DEC-2 · Swift tools 6.0, language mode 5, macOS 13 floor (blueprint D-2)
- **Why:** Command Line Tools 16 on macOS 15 must build it. Strict concurrency adds cost and gives users nothing.
- **Affects:** `Package.swift`. Moving to mode 6 later is a mechanical sweep.

### DEC-3 · Observation uses Combine `ObservableObject`, never `@Observable` (blueprint D-3)
- **Why:** `@Observable` needs macOS 14; the floor is 13.
- **Affects:** all of JarvisCore; the app binds with `@ObservedObject`/`@StateObject`.

### DEC-4 · Speech framework guard is `canImport(Speech) && compiler(>=6.2)`
- **Decided by:** review (T-15)
- **Affects:** `Engines/Apple/SpeechAnalyzerTranscriber.swift`. Keeps the CLT 16 build working.

## Engines

### DEC-5 · Engines are injected as `() -> (any Protocol)?` closures; `nil` means off (blueprint D-4)
- **Why:** engines change after launch ("none" state, runtime fallback).
- **Affects:** every component. The swappability test (T-24) keeps this true.
- **Amended 17 Oct (T-24 review, human: A-lite):** the **transcriber** swaps live. When whisper's model
  finishes downloading, transcription starts without a relaunch. The **search embedder** stays fixed per
  launch, because nothing can change it while running today (Core AI is dormant). Note writer and command
  runner already swap live.
- **Checked against:** DEC-7 (search tiers unchanged), DEC-8 (index keyed by embedder, so a switch at launch rebuilds it).

### DEC-6 · whisper.cpp runs as a long-lived `whisper-server`; `whisper-cli` is the fallback (blueprint D-5)
- **Why:** the wake word transcribes every ~1 s. Respawning reloads the model every time.
- **Affects:** `Engines/Whisper/`. Two instances (main and wake-word). Pidfiles come from
  `WhisperServerProcess.pidFile(role:)` and T-18/T-24 must pass them.

### DEC-7 · Search tiers: Core AI → NLContextualEmbedding → NLEmbedding
- **Decided by:** human (decision:search-engine)
- **Why:** there is no Core AI model yet (dormant slot). NLContextualEmbedding needs no model file on macOS 14+.
- **Affects:** T-18 engine selection, `Engines/Apple/`. Open item: T-17 F-1, the Core AI slot has no model.

### DEC-8 · Search index is one JSON file, rewritten atomically, keyed by embedder (blueprint D-6, T-8 fix)
- **Why:** a year of notes is about 6 MB, so a database isn't justified. Vectors from different embedders must not mix.
- **Affects:** `NoteIndex(paths:embedder:embedderID:)`. T-24 passes the search name from the Engines line.

### DEC-9 · Claude Code runs are pinned down
- **Decided by:** review (T-12 blocker) + human (decision:claude-safety, "accept as is")
- **What:** `--setting-sources ""`, `--permission-mode dontAsk`, MCP servers not ticked in Settings go on
  `--disallowedTools`, cwd is `$TMPDIR/jarvis-claude`, and SIGPIPE is guarded.
- **Known limits (must go in README and MR):** admin-managed policy still applies. Servers missing from
  `claude mcp list` are refused only by dontAsk. Auth through settings.json is unsupported. Listing MCP
  servers adds latency to each command.
- **Affects:** `Engines/Claude/`, `Process/ChildProcess.swift`.

### DEC-10 · Child-process waits are always bounded
- **Decided by:** gate-6 repair (commit 1901080)
- **Why:** `waitUntilExit` can miss the child's exit and hang forever.
- **What:** `Process.terminateAndWait(grace:)`: SIGTERM, poll, then SIGKILL to the process group.

## Privacy

### DEC-11 · No raw audio is written to disk
- **Decided by:** review (T-21 fix)
- **What:** the whisper-server path posts audio from memory. The CLI fallback writes a short-lived temp WAV,
  which is the documented exception.

### DEC-12 · "Forget last hour" uses one shared `ForgottenWindows`
- **Decided by:** review (T-9 fix)
- **Affects:** T-24 must pass the same instance to `CapturePipeline`, `HourlyNoteScheduler` and `ForgetLastHour`.

### DEC-13 · Jarvis's own speech is kept out of system-audio capture, not out of the mic (blueprint D-8)
- **Accepted residual:** a read-back sentence may show up in a transcript. The wake-word input is muted while speaking (T-27).

## Listening behaviour

### DEC-14 · Quiet hours always Stop, even over a user pause; afterwards return to the prior state
- **Decided by:** human (decision:quiet-hours), applied in the T-5 fix
- **Affects:** `Session/ListeningSession.swift`.

### DEC-15 · A built-in control said during a pending read-back wins
- **Decided by:** human (T-11 F-2, option A)
- **What:** if you say e.g. "Jarvis, pause listening" while Jarvis waits for your yes, Jarvis says
  "Cancelled.", drops the pending command, then runs the control. Anything else is still a correction.
- **Affects:** `Commands/VoiceControlRouter.swift`.

### DEC-16 · "Jarvis, resume" with the headset disconnected resumes on the MacBook mic
- **Decided by:** human (T-11 F-6, option A)
- **What:** Jarvis says "Listening through the MacBook mic." and moves back to the headset when it reconnects.
- **Affects:** `Commands/VoiceControlRouter.swift`. Capture must follow the active input device (checked at T-24 and on hardware).
- **Checked against:** DEC-14. Quiet hours still win, because resume doesn't override a quiet-hours stop.

### DEC-17 · A read-back left unanswered times out on the next utterance, silently
- **Decided by:** review (T-11 F-1)
- **What:** the next thing said is handled as a new request, not dropped.

### DEC-22 · Holding ⌥Space works while Stopped
- **Decided by:** spec story 8a ("⌥Space also starts a command"), confirmed in the T-24 review
- **What:** the mic runs only for the hold, nothing is stored, and the command routes as usual. A
  deliberate hold also works during quiet hours.
- **Affects:** `Commands/VoiceControlRouter.swift`, `Jarvis.swift`.
- **Checked against:** DEC-14. Quiet hours stop *listening*, and a hold is a deliberate command, not listening.

### DEC-24 · Audio chunks are cut at every listening boundary
- **Decided by:** human (T-24 review, option A)
- **What:** on pause, resume, stop, start, quiet hours or screen lock, the mic and call-audio streams end
  their current chunk at that moment. Every chunk falls wholly inside or wholly outside listening, so nothing
  paused is saved and no real speech is lost.
- **Affects:** `Audio/MicSource.swift`, `Audio/SystemAudioSource.swift`, `Jarvis.swift`.
- **Checked against:** DEC-11, DEC-14, DEC-16. Same privacy rules, without the 30 s loss.

### DEC-25 · Jarvis checks quiet hours and the lock screen the moment it starts
- **Decided by:** review (T-24 F-2)
- **What:** no 30 s window of listening at launch. The lock check reads the session's `CGSSessionScreenIsLocked` key, which Apple doesn't
  document. **Hardware check pending:** launch while the screen is locked. If the key is missing, the lock is caught at the next lock event.
- **Checked against:** DEC-14.

## Imports

### DEC-18 · Imported recordings are labelled "Me" (blueprint D-7)
- **Why:** a Voice Memo or inbox file comes from the user's own recorder. To reverse it, change one line in `AudioSource.label`.

### DEC-19 · Voice Memos backlog: only new memos are imported (option A)
- **Decided by:** human (decision:memo-backlog)
- **What:** on first access, the memos already there become the baseline and are skipped. If `Recordings/`
  is missing, the baseline is empty. To bring in old memos, drop them in `~/Jarvis/inbox`.
- **Affects:** `Import/VoiceMemosImporter.swift` (`start()` is async throws).

### DEC-23 · An imported recording is deleted only after a successful transcription
- **Decided by:** review (T-24 implementer finding on T-22)
- **What:** if transcription fails, or no transcriber is available, the file stays and is retried. An empty
  result from a silent recording counts as success.
- **Affects:** `Import/ImportCoordinator.swift`.
- **Known limit:** a retry resumes after the chunks already stored, but only within one run. After a relaunch, a
  partly imported file is retried from the start and can duplicate lines.

### DEC-26 · An import re-notes only finished hours
- **Decided by:** review (T-24 F-1)
- **What:** a recording from the current hour doesn't write that hour's note early. The hourly scheduler
  owns the rule, using its own calendar and in-flight claim.
- **Affects:** `Notes/HourlyNoteScheduler.swift`.

## Process and scope

### DEC-20 · UI, installer and Homebrew formula ship without automated tests (blueprint D-1)
- **Decided by:** human ("proceed untested, acknowledged")
- **Affects:** T-25…T-29. All of their logic lives in JarvisCore, which is tested. They are covered by manual QA.

### DEC-21 · DAG corrections (blueprint D-9 and later)
- T-21 waits on T-4. T-19 waits on T-5. In wave 9, T-25 is the only ticket that edits `JarvisApp.swift`.

---

## Rejected review findings (kept so they aren't raised again)

| Ticket · finding | Why rejected |
|---|---|
| T-5 F-6, T-6 F-3, T-8 F-6, T-18 F-4 | rejected in the wave-2…4 reviews, each with its reason in the run's review file |
| F-CLAIM-1 on T-3, T-4, T-7, T-11, T-22, T-23, T-24 | "new vs reusing" disagreements where the reused piece was trivial or already fixed by another finding |

## Open

- **T-17 F-1:** there is no Core AI model to ship. The slot stays dormant (DEC-7).
- **Fixture question:** should the AirPods sample recording be committed as a test fixture? Not decided yet.
