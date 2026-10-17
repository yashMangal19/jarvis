# Jarvis for Mac

A clone for the part of you that forgets.

Jarvis is a small menu-bar app that **listens**, **remembers** and **acts**, so you don't have to hold everything in your head. And it always asks before doing anything that leaves your Mac.

From the Swift Mumbai talk **"What If You Could Clone Yourself?"** (17 Oct 2026). MIT licensed: fork it, change it, make it yours.

> **Status: building in the open.** v1 is in progress on the [`feature/jarvis-ambient-memory`](../../tree/feature/jarvis-ambient-memory) branch and merges into `main` when it's done. Anything marked *(after v1)* is decided but not shipped yet. Star or watch the repo to follow along.

## How it works

Five steps, all on your Mac.

| | Step | What happens |
|---|---|---|
| 01 | **Listen** | Records you, your calls and, if you want, the room. |
| 02 | **Transcribe** | Turns speech into text on your Mac, then deletes the audio. |
| 03 | **Write notes** | Every hour, a short note of what was said. |
| 04 | **Remember** | Notes roll up into days and weeks, and you can search all of them. |
| 05 | **Act** | Say "Jarvis, …". It reads back its plan and acts after your yes. |

## Features

Every feature works on **any Mac** (macOS 13+). Newer macOS uses Apple's newest frameworks automatically.

### Always listening, when you want it
Start and stop from the menu bar. The icon is red while recording.

<details><summary>How it's built</summary>

- `AVAudioEngine` records the active mic in 30-second chunks.
- A chunk that stays below a loudness threshold is silence. It is dropped and adds no transcript line.
</details>

### Whole meetings, not just you
Online calls: the call audio is recorded too. In person: turn on **Meeting mode** to record the room. Lines are labelled **Me** or **Others**.

<details><summary>How it's built</summary>

- We tested it: AirPods Pro caught the wearer clearly but heard a nearby podcast as "[INAUDIBLE]". The MacBook mic transcribed the same podcast almost word for word.
- So the AirPods record you, `ScreenCaptureKit` records call audio (audio only; needs the Screen Recording permission), and Meeting mode adds the built-in mic for the room.
- Each source is its own stream, and the source decides the label.
</details>

### Private transcription
Speech becomes text on your Mac. Audio is never uploaded or kept. Hindi and Hinglish work too.

<details><summary>How it's built</summary>

- whisper.cpp with a multilingual model that detects the language.
- On macOS 26+, Apple's `SpeechAnalyzer` is used for the languages it supports, so there's nothing to download.
- **Settings → Engines** shows which engine is in use.
</details>

### Hourly notes
Each hour with speech becomes a short Markdown note: topics, decisions, to-dos, people. Turn on **Demo mode** to get a note every 2 minutes.

<details><summary>How it's built</summary>

- The first available writer is used: Claude Code (`claude -p`), then Apple `FoundationModels` on-device (macOS 26+), then a local Ollama model (optional, about 2 GB).
- With none available, the menu says "Notes off — install Claude Code or Ollama", and transcripts and search keep working.
- Edit `prompts/hourly.md` to change how notes read.
</details>

### Memory that stays small
Hourly notes become a daily note. Daily notes become a weekly note. Raw transcripts are deleted after 7 days; notes stay.

### Ask your memory
"What did we decide about the launch on Tuesday?" Jarvis answers and names the notes it used.

<details><summary>How it's built</summary>

- Every note is turned into a vector with Apple's built-in `NLEmbedding` and searched by similarity.
- On macOS 27, a `Core AI` slot is ready for a stronger embedding model; if it can't load, Jarvis falls back to NaturalLanguage.
</details>

### Voice commands
"Jarvis, tell the team I'm 10 minutes late." It uses the tools you've connected to Claude Code: chat, calendar, GitHub and more.

<details><summary>How it's built</summary>

- Three ways to start: say **"Jarvis, …"**, hold **⌥Space** and speak, or squeeze an **AirPods stem** (experimental).
- Say it in one breath. Jarvis keeps the last few seconds in memory (never on disk), so it catches what you say right after the wake word. A soft chime tells you it heard you.
</details>

