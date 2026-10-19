# Jarvis for Mac

A small menu-bar app that listens, remembers and acts, so you don't have to hold everything in your head.
It records you (and, if you want, your calls and the room), turns speech into text on your Mac, writes a
short note every hour, lets you search your notes, and acts on "Jarvis, …" after it has read back its
plan and you've said yes. Your audio never leaves your Mac. Transcript text does when Claude Code writes
your notes: see [What leaves your Mac](#what-leaves-your-mac).

Full guide: [`docs/guide.html`](docs/guide.html), published at
<https://yashmangal19.github.io/jarvis/guide.html>.

## Requirements

- **macOS 13 or later** to run Jarvis. macOS 27 on Apple Silicon gets the newest features (Apple's
  on-device speech and notes) automatically.
- **Homebrew** and the **Xcode Command Line Tools** (`xcode-select --install`). Xcode 27 for the newest features.
- **To build from source** (both install paths do): **Swift 6.0 or later**, which comes with Xcode 16 or
  Command Line Tools 16 and later. Xcode 16 needs macOS 14.5 or later, so on an older Mac the build
  may not be possible. The installer checks `swift --version` first and stops, before downloading
  anything, if Swift is older than 6.0.
- **The Homebrew install needs macOS 14.5 or later**, because it builds from source with Swift 6. Jarvis
  itself runs on macOS 13 and later.
- **Optional:** Claude Code with a Claude plan, for the best notes and for voice commands. Without it,
  Apple's on-device model (macOS 26+) or Ollama writes notes.
- A built-in mic or any earbuds. AirPods are best for your own voice.

## Install

One command (once the Homebrew tap is published):

```sh
brew install yashMangal19/tap/jarvis
```

Then run `jarvis`. The first run copies the whisper models into Jarvis's data folder and opens the app.
Opening Jarvis from Finder or Spotlight the first time skips that copy.

Or from source:

```sh
git clone https://github.com/yashMangal19/jarvis
cd jarvis && ./install.sh
```

On a Mac that already has Homebrew and the Command Line Tools, this takes under 10 minutes and ends
with the Jarvis icon in the menu bar. The script:

1. checks for macOS 13+, Homebrew, the Command Line Tools and Swift 6.0+, and stops if Jarvis is running;
2. installs `whisper-cpp` with Homebrew, unless it's already there;
3. puts the wake-word model in Jarvis's data folder, and downloads the whisper `small` model (about
   470 MB) on macOS 15 and earlier. On macOS 26 and later Apple's speech recognition is used, and Jarvis
   downloads a whisper model in the background only if your language needs it;
4. looks for Claude Code. If it's missing, it offers to install Ollama (about 2 GB) for notes;
5. builds Jarvis (`swift build -c release`) and prints how long it took;
6. puts the app at `~/Applications/Jarvis.app`, signed locally (ad hoc, not for distribution), and opens it.

Running it again is safe: finished steps are skipped and the app is rebuilt. Quit Jarvis from its menu
first. If it's running, the installer stops and changes nothing.

**Where it looks for tools.** Jarvis opened from Finder doesn't get Terminal's `PATH`, so the installer
looks where the app looks: `/opt/homebrew/bin`, `/usr/local/bin` and the system folders, plus
`~/.local/bin` and `~/.claude/local` for Claude Code. If a tool is only on Terminal's `PATH` (for example
`claude` installed with npm under nvm), the installer warns that Jarvis won't see it and treats it as
missing. For `claude`, link it into `~/.local/bin`.

| Option | What it does |
|---|---|
| `--with-whisper` | download the whisper model on macOS 26+ too |
| `--model small\|medium\|large-v3-turbo` | pick the whisper model to download (implies `--with-whisper`) |
| `--with-ollama` | install Ollama and the `llama3.2` model without asking |
| `--bundle-only --prefix <dir>` | only build and sign `<dir>/Jarvis.app` (used by the Homebrew formula). Builds with `swift build --disable-sandbox`, because SwiftPM's sandbox can't start inside Homebrew's, and refuses while a Jarvis runs from any folder next to `<dir>` or from Homebrew's `opt/jarvis` link |
| `--dry-run` | print every step without changing anything |

### First launch

1. **Microphone:** allow it when macOS asks. If it's off, the menu says "Microphone access is off" with a
   button that opens the right Settings page.
2. **Screen Recording** (for call audio only, Jarvis never records your screen): Jarvis explains, then
   asks once, on the first launch. If you say no, it works with your mic only, and the menu shows
   "Call audio off — Allow Screen Recording…" in case you change your mind.
3. **Full Disk Access** (only to import iPhone Voice Memos): the menu shows "Allow Full Disk Access to
   import Voice Memos" with a button that opens System Settings › Privacy & Security › Full Disk Access.
   Only memos recorded after that are imported. To add older ones, drop them in the `inbox` folder of Jarvis's data folder (below).
4. **Connect Claude (optional):** install Claude Code and sign in. Add tools with `claude mcp add`.
5. Click **Start listening**. Turn on **Demo mode** to see a note in 2 minutes.

**After a reinstall or update.** The installer signs Jarvis on your Mac without a developer certificate
(ad hoc), and every run rebuilds the app, so macOS may treat it as a new app. It may ask for the
microphone again. Screen Recording and Full Disk Access can switch off without any prompt, and Jarvis
won't ask again for Screen Recording because it asks only once. Turn them back on from Jarvis's menu:
"Call audio off — Allow Screen Recording…" and "Allow Full Disk Access to import Voice Memos" open the
right Settings page. If the switch there looks on but the menu line stays, turn it off and on again.

