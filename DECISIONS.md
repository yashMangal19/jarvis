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
- **Note 18 Oct (T-29 review):** macOS 13 is the floor for *running* Jarvis. *Building* it needs Swift 6 (Xcode 16 /
  CLT 16), which needs macOS 14.5 or later. Both install paths build from source, so installing needs 14.5+. See DEC-38.

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

### DEC-32 · Privacy wording says exactly what leaves the Mac
- **Decided by:** review (T-28 F-1, blocker)
- **What:** audio never leaves the Mac. When Claude Code writes the notes (the first choice), each hour's
  transcript **text** goes to Anthropic. A voice command's words go to Claude to draft the plan *before* your yes.
  Only the action itself waits for the yes. Apple's on-device model or Ollama keep everything local. The README,
  the Jarvis page and `docs/guide.html` must never say "all on your Mac" or "nothing leaves until yes".
- **Checked against:** DEC-9, DEC-11, DEC-29.

## Listening behaviour

### DEC-14 · Quiet hours always Stop, even over a user pause; afterwards return to the prior state
- **Decided by:** human (decision:quiet-hours), applied in the T-5 fix
- **Affects:** `Session/ListeningSession.swift`.
- **Amended 18 Oct (T-25 review):** "always" means nothing *automatic* overrides quiet hours. You can, on purpose:
  see DEC-27 and DEC-22.

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

### DEC-27 · Clicking "Start listening" during quiet hours overrides them until they end
- **Decided by:** human (T-25 review, F-3, option A)
- **What:** Jarvis stays on until the current quiet window ends. The status reads "Listening (quiet hours paused
  until HH:MM)". The next window applies normally. Enforced in `ListeningSession`, not the app.
- **Checked against:** DEC-14 (amended), DEC-22. Both are deliberate actions. Nothing automatic overrides quiet hours.
- **Detail (T-25 fix):** an unlock during an active override goes back to listening, because the override was your choice.
  Launch, a headset reconnect, and an override left over from a night the Mac slept through never override.

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

### DEC-28 · Screen Recording is asked for once
- **Decided by:** human (T-25 review, F-2, option A)
- **Why:** call audio (spec story 4a) needs ScreenCaptureKit, which macOS files under Screen Recording, even though
  Jarvis uses audio only. macOS shows its own prompt only once.
- **What:** Jarvis explains, then asks, on the first launch only, and remembers the answer in its settings. After a
  "no", the menu shows "Call audio off — Allow Screen Recording…", which opens the right Settings page.
- **Affects:** `Storage/SettingsStore`, `JarvisApp/Permissions.swift`, `JarvisApp/MenuContent.swift`.

### DEC-30 · Forget-last-hour deletes exactly the hour it named
- **Decided by:** review (T-25 F-1)
- **What:** the menu alert and the voice read-back both fix the window when they describe it. Leaving the alert
  open doesn't shift what gets deleted.
- **Checked against:** DEC-12.

### DEC-31 · A denied microphone is shown, never hidden behind a red icon
- **Decided by:** review (T-25 F-7)
- **What:** the menu shows "Microphone access is off" with a button that opens the right Settings page, like the
  Full Disk Access line.

### DEC-42 · The mic retries a failed restart, and the status line says when it isn't recording (2026-10-19) · *Superseded by DEC-49*
- **Why:** QA-8 (J-007) found that after the AirPods dropped and came back, the single restart had found no input
  and given up, while the menu still read "Listening via AirPods Pro" and no transcript was written.
- **Decided by:** Jarvis-Orc (J-007), within DEC-31's rule.
- **What:** `MicSource` retries a failed restart after 0.5, 1, 2 and 4 s, then every 5 s, until the input is back
  or listening stops. While retrying, the status line reads "Reconnecting mic…". After about 12 s it reads
  "Mic not recording: reconnect it or choose another input", and the retries carry on. DEC-31's "Microphone
  access is off" line is not used here, because its Settings button would send the user to the wrong page.
  The icon stays red, as it shows the session's state.
- **Amended (J-008):** Meeting mode's room mic re-pins with the same retries (`RestartRetry`). It still stops for
  good when the built-in mic becomes the default input or is gone. The status line then gets
  " · reconnecting room mic…" or " · room mic not recording" added. The mic's own trouble is shown first.