### Control it by voice
"Jarvis, pause." "Jarvis, resume." Also: meeting mode on/off, demo mode on/off, forget the last hour, and "what did …?". These run without Claude, so they're instant.

### It asks before it acts
Nothing leaves your Mac until you've heard it and said yes.

<details><summary>How it's built</summary>

- Every command runs in two phases: a read-only draft, then execution.
- The read-back says exactly what will happen, to whom, and with what content.
- **Yes** runs it. **No**, or 15 seconds of silence, drops it. Anything else is a correction ("no, send it to Prashant instead"): Jarvis redrafts and reads it back. After 3 corrections without a yes, it gives up and tells you.
- Only the tools you tick in Settings can run. Shell commands and file edits are off by default.
</details>

### Away from your Mac
Record on your phone. Jarvis adds the recording to your memory when the Mac wakes.

- **iPhone:** Voice Memos sync over iCloud and are imported automatically (needs Full Disk Access).
- **Android:** save recordings into a synced folder that points at `~/Jarvis/inbox`.

## Privacy

- The icon is red while recording.
- **Pause** (click, or "Jarvis, pause"): nothing is recorded, but "Jarvis, …" still works. The icon goes grey with a dot.
- **Stop** turns everything off, wake word included. The icon goes plain grey.
- It stops on its own when your screen locks and during quiet hours you set.
- Audio is never stored and never uploaded. Only text goes to the model you choose.
- **Forget last hour** deletes that hour's notes and their search entries.

Tell people when you're recording them. Consent and local laws apply to you.

## Requirements

| | |
|---|---|
| **Mac** | macOS 13 or later. macOS 27 on Apple silicon for the newest features. |
| **Tools** | Homebrew and the Xcode Command Line Tools. Xcode 27 for the newest features. |
| **AI** | Claude Code with a Claude plan. Without it, Apple's on-device model (macOS 26+) or Ollama writes notes. |
| **Mic** | Built-in mic or any earbuds. AirPods are best for your own voice. |

## Install

### Today: build from source

The core library and its tests build now; the menu-bar app lands with v1.

```sh
git clone https://github.com/yashMangal19/jarvis.git
cd jarvis
git checkout feature/jarvis-ambient-memory
swift build
swift test
```

For transcription, install whisper.cpp: `brew install whisper-cpp`.

### After v1: one command

```sh
brew install yashMangal19/tap/jarvis
```

Or from source:

```sh
git clone https://github.com/yashMangal19/jarvis
cd jarvis && ./install.sh
```

Then:

1. **Allow the mic.** Open Jarvis from the menu bar and allow microphone access.
2. **Connect Claude (optional).** Install [Claude Code](https://claude.com/claude-code) and sign in. Add tools with `claude mcp add`.
3. **Start listening.** Click Start. Turn on Demo mode to see a note in 2 minutes.

## Your data

Plain files you own.

```
~/Jarvis/
├── inbox/          phone recordings to import
├── transcripts/    deleted after 7 days
├── notes/
│   ├── hourly/
│   ├── daily/
│   └── weekly/
├── index/          for search
└── prompts/        edit to change your notes
```

## Build on top

Each step is a small Swift protocol in `JarvisCore`. Replace one without touching the rest.

```swift
protocol Transcriber   { func transcribe(_ chunk: AudioChunk) async throws -> String }
protocol NoteWriter    { func note(from transcript: String, prompt: String) async throws -> String }
protocol Embedder      { func embed(_ text: String) throws -> [Float] }
protocol CommandRunner {
  func draft(_ command: String) async throws -> String   // never acts
  func execute(_ draft: String) async throws -> String   // only after "yes"
}
```

Ideas to try:

- Change how notes read: edit `prompts/hourly.md`.
- Give Jarvis new powers: `claude mcp add` any MCP server.
- Send yourself a daily digest of `notes/daily/`.
- Build a phone companion in SwiftUI or Compose that feeds the inbox.
- Name individual speakers inside "Others".
- Add Siri with App Intents (macOS 27): "Siri, ask Jarvis …".

## Licence

MIT. See [LICENSE](LICENSE). Made by Yash Mangal for Swift Mumbai. Questions and pull requests are welcome.
