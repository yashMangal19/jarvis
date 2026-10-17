#!/usr/bin/env bash
# Jarvis installer: from `git clone` to the menu-bar icon. Safe to re-run: finished steps are skipped
# and the app bundle is rebuilt. Uses only bash, curl, brew, swift, codesign and plutil. No sudo.
#
#   ./install.sh                         full install into ~/Applications/Jarvis.app, then open it
#   ./install.sh --with-whisper          also download the whisper model on macOS 26+
#   ./install.sh --model medium          download a larger whisper model (implies --with-whisper)
#   ./install.sh --with-ollama           install Ollama for notes when Claude Code is missing (~2 GB)
#   ./install.sh --bundle-only --prefix <dir>
#                                        release build + signed <dir>/Jarvis.app only (used by the Homebrew formula);
#                                        no checks, downloads or launch
#   ./install.sh --dry-run               print every action, change nothing
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="$HOME/Applications"
jarvis_home="$HOME/Jarvis"                                              # JarvisPaths.standard
model_url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"  # WhisperModelDownloader.baseURL
model=small
with_whisper=0 with_ollama=0 bundle_only=0 dry_run=0

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
say()   { printf '\033[1m==>\033[0m %s\n' "$*"; }
note()  { printf '    %s\n' "$*"; }
die()   { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
# Every action that changes something goes through `run`, so --dry-run prints it instead.
run() {
  if [ "$dry_run" = 1 ]; then printf '    [dry-run]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bundle-only)  bundle_only=1 ;;
    --prefix)       [ $# -ge 2 ] || die "--prefix needs a folder"; prefix="$2"; shift ;;
    --with-whisper) with_whisper=1 ;;
    --model)        [ $# -ge 2 ] || die "--model needs a name"; model="$2"; with_whisper=1; shift ;;
    --with-ollama)  with_ollama=1 ;;
    --dry-run)      dry_run=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; die "unknown option: $1" ;;
  esac
  shift
done
# The names WhisperInstall.preferredModel looks for; anything else would download a model Jarvis never uses.
case "$model" in small|medium|large-v3-turbo) ;; *) die "--model must be small, medium or large-v3-turbo" ;; esac

app="$prefix/Jarvis.app"
models="$jarvis_home/models"

# Same search order as WhisperInstall.defaultSearchPath (+ ClaudeCLI's extra homes for `claude`).
find_tool() {
  local name dir dirs
  dirs="/opt/homebrew/bin:/usr/local/bin:${PATH:-}:$HOME/.local/bin:$HOME/.claude/local"
  for name in "$@"; do
    while IFS= read -r dir; do
      if [ -n "$dir" ] && [ -x "$dir/$name" ]; then printf '%s\n' "$dir/$name"; return 0; fi
    done <<< "${dirs//:/$'\n'}"
  done
  return 1
}

# Downloads ggml-<name>.bin into the models folder unless it is there. Like the app's downloader, it
# writes <file>.part and renames on completion, so a half download never looks like a model; a re-run
# resumes the .part.
download_model() {
  local name="$1" file="$models/ggml-$1.bin"
  if [ -f "$file" ]; then note "ggml-$name.bin already downloaded."; return; fi
  say "Downloading whisper model ggml-$name.bin (resumes if interrupted)"
  run curl -fL --retry 3 -C - -o "$file.part" "$model_url/ggml-$name.bin"
  run mv "$file.part" "$file"
}

check_system() {
  [ "$(uname -s)" = Darwin ] || die "Jarvis runs on macOS only."
  macos="$(sw_vers -productVersion)"
  macos_major="${macos%%.*}"
  [ "$macos_major" -ge 13 ] || die "Jarvis needs macOS 13 or later (this Mac has $macos)."
  command -v brew >/dev/null || die "Homebrew is missing. Install it from https://brew.sh, then re-run."
  xcode-select -p >/dev/null 2>&1 || die "The Xcode Command Line Tools are missing. Run: xcode-select --install"
  say "macOS $macos on $(uname -m), Homebrew and developer tools found"
  if [ "$macos_major" -lt 27 ]; then
    note "Tip: update to macOS 27 and Xcode 27 if you can. Jarvis works without them, and gets Apple's"
    note "newest on-device frameworks automatically once you have them."
  fi
}

install_whisper() {
  if find_tool whisper-server whisper-cli whisper-cpp >/dev/null; then
    say "whisper.cpp already installed"
  else
    say "Installing whisper.cpp (Homebrew)"
    run brew install whisper-cpp
  fi
}