- **Amended (J-009):** a room mic that stops itself tells Jarvis (`StopsItself.onStopped`), which tries it again
  at once and again at every route change. A missing built-in mic shows " · room mic not recording". A redundant
  one (the built-in mic became the default input, so the mic stream records the room) shows nothing. Outside
  Meeting mode there is no room note.
- **Affects:** `Audio/RestartRetry.swift`, `MicSource.swift` (`AudioTap`, `MicHealth`), `RoomMicSource.swift`,
  `Jarvis.statusLine`/`micHealth`/`roomMicHealth`, `MenuContent`.
- **Checked against:** DEC-31 (kept; a separate case), DEC-24 (each restart still ends the chunk), DEC-25 (none).

### DEC-45 · Errors go to the unified log, never what was said (2026-10-19)
- **Why:** QA-8 found that failures were invisible: about a dozen error paths dropped their errors with `try?` (J-012).
- **Decided by:** Jarvis-Orc (J-012).
- **What:** `Log` (subsystem `dev.yashmangal.jarvis`) logs errors when capture starts, when transcription or storing
  fails, and from the importers, notes, index, settings and maintenance, plus mic and room-mic health changes.
  An error's domain and code are public. Its description is private, because a transcriber's message could
  quote speech. Paths are private. Transcript and command text are never logged. Behaviour is unchanged.
  Pitfall, checked in the log: an `Error` interpolated directly is printed in full even when marked
  `.private`. Its description is always interpolated as `String(describing: error)`.
- **Affects:** `Log.swift`, `Jarvis.swift`, `RestartRetry`, `ImportCoordinator`, `VoiceMemosImporter`, `NoteIndex`.
- **Checked against:** DEC-32 (privacy wording holds: the log stays on the Mac and holds no speech).

### DEC-46 · Meeting mode's cross-mic duplicates ship as a known limit in 0.1.0 (2026-10-19)
- **Why:** QA-11 and QA-10 found that the bleed goes both ways. The wearer reaches the room mic (an Others copy),
  and a nearby phone reaches the AirPods (a Me copy). Keeping the copy from the true source needs per-utterance
  timing and levels. Jarvis doesn't capture them: a line is a whole 30 s chunk, transcribers return text only,
  chunk audio is dropped after transcription, and Bluetooth latency hides which mic heard it first.
- **Decided by:** Jarvis-Orc (J-015). A text-similarity "drop the Others copy" rule was built and rejected,
  because for a podcast it would keep the wrong copy, which is worse than the duplicate.
- **What:** both copies are stored. README Known limits and the guide say so. Real attribution (an utterance
  split before transcription, in-memory cross-correlation of the two mics, and level ratios against a per-device
  baseline; 2–4 days plus paired recordings) is a post-0.1.0 backlog item.
- **Checked against:** DEC-18 (labels still come from the source), DEC-32 (privacy unchanged: no audio kept).

### DEC-47 · Voice commands get a readable record in the data home; the unified log gets names only (2026-10-19)
- **Why:** QA-27 couldn't be diagnosed. The user wants the command record readable, which `<private>` in the
  unified log is not (J-016 amendment).
- **Decided by:** the user, through Jarvis-Orc (J-016).
- **What:** `logs/commands.jsonl` gets one line per command when it ends. Each line has: time, trigger (wake word,
  hold or reply window), mic, what was heard, intent, action, what Jarvis said (read-back and result), the replies,
  and the outcome (done, cancelled or failed, with the reason). It is kept like transcripts: data home only, 7-day
  expiry in maintenance, removed by "Forget the last hour", and deleted by `uninstall.sh --purge` with the rest of
  the data home. The unified log's `command` category holds names only (trigger, intent, action, outcome and
  duration) and never content, so DEC-45 holds.
  The record of a "Forget the last hour" command is written after the forget, so that record itself stays.
