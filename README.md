# Jarvis for Mac

A small menu-bar app that listens, remembers and acts, so you don't have to hold everything in your head.
It records you (and, if you want, your calls and the room), turns speech into text on your Mac, writes a
short note every hour, lets you search your notes, and acts on "Jarvis, …" after it has read back its
plan and you've said yes.

Full guide: [`docs/guide.html`](docs/guide.html), published at
<https://yashmangal19.github.io/jarvis/guide.html>.

## Requirements

- **macOS 13 or later.** macOS 27 on Apple Silicon gets the newest features (Apple's on-device speech
  and notes) automatically.
- **Homebrew** and the **Xcode Command Line Tools** (`xcode-select --install`). Xcode 27 for the newest features.
- **Optional:** Claude Code with a Claude plan, for the best notes and for voice commands. Without it,
  Apple's on-device model (macOS 26+) or Ollama writes notes.
- A built-in mic or any earbuds. AirPods are best for your own voice.

## Install

One command (once the Homebrew tap is published):

```sh
brew install yashMangal19/tap/jarvis
```

Or from source:

```sh
git clone https://github.com/yashMangal19/jarvis
cd jarvis && ./install.sh
```

On a Mac that already has Homebrew and the Command Line Tools, this takes under 10 minutes and ends
with the Jarvis icon in the menu bar. The script:

1. checks for macOS 13+, Homebrew and the Command Line Tools;
2. installs `whisper-cpp` with Homebrew, unless it's already there;
3. puts the wake-word model in `~/Jarvis/models`, and downloads the whisper `small` model (about
   470 MB) on macOS 15 and earlier. On macOS 26 and later Apple's speech recognition is used, and Jarvis
   downloads a whisper model in the background only if your language needs it;
4. looks for Claude Code. If it's missing, it offers to install Ollama (about 2 GB) for notes;
5. builds Jarvis (`swift build -c release`) and prints how long it took;
6. puts the app at `~/Applications/Jarvis.app`, signed locally (ad hoc, not for distribution), and opens it.

Running it again is safe: finished steps are skipped and the app is rebuilt. If Jarvis is running,
quit it from its menu first, or the old version keeps running.

| Option | What it does |
|---|---|
| `--with-whisper` | download the whisper model on macOS 26+ too |
| `--model small\|medium\|large-v3-turbo` | pick the whisper model to download (implies `--with-whisper`) |
| `--with-ollama` | install Ollama and the `llama3.2` model without asking |
| `--bundle-only --prefix <dir>` | only build and sign `<dir>/Jarvis.app` (used by the Homebrew formula) |
| `--dry-run` | print every step without changing anything |

### First launch

1. **Microphone:** allow it when macOS asks. If it's off, the menu says "Microphone access is off" with a
   button that opens the right Settings page.
2. **Screen Recording** (for call audio only, Jarvis never records your screen): Jarvis explains, then
   asks once, on the first launch. If you say no, it works with your mic only, and the menu shows
   "Call audio off — Allow Screen Recording…" in case you change your mind.
3. **Full Disk Access** (only to import iPhone Voice Memos): the menu shows "Allow Full Disk Access to
   import Voice Memos" with a button that opens System Settings › Privacy & Security › Full Disk Access.
   Only memos recorded after that are imported. To add older ones, drop them in `~/Jarvis/inbox`.
4. **Connect Claude (optional):** install Claude Code and sign in. Add tools with `claude mcp add`.
5. Click **Start listening**. Turn on **Demo mode** to see a note in 2 minutes.

### Uninstall

```sh
install/uninstall.sh            # removes ~/Applications/Jarvis.app, keeps your notes in ~/Jarvis
install/uninstall.sh --purge    # also deletes ~/Jarvis (asks you to type "delete" first)
```

Quit Jarvis from its menu first. Homebrew packages and the permissions you granted stay. The script
prints how to remove them.

## What runs where

Everything runs on your Mac. Only text, never audio, goes to the note writer you choose.

| Step | Engine, first available wins |
|---|---|
| Speech to text | Apple SpeechAnalyzer (macOS 26+, for the languages it supports), then whisper.cpp with a multilingual model. Hindi and Hinglish work too. |
| Hourly notes | Claude Code (`claude -p`), then Apple's on-device model (macOS 26+), then a local Ollama model. With none, the menu says "Notes off — install Claude Code or Ollama", and transcripts and search keep working. |
| Search | Core AI (planned, no model ships yet), then NLContextualEmbedding (macOS 14+), then NLEmbedding. |
| Voice commands | Claude Code, using the tools you've connected to it and ticked in Settings. |

Settings › Engines shows which engine is in use.

**Starting a command:** say "Jarvis, …", or hold ⌥Space, speak, then let go. Holding ⌥Space works
even when Jarvis is stopped: the mic is on only while you hold the key, and nothing is saved.
**Squeezing an AirPods stem is experimental:** it may not work with every AirPods model or macOS
version. Use the wake word or ⌥Space if it doesn't.

## Privacy

Tell people when you're recording them. Consent and local laws apply to you.

- The icon is red while recording. Pause with a click or "Jarvis, pause": nothing is recorded, but
  "Jarvis, …" still works. Stop turns everything off, wake word included.
- Jarvis stops when your screen locks and during the quiet hours you set, checked from the moment it
  launches. Nothing automatic overrides quiet hours. If you click Start listening during them, Jarvis
  stays on until that night's quiet hours end.
- Audio is never stored and never uploaded. It's processed in memory. The one exception: if the
  whisper server is down, the fallback writes a temporary file and deletes it once transcribed.
- Raw transcripts are deleted after 7 days. Notes stay.
- "Forget last hour" deletes that hour's transcript, notes and search entries. It deletes exactly
  the hour it showed you, and can't be undone.
- Nothing leaves your Mac until Jarvis has read the plan back and you've said yes.

## Your data

Plain files you own, in `~/Jarvis`:

```
~/Jarvis/
├── inbox/          phone recordings to import
├── transcripts/    deleted after 7 days
├── notes/          hourly/, daily/, weekly/
├── index/          for search
├── prompts/        edit to change how your notes read
└── models/         whisper models
```

## Known limits

- **Claude Code runs locked down, with limits.** Jarvis starts Claude with your own settings
  unloaded, in a scratch folder, refusing anything not allowed instead of asking, and with the
  MCP servers you didn't tick in Settings blocked. Still:
  - policies your admin manages still apply;
  - a server missing from `claude mcp list` is refused only by the refuse-instead-of-asking mode;
  - signing in to Claude through `settings.json` isn't supported;
  - listing MCP servers adds a little time to each command.
- The mic can still catch Jarvis reading a plan back, so a read-back sentence may show up in a
  transcript. It is removed from call audio.
- If an imported recording is only partly transcribed when Jarvis quits, it's retried from the start
  next time and can add duplicate lines.
- The app is signed locally (ad hoc). After a rebuild, macOS may ask for permissions again.

## Development

```sh
swift build
swift test
```

`JarvisCore` holds the logic and is covered by tests. The app, the installer and the Homebrew formula
are checked by hand. Every decision is recorded in [`DECISIONS.md`](DECISIONS.md).

**Publishing the guide (maintainer, once, after merging):** turn on GitHub Pages for this repo (Settings ›
Pages › deploy from the default branch, `/docs` folder) so <https://yashmangal19.github.io/jarvis/guide.html>
works. The app's "Notes off" link opens that page.