### Uninstall

```sh
install/uninstall.sh            # removes ~/Applications/Jarvis.app, keeps your notes
install/uninstall.sh --purge    # also deletes your notes and data (asks you to type "delete" first)
```

`--purge` can't be undone. It only deletes after you type "delete" in Terminal. If it isn't run from a
terminal (from a script, a pipe or `ssh host command`), it refuses and removes nothing, unless you also
pass `--yes`: `install/uninstall.sh --purge --yes`. `--dry-run` prints what either would do.

Quit Jarvis from its menu first. Homebrew packages and the permissions you granted stay. The script
prints how to remove them.

## What runs where

Listening, speech to text and search run on your Mac. Notes and voice commands run wherever the engine
you use runs. [What leaves your Mac](#what-leaves-your-mac) says exactly what is sent.

| Step | Engine, first available wins |
|---|---|
| Speech to text | Apple SpeechAnalyzer (macOS 26+, for the languages it supports), then whisper.cpp with a multilingual model. Hindi and Hinglish work too. |
| Hourly notes | Claude Code (`claude -p`), then Apple's on-device model (macOS 26+), then a local Ollama model. With none, the menu says "Notes off — install Claude Code or Ollama", and transcripts and search keep working. |
| Search | Core AI (planned, no model ships yet), then NLContextualEmbedding (macOS 14+), then NLEmbedding. |
| Voice commands | Claude Code, using the tools you've connected to it and ticked in Settings. |

Settings › Engines shows which engine is in use.

**Starting a command:** say "Jarvis, …", or hold ⌥Space, speak, then let go. Holding ⌥Space works
even when Jarvis is stopped: the mic is on only while you hold the key, and nothing is saved.
**AirPods stem squeeze (experimental, off by default).** Turn it on in Settings with "AirPods stem squeeze
(experimental)". To hear a squeeze, Jarvis has to play silence so it stays the "Now Playing" app. It does
that only while it's listening or paused, never when stopped, in quiet hours or with the screen locked.
While it's on:
- it takes Now Playing from Music and other players;
- it may keep your AirPods connected to the Mac instead of switching to your phone, and it can stop the
  Mac from going to sleep when idle;
- taking an AirPod out, a Bluetooth drop or the keyboard's play/pause key can look like a squeeze and
  start a command;
- it may not work with every AirPods model or macOS version.

The wake word and ⌥Space work without it.

## Privacy

Tell people when you're recording them. Consent and local laws apply to you.

### What leaves your Mac

- **Audio never leaves your Mac.** Speech becomes text on your Mac, and the audio isn't kept.
- **With Claude Code writing your notes** (the first choice when it's installed), each hour's transcript
  **text** is sent to Anthropic to write that hour's note. This happens every hour without asking.
- **Voice commands** use Claude Code. The words of your command (and any corrections you say) are sent
  to Claude so it can draft a plan **before** you say yes. No tools run while it drafts. Only the action
  itself (sending, creating or changing anything through your tools) waits for your yes, and then what
  the action needs goes to Claude and to those tools.
- **With Apple's on-device model or Ollama** writing your notes, and no voice commands, nothing leaves
  your Mac.
- Settings › Engines shows which engine is in use.

### On your Mac

- The icon is red while recording. Pause with a click or "Jarvis, pause": nothing is recorded, but
  "Jarvis, …" still works. Stop turns everything off, wake word included.
- Jarvis stops when your screen locks and during the quiet hours you set, checked from the moment it
  launches. Nothing automatic overrides quiet hours. If you click Start listening during them, Jarvis
  stays on until that night's quiet hours end.
- Audio is never stored and never uploaded. It's processed in memory. The one exception: if the
  whisper server is down, the fallback writes a temporary file and deletes it once transcribed.
- Raw transcripts are deleted after 7 days. Notes stay.
- "Forget last hour" deletes that hour's transcript, notes and search entries. It deletes exactly
  the hour it showed you, and can't be undone. It can't recall text already sent to Anthropic.

## Your data

Plain files you own, in `~/Library/Application Support/Jarvis`. **Open notes** in the menu opens the notes folder in Finder.

```
~/Library/Application Support/Jarvis/
├── inbox/          phone recordings to import
├── transcripts/    deleted after 7 days
├── notes/          hourly/, daily/, weekly/
├── index/          for search
├── prompts/        edit to change how your notes read
└── models/         whisper models
```

Builds before 0.1.0 used `~/Jarvis`. On a Mac whose disk ignores case (the default), that is the
same folder as a `~/jarvis` clone of this repo. The first launch brings the old files across: it moves
them, or, when `~/Jarvis` is a git repository, copies them and leaves the originals for you to delete.
Jarvis refuses to start with its data folder inside a git repository.

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
- The app is signed locally (ad hoc), with no developer certificate. After a reinstall, macOS may ask
  for the microphone again, and Screen Recording or Full Disk Access may switch off silently. Turn them
  back on from Jarvis's menu (see [First launch](#first-launch)). A stable signing identity is deferred.
- The AirPods stem squeeze is experimental and off by default. See its side effects above.
- **Meeting mode can store a sentence twice.** The two mics hear each other's sounds. Your words reach the
  MacBook mic, and a phone or speaker nearby can reach the AirPods. So a sentence can be stored once per
  mic, and only one copy has the right speaker label. Notes may repeat it. Telling which mic really heard
  it needs per-sentence timing and levels that Jarvis doesn't capture yet; it is planned after 0.1.0.

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

## Licence

MIT. See [`LICENSE`](LICENSE).