- **QA-27 finding:** the wake word listens on the active mic only (`WakeWordListener` reads `MicSource` frames),
  so the room mic can't start a second command, and no cross-source debounce is needed. The Others/Me pair was
  the transcript duplicate (DEC-46). A control matches only as the whole utterance, so a near miss ("meeting mode
  of") becomes a tool command with a read-back. The record now shows which happened.
- **Affects:** `Storage/CommandLog.swift`, `JarvisPaths.logs/commandLog`, `VoiceControlRouter`, `ForgetLastHour`,
  `LaunchMaintenance`, `Log.command`, README.
- **Checked against:** DEC-32 and DEC-45 (still on this Mac only; no speech in the unified log), DEC-41 (data home).

### DEC-49 · One capture supervisor owns every source's lifecycle and health (2026-10-19)
- **Why:** D12 review (J-018). J-007/8/9 fixed the mic and the room mic one at a time, each with its own retry and
  its own report channel (`onHealth`, `onStopped`). System audio was missed: on a stream error it stopped silently,
  and calls went uncaptured while the menu said listening.
- **Decided by:** Jarvis-Orc (J-020).
- **What:** `CaptureSupervisor` owns the mic, call audio and the room mic through one `CaptureDriver` each.
  - The driver knows whether its source is wanted. It starts it, and restarts it when the source stops by itself
    or fails to start: immediately on a route event, otherwise with `RestartRetry`'s backoff.
  - The driver is the only source of `SourceHealth` (ok, reconnecting, unavailable).
  - A source does device work only. Its single required report is `onStopped(.redundant | .failed)`, so a new
    source can't leave health out.
  - Redundant and a refused permission are not faults: they are neither retried nor shown (a permission has its
    own menu line).
  - The status line shows the mic's trouble first, then " · call audio not recording" and, in Meeting mode,
    " · room mic not recording".
- **Supersedes:** DEC-42 and its J-008/J-009 amendments.
- **Checked against:** DEC-16 (a route change still re-checks the room mic), DEC-24 (each restart still ends the
  chunk), DEC-28 and DEC-31 (permission lines unchanged), DEC-45 (health changes are logged by name only).

### DEC-50 · A near miss of a control is asked about, never sent to Claude (2026-10-19) · *Superseded in part by DEC-54*
- **Why:** D12 review (J-018) of QA-27. A control matched only as the exact whole utterance, so any mishearing
  ("meeting mode of") silently became a Claude tool command with a read-back.
- **Decided by:** Jarvis-Orc (the behaviour), J-021 (the matching).
- **What:** `VoiceIntentParser`, the one owner of what an utterance means, returns `.didYouMean(candidates)` for an
  utterance close to a control. Close means one of:
  - within a small edit distance: none under 7 characters, so "pass" is never "pause"; 1 under 12; then 2;
  - a control of two or more words plus one extra word ("turn meeting mode off").

  A one-word control with more words stays a tool command ("pause the music"). Of equally close controls, the
  router asks about the one that would change something (with Meeting mode on, "meeting mode of" means off).
  The question is a read-back in the confirmation loop: yes runs the control, anything else cancels. A near miss
  of "forget the last hour" goes straight to its own read-back, which already asks. A near miss never reaches a
  command runner.
- **Checked against:** DEC-15 (a control during a read-back still cancels it), DEC-47 (recorded as
  `didYouMean(<control>)`).

### DEC-51 · Every wait in production runs on an injected Scheduler (2026-10-19)
- **Why:** D12 review (J-018) of J-010. Production code waited on wall-clock time (`Task.sleep`/`asyncAfter`/`Date()`
  deadlines), so timing tests could only use small real delays and bounds. They failed under load, and some needed
  internal hooks.
- **Decided by:** Jarvis-Orc (J-022).
- **What:** `Scheduler` (`now`, `sleep(for:)`, `after(_:on:_:)`), with `SystemScheduler` in production and a virtual
  scheduler in tests that moves only when advanced. It is used by:
  - capture restarts (`RestartRetry` via `CaptureDriver`);
  - import retries and settle looks (`ScanScheduler`, `ImportCoordinator`, both importers, including the J-011 gap);
  - the folder-watcher debounce;
  - the `ChildProcess` timeout ("timed out" now means the timeout fired, not a later clock read);
  - whisper readiness and orphan reap;
  - the Jarvis tick.

  Timing tests advance virtual time, so they test when things happen, not how fast the machine is. A blocking source
  start is tested by order (a start held open), not by a time bound. `CommandCapture` already took its sleep as a
  parameter.
- **Checked against:** DEC-10 (bounded child waits unchanged), DEC-43 and DEC-48 (gap semantics unchanged; its clock
  is now the scheduler's).

### DEC-54 · One CommandInterpreter decides what was meant; nothing reaches Claude by default (2026-10-19)
- **Why:** QA-22 failed on RC1. "Jarvis, pause" was heard as "boss." and, being a short word that J-021 never
  guessed, went to Claude; "pause, Jarvis, resume." also went to Claude. Three owners decided meaning and each
  failure fell through to a tool command.
- **Decided by:** Jarvis-Orc (J-027), on the J-027 design note, with these calls:
  - (i) a tool command needs two words or more;
  - (ii) barge-in only for controls, yes/no and stop/cancel;
  - (iii) hardware echo cancellation is deferred to after 0.1.0.
- **What:** `CommandInterpreter` (it replaces `VoiceIntentParser`) is the one owner of what an utterance means.
  - Controls match by words or by sound. The sound key is a consonant skeleton with voiced and unvoiced letters
    merged, so "boss" is "pause". Short words too: a sound-alike is asked about ("Did you mean pause?"),
    reversing DEC-50's "short words are never guessed".
  - The utterance splits at "Jarvis", sentence punctuation and "and"/"then". Controls said one after another run
    in that order ("pause, Jarvis, resume"). A "forget the last hour" among them comes last, with its own
    read-back.
  - Controls mixed with other words, or near misses, are asked about in one question.
  - "stop" and "cancel" are a control: they cancel a waiting read-back, and stop Jarvis talking (DEC-55).
  - A tool command needs two words or more, with no segment that is, or sounds like, a control. One unknown word
    gets "Sorry, I didn't catch that."
  - During a read-back, yes/no answer it; a control or near-control cancels it; anything else is a correction.
- **Checked against:** DEC-15 (a control during a read-back still cancels it), DEC-47 (records name the outcome:
  `controls(…)`, `didYouMean(…)`, `unclear`), DEC-50 (superseded in part).

### DEC-33 · The AirPods stem squeeze is opt-in
- **Decided by:** human (T-27 review, option A)
- **Why:** to hear a squeeze, Jarvis must play silence to stay "Now Playing". All the time, that blocks idle sleep,
  keeps the AirPods attached to the Mac and takes Now Playing from Music. Taking an AirPod out, a Bluetooth drop and
  the keyboard play/pause key also look like squeezes.
- **What:** a Settings toggle "AirPods stem squeeze (experimental)", off by default. When it's on, the silence plays
  only while Jarvis is listening or paused, never when Stopped, in quiet hours or with the screen locked. The side effects are listed in the README.
- **Checked against:** DEC-14, DEC-22 (⌥Space hold is unaffected).

## Storage

### DEC-41 · The data home is `~/Library/Application Support/Jarvis`, not `~/Jarvis` (2026-10-19)
- **Why:** on a case-insensitive disk (the macOS default) `~/Jarvis` is the same folder as a `~/jarvis` clone.
  QA found room-speech transcripts, `settings.json`, `index/` and `prompts/` in the repo's working tree
  (J-005, QA-85). Nothing was committed. `~/Documents/Jarvis` was rejected: with iCloud "Desktop & Documents"
  on, transcripts would leave the Mac (DEC-32).
- **Decided by:** human (J-005, option A).
- **What:** the first launch brings the old `~/Jarvis` files across once. They are moved, but copied when
  `~/Jarvis` is a git repository, and the originals are left for the user to delete. An item the new home
  already has, such as a model the installer put there, is never replaced. Jarvis refuses to start when its
  data home is inside a git repository. The check stops below the home folder, so a dotfiles `~/.git`
  does not count. `.gitignore` also lists Jarvis's folders, as a second guard. **Open notes** in the menu
  replaces "look in your home folder". Supersedes the spec's `~/Jarvis/` storage line.
- **Affects:** `Storage/JarvisPaths.swift` (`standard`, `legacyRoot`, `adoptLegacyData(from:)`, the
  `ensureLayout` guard), `Jarvis.live()`, `install/install.sh`, `install/uninstall.sh`, README, guide,
  the Homebrew `jarvis` launcher (DEC-40), and `.gitignore`.
- **Checked against:** DEC-19 and DEC-40 (paths updated, decisions unchanged); DEC-32 (strengthened: the
  folder is not iCloud-synced); DEC-36 (`--purge` now deletes the new folder, with the same confirmation).
  The legacy `~/Jarvis` is never deleted.

## Imports

### DEC-43 · A still-syncing memo is given up only on a look at least `retryDelay` after the first (2026-10-19) · *Superseded in part by DEC-48*
- **Why:** J-010 found that at startup the first scan and a folder change can run back to back. A memo seen unchanged
  and undecodable twice, a moment apart, was dropped for good, which is data loss.
- **Decided by:** Jarvis-Orc (J-011).
- **What:** the first sighting is recorded with its time. A later sighting of the same unchanged file gives up only
  when at least `retryDelay` (5 s) has passed; a sooner one keeps it for the retry.
- **Affects:** `Import/VoiceMemosImporter.swift`.
- **Checked against:** DEC-19 (unchanged), DEC-23 (unchanged: audio is still deleted only after a successful
  transcription). The import gate repair's "unchanged and still broken" rule is kept, with the time gap added.

### DEC-48 · "Undecodable" is a verdict on one version of a memo, never on its path (2026-10-19)
- **Why:** D12 review (J-018) of J-011. The ledger was keyed by path only, so a memo given up on mid-sync was lost
  for good. A quiet-gap rule only moved the threshold (a writer stalled more than 5 s still lost the memo).
- **Decided by:** Jarvis-Orc (J-019).
- **What:** `index/imported.json` keeps imported and baseline memos by path, for good (DEC-19: never re-import a
  trimmed memo). An undecodable memo is recorded with its size and modification date, and any later version is a
  candidate again at the next scan or launch, so no stall can lose it. `FileStamp` reads from disk, never from a
  URL's cached values. Older ledgers read as before.
- **Supersedes in part:** DEC-43. Its gap now only decides how long a still-changing memo keeps being retried
  (promptness); it no longer protects the data.
- **Not covered here:** a recording partly transcribed when Jarvis quits restarted from the beginning. Closed by
  DEC-52.
- **Checked against:** DEC-19, DEC-23 (audio still deleted only after a full transcription), DEC-43.

### DEC-52 · Where each import got to is kept on disk, by file version (2026-10-19)
- **Why:** J-018/J-019 follow-up (J-023). Two in-memory records were lost on a relaunch, so lines were stored twice:
  how many chunks of a file were stored, and "all stored, only the delete failed".
- **Decided by:** Jarvis-Orc (J-023).
- **What:** `ImportProgress` (`index/import-progress.json`) holds, per file version (path, size, modification date),
  the chunks stored and whether all are. It is updated after every stored chunk, and cleared when the file is
  deleted. A relaunch carries on after the stored chunks, and a file whose delete failed is never imported again.
  A different recording under the same name starts afresh. Entries for vanished files are dropped on load.
  Residual: a crash between a chunk's line and the progress write can repeat that one chunk.
- **Supersedes:** the in-memory `resumeAt` and `undeleted` sets in `ImportCoordinator`, and README's "retried from
  the start" known limit.
- **Checked against:** DEC-23 (audio still deleted only after a full transcription), DEC-48 (the ledger stays the
  Voice Memos verdict; progress is per file, for both importers), DEC-41 (in the data home, removed by `--purge`).

### DEC-53 · Every model download is pinned to one revision and checked against its sha256, failing closed (2026-10-19)
- **Why:** release blocker (J-026). Models came from `resolve/main`, which can change under the same name, and the
  app's downloader and the installer checked nothing, so a changed or corrupted file would have been used.
- **Decided by:** Jarvis-Orc (J-026).
- **What:** `install/whisper-models.txt` is the one list: a pinned revision of `ggerganov/whisper.cpp` and each
  model's sha256. Every path that fetches a model uses it:
  - the installer: pinned URL; it also checks a model copied from the repo or already in place;
  - the app's `WhisperModelDownloader`: only pinned models, verified before the `.part` becomes the model;
  - `release-formula.sh`: writes both formula resources' URLs and checksums, so Homebrew verifies them, and the
    `jarvis` launcher copies files Homebrew has already verified.

  A mismatch is removed and never used: the installer stops, and the app reports `checksumMismatch` and stays
  without that model. `WhisperModels.swift` holds the same values, and a test fails if the two drift. A model
  already in the app's models folder is trusted, because every path that puts one there has verified it.
- **Checked against:** DEC-5 (live transcriber swap unchanged), DEC-40 (launcher copy unchanged), DEC-45 (the
  mismatch is logged by kind).

### DEC-44 · Real-device and on-device-model tests are opt-in; run once by hand before a tag (2026-10-19)
- **Decided by:** Jarvis-Orc (J-011, from J-010).
- **What:** `FoundationModelsNoteWriterTests` joins the mic, room-mic and call-audio smoke tests behind
  `JARVIS_HW_TESTS=1`. The release checklist (feature doc §9) runs them once before tagging.
- **Checked against:** DEC-20 (manual QA still covers the UI).

### DEC-18 · Imported recordings are labelled "Me" (blueprint D-7)
- **Why:** a Voice Memo or inbox file comes from the user's own recorder. To reverse it, change one line in `AudioSource.label`.

### DEC-19 · Voice Memos backlog: only new memos are imported (option A)
- **Decided by:** human (decision:memo-backlog)
- **What:** on first access, the memos already there become the baseline and are skipped. If `Recordings/`
  is missing, the baseline is empty. To bring in old memos, drop them in the data home's `inbox` (DEC-41).
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

### DEC-34 · Jarvis is MIT-licensed
- **Decided by:** human (wave-9 review). `LICENSE` at the repo root, © 2026 Yash Mangal.

### DEC-35 · Ad-hoc signing: permission resets after a reinstall are a known v1 limit
- **Decided by:** human (T-28 review, option A)
- **What:** the installer signs Jarvis locally without a developer certificate. macOS may treat each reinstall as a
  new app: it asks for the mic again, and Screen Recording or Full Disk Access can switch off silently. You turn
  them back on from Jarvis's menu lines. The README explains this. A stable signing identity is deferred.
- **Checked against:** DEC-28 (asked once, so the menu line is the way back), DEC-31.

### DEC-38 · The Homebrew formula requires macOS Sonoma
- **Decided by:** human (T-29 review, option A)
- **Why:** every Homebrew install builds from source, and Swift 6 needs macOS 14.5+. On Ventura the install would
  download about 620 MB and then fail.
- **Checked against:** DEC-2 (note added: runs on 13+, builds on 14.5+).

### DEC-39 · Installs never replace a running Jarvis, including on `brew upgrade`
- **Decided by:** human (T-29 review, option A)
- **What:** the installer refuses when Jarvis is running from any Homebrew version folder, not only the one being
  built. The caveat "Quit Jarvis before brew upgrade" stays as well.

### DEC-40 · Homebrew installs copy the models on the first `jarvis` run
- **Decided by:** review (T-29), forced by Homebrew 7 (no `post_install`, and its sandbox can't write to your home folder)
- **What:** the `jarvis` command copies any missing model into the data home's `models` (DEC-41; never over an existing file),
  then opens the app. The caveats say to open it with `jarvis` the first time.

### DEC-36 · `uninstall.sh --purge` never deletes without a typed confirmation
- **Decided by:** review (T-28 F-2)
- **What:** when not run from a terminal, it refuses unless `--yes` is also passed.

### DEC-37 · The installer looks for tools where the app looks
- **Decided by:** review (T-28 F-3)
- **What:** it checks the fixed folders the app searches (an app opened from Finder gets no shell PATH), and warns
  when a tool is found only through Terminal's PATH.

### DEC-29 · The setup guide is published from `docs/guide.html`
- **Decided by:** human (T-25 review, F-9, option A)
- **What:** the "Notes off — install…" link opens `yashmangal19.github.io/jarvis/guide.html#install`. The guide
  is the same page as the Jarvis artifact page, and the two are kept in sync. After the merge, the human turns on
  GitHub Pages; that step is outward, so it's the human's to do.


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
| F-CLAIM-1 on T-3, T-4, T-7, T-11, T-22, T-23, T-24, T-25 | "new vs reusing" disagreements where the reused piece was trivial or already fixed by another finding |

## Open

- **T-17 F-1:** there is no Core AI model to ship. The slot stays dormant (DEC-7).
- **Fixture question:** should the AirPods sample recording be committed as a test fixture? Not decided yet.
