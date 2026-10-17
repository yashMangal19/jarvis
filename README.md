# Jarvis

A clone for the part of you that forgets.

Jarvis is a macOS menu-bar app. It listens through your AirPods, keeps searchable notes of your day, and acts when you say "Jarvis, …": it drafts the action, reads it back to you, and only then does it.

From the Swift Mumbai talk **"What If You Could Clone Yourself?"** (17 Oct 2026).

> **Status: building in the open.** Jarvis is still being built. The code in progress lives on the [`feature/jarvis-ambient-memory`](../../tree/feature/jarvis-ambient-memory) branch and merges into `main` when it's done. Watch or star the repo to follow along, and fork it whenever you like.

## How it works

1. **Listen.** AirPods mic, plus system audio during calls (ScreenCaptureKit). Meeting mode uses the Mac mic for in-person rooms.
2. **Transcribe.** whisper.cpp (multilingual) on any Mac, or SpeechAnalyzer on macOS 26+.
3. **Write notes.** On a schedule, the transcript becomes notes: Claude, Apple Foundation Models (macOS 26+), or Ollama.
4. **Search.** Notes are embedded with NaturalLanguage, or Core AI on macOS 27.
5. **Act.** Say "Jarvis" (or press ⌥Space). It reads back what it will do, you confirm or correct it, and it runs through allowlisted tools.

Everything stays on your Mac as plain files you own. Pause keeps the wake word on; Stop turns everything off.

## Swap any part

Every step is a Swift protocol in `JarvisCore`: `Transcriber`, `NoteWriter`, `Embedder`, `CommandRunner`. Write your own implementation and plug it in: a different model, a different strategy, different tools.

## Requirements

- A Mac (Apple silicon recommended) on macOS 13 or later. Newer macOS unlocks the native Apple engines.
- AirPods, or any mic.
- Xcode or the Command Line Tools to build.

## Build

```sh
git clone https://github.com/yashMangal19/jarvis.git
cd jarvis
git checkout feature/jarvis-ambient-memory
swift build && swift test
```

## Licence

MIT. See [LICENSE](LICENSE).