install_models() {
  run mkdir -p "$models"
  # The wake-word model. Model files are not committed (.gitignore), so a fresh clone downloads it.
  if [ -f "$models/ggml-base.en.bin" ]; then
    note "Wake-word model already in place."
  elif [ -f "$repo/models/ggml-base.en.bin" ]; then
    say "Copying the wake-word model"
    run cp "$repo/models/ggml-base.en.bin" "$models/"
  else
    download_model base.en
  fi
  if [ "$with_whisper" = 1 ] || [ "$macos_major" -lt 26 ]; then
    download_model "$model"
  else
    say "Speech: Apple's on-device speech recognition (macOS $macos)"
    note "No whisper model needed now. If your language isn't covered, Jarvis downloads one in the"
    note "background. To download it now: ./install.sh --with-whisper"
  fi
}

install_ollama() {
  if ! find_tool ollama >/dev/null; then
    say "Installing Ollama (Homebrew)"
    run brew install ollama
  fi
  run brew services start ollama
  if [ "$dry_run" = 0 ]; then
    local tries=0
    until curl -fs http://127.0.0.1:11434/api/tags >/dev/null; do
      tries=$((tries + 1)); [ "$tries" -le 30 ] || die "Ollama didn't start. Try: brew services restart ollama"
      sleep 1
    done
  fi
  say "Downloading the llama3.2 model (about 2 GB)"
  run "$(find_tool ollama || echo ollama)" pull llama3.2
}

choose_note_writer() {
  if find_tool claude >/dev/null; then
    say "Notes and commands: Claude Code"
    return
  fi
  say "Claude Code not found"
  [ "$macos_major" -ge 26 ] && note "Notes can use Apple's on-device model when Apple Intelligence is on."
  if [ "$with_ollama" = 1 ]; then
    install_ollama
  elif find_tool ollama >/dev/null; then
    note "Notes: Ollama (already installed)."
  elif [ "$macos_major" -lt 26 ] && [ -t 0 ]; then
    printf '    Install Ollama for local notes? It downloads about 2 GB. [y/N] '
    local answer; read -r answer || answer=
    case "$answer" in y|Y|yes) install_ollama ;; *) note "Skipped. Without a note writer, transcripts and search still work." ;; esac
  else
    note "For notes, install Claude Code (https://claude.com/claude-code) or re-run with --with-ollama."
  fi
}

build_and_bundle() {
  say "Building Jarvis (swift build -c release)"
  local started=$SECONDS bin
  run swift build --package-path "$repo" -c release --product JarvisApp
  note "Build took $((SECONDS - started)) s."
  bin="$(swift build --package-path "$repo" -c release --show-bin-path)"

  # Built beside the old bundle and swapped in, so a failed step never leaves a half-built app.
  say "Building $app"
  local staging="$prefix/.Jarvis.app.staging"
  run rm -rf "$staging"
  run mkdir -p "$staging/Contents/MacOS"
  run cp "$bin/JarvisApp" "$staging/Contents/MacOS/JarvisApp"
  run cp "$repo/Sources/JarvisApp/Info.plist" "$staging/Contents/Info.plist"
  run plutil -lint -s "$staging/Contents/Info.plist"
  # Ad-hoc signature, local only (not distribution signing). The bundle is what makes the
  # microphone prompt Jarvis's own rather than Terminal's.
  run codesign --force --sign - "$staging"
  run rm -rf "$app"
  run mv "$staging" "$app"
}

launch() {
  if pgrep -x JarvisApp >/dev/null; then
    say "Jarvis is already running the previous version"
    note "Quit it from its menu (Quit), then run: open \"$app\""
  else
    say "Opening Jarvis"
    run open "$app"
  fi
  cat <<MSG

Look for the Jarvis icon in the menu bar.
  1. Allow microphone access when macOS asks.
  2. Screen Recording is asked for once, for call audio only. You can say no and allow it later from the menu.
  3. To import iPhone Voice Memos, allow Full Disk Access: System Settings > Privacy & Security >
     Full Disk Access > add Jarvis (the menu has a button that opens that page).
  4. Click Start listening. Turn on Demo mode to see a note in 2 minutes.

Privacy: tell people when you are recording them. Consent and local laws apply to you.
Guide: https://yashmangal19.github.io/jarvis/guide.html
MSG
}

if [ "$bundle_only" = 1 ]; then
  run mkdir -p "$prefix"
  build_and_bundle
  exit 0
fi

check_system
install_whisper
install_models
choose_note_writer
run mkdir -p "$prefix"
build_and_bundle
launch
