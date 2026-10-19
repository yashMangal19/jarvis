#!/usr/bin/env bash
# Jarvis installer: from `git clone` to the menu-bar icon. Safe to re-run: finished steps are skipped
# and the app bundle is rebuilt. Uses only bash, curl, brew, swift, codesign and plutil. No sudo.
# Run with --help for the options.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="$HOME/Applications"
jarvis_home="$HOME/Library/Application Support/Jarvis"                   # JarvisPaths.standard
# Every model is fetched from one pinned revision and checked against its sha256 (DEC-53); the app's
# WhisperModels.swift holds the same values.
manifest="$repo/install/whisper-models.txt"
model=small
with_whisper=0 with_ollama=0 bundle_only=0 dry_run=0

usage() {
  cat <<'HELP'
Usage:
  ./install.sh                         full install into ~/Applications/Jarvis.app, then open it
  ./install.sh --with-whisper          also download the whisper model on macOS 26+
  ./install.sh --model medium          download a larger whisper model (implies --with-whisper)
  ./install.sh --with-ollama           install Ollama for notes when Claude Code is missing (~2 GB)
  ./install.sh --bundle-only --prefix <dir>
                                       release build + signed <dir>/Jarvis.app only (used by the Homebrew formula);
                                       no downloads or launch. Builds with swift build --disable-sandbox, because
                                       SwiftPM's own sandbox can't start inside Homebrew's build sandbox
  ./install.sh --dry-run               print every action, change nothing
HELP
}
say()   { printf '\033[1m==>\033[0m %s\n' "$*"; }
note()  { printf '    %s\n' "$*"; }
warn()  { printf '\033[33mWarning:\033[0m %s\n' "$*" >&2; }
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
# --bundle-only runs inside Homebrew's build sandbox, where macOS refuses SwiftPM's nested sandbox.
swift_flags=()
[ "$bundle_only" = 1 ] && swift_flags=(--disable-sandbox)

# Jarvis is opened from Finder or with `open`, so it gets launchd's short PATH (/usr/bin:/bin:/usr/sbin:/sbin),
# not Terminal's. These are the folders the app actually searches: WhisperInstall.defaultSearchPath
# (Homebrew's two bin folders, then that short PATH; OllamaInstall uses the same list) and, for `claude` only,
# ClaudeCLI.defaultSearchPath's two extra homes. Deciding from Terminal's PATH would find tools the app can't.
app_dirs="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
claude_dirs="$app_dirs:$HOME/.local/bin:$HOME/.claude/local"

first_in() {   # first_in <colon-separated dirs> <name>...: prints the first executable found
  local dirs="$1" name dir; shift
  for name in "$@"; do
    while IFS= read -r dir; do
      if [ -n "$dir" ] && [ -x "$dir/$name" ]; then printf '%s\n' "$dir/$name"; return 0; fi
    done <<< "${dirs//:/$'\n'}"
  done
  return 1
}

# Prints the tool's path when Jarvis will find it. A tool reachable only through Terminal's PATH counts as
# missing, with a warning saying so.
find_tool() {
  local dirs="$app_dirs" found
  [ "$1" = claude ] && dirs="$claude_dirs"
  if first_in "$dirs" "$@"; then return 0; fi
  if found="$(first_in "${PATH:-}" "$@")"; then
    warn "$found is on Terminal's PATH only. Jarvis, opened from Finder, won't see it there."
    if [ "$1" = claude ]; then
      note "To use it, link it into a folder Jarvis searches: mkdir -p ~/.local/bin && ln -s \"$found\" ~/.local/bin/claude" >&2
    else
      note "Install it with Homebrew (/opt/homebrew/bin or /usr/local/bin) so Jarvis can find it." >&2
    fi
  fi
  return 1
}

pinned_sha() { awk -v f="$1" '$1 == f { print $2 }' "$manifest"; }
pinned_url() {
  printf 'https://huggingface.co/ggerganov/whisper.cpp/resolve/%s/%s' \
    "$(awk '$1 == "revision" { print $2 }' "$manifest")" "$1"
}
sha_matches() { [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$2" ]; }

# Downloads ggml-<name>.bin into the models folder unless a copy that matches its pinned sha256 is there.
# Like the app's downloader it writes <file>.part and renames only once the checksum matches, so a half or
# wrong download never looks like a model; a re-run resumes the .part. Fails closed: a mismatch is removed
# and the install stops.
download_model() {
  local name="$1" file="$models/ggml-$1.bin" sha
  sha="$(pinned_sha "ggml-$name.bin")"
  [ -n "$sha" ] || die "ggml-$name.bin isn't pinned in install/whisper-models.txt, so it won't be downloaded."
  if [ -f "$file" ]; then
    if [ "$dry_run" = 1 ] || sha_matches "$file" "$sha"; then note "ggml-$name.bin already downloaded."; return; fi
    say "ggml-$name.bin doesn't match its pinned checksum; downloading it again"
    run rm -f "$file"
  fi
  say "Downloading whisper model ggml-$name.bin (resumes if interrupted)"
  run curl -fL --retry 3 -C - -o "$file.part" "$(pinned_url "ggml-$name.bin")"
  if [ "$dry_run" = 0 ] && ! sha_matches "$file.part" "$sha"; then
    rm -f "$file.part"
    die "ggml-$name.bin doesn't match its pinned checksum, so it was removed and not installed. Run the installer again to download it afresh."
  fi
  run mv "$file.part" "$file"
}

# Package.swift is swift-tools-version 6.0, so an older toolchain would fail only at `swift build`,
# after the model downloads. Checked first instead.
check_swift() {
  local version major
  version="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1.\2/p' | head -n 1)" || true
  [ -n "$version" ] || die "Swift wasn't found. Building Jarvis needs Swift 6.0 or later (Xcode 16 or its Command Line Tools). Run: xcode-select --install"
  major="${version%%.*}"
  if [ "$major" -lt 6 ]; then
    # Under Homebrew the source and dependencies are already downloaded by now, so say only what is true.
    local outcome="Nothing was downloaded or changed."
    [ "$bundle_only" = 1 ] && outcome="Jarvis wasn't built or installed."
    die "Building Jarvis needs Swift 6.0 or later, and this Mac has Swift $version.
       Update the Command Line Tools in System Settings > General > Software Update, or install Xcode 16 or later.
       Xcode 16 needs macOS 14.5 or later. $outcome"
  fi
  note "Swift $version"
}

# Swapping the bundle under a running Jarvis would leave it running from a deleted binary. Same rule
# and message as uninstall.sh.
# With --bundle-only, a Jarvis counts if it runs from this bundle, from any sibling folder of the prefix
# (Homebrew's other version folders, <cellar>/jarvis/*/Jarvis.app, which brew cleanup deletes after an
# upgrade), or from Homebrew's opt link (<homebrew prefix>/opt/jarvis/Jarvis.app).
re_escape() { printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|]/\\&/g'; }
refuse_if_running() {
  local running
  if [ "$bundle_only" = 1 ]; then
    local tail='/Jarvis\.app/Contents/MacOS/JarvisApp( |$)' kegs cellar pattern
    kegs="$(dirname "$prefix")"
    cellar="$(dirname "$kegs")"
    pattern="^$(re_escape "$prefix")$tail|^$(re_escape "$kegs")/[^/]+$tail"
    if [ "$(basename "$cellar")" = Cellar ]; then
      pattern="$pattern|^$(re_escape "$(dirname "$cellar")/opt/$(basename "$kegs")")$tail"
    fi
    running="$(pgrep -f "$pattern" || true)"   # macOS pgrep patterns are extended regular expressions
  else running="$(pgrep -x JarvisApp || true)"; fi
  if [ -n "$running" ]; then
    die "Jarvis is running. Quit it from its menu (Quit), then run this again."
  fi
}

check_system() {
  [ "$(uname -s)" = Darwin ] || die "Jarvis runs on macOS only."
  macos="$(sw_vers -productVersion)"
  macos_major="${macos%%.*}"
  [ "$macos_major" -ge 13 ] || die "Jarvis needs macOS 13 or later (this Mac has $macos)."
  command -v brew >/dev/null || die "Homebrew is missing. Install it from https://brew.sh, then re-run."
  xcode-select -p >/dev/null 2>&1 || die "The Xcode Command Line Tools are missing. Run: xcode-select --install"
  check_swift
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
  if [ ! -f "$models/ggml-base.en.bin" ] && [ -f "$repo/models/ggml-base.en.bin" ] \
     && sha_matches "$repo/models/ggml-base.en.bin" "$(pinned_sha ggml-base.en.bin)"; then
    say "Copying the wake-word model"
    run cp "$repo/models/ggml-base.en.bin" "$models/"
  fi
  download_model base.en   # checks a copy already in place, downloads one otherwise
  if [ "$with_whisper" = 1 ] || [ "$macos_major" -lt 26 ]; then
    download_model "$model"
  else
    say "Speech: Apple's on-device speech recognition (macOS $macos)"
    note "No whisper model needed now. If your language isn't covered, Jarvis downloads one in the"
    note "background. To download it now: ./install.sh --with-whisper"
  fi
}

install_ollama() {
  local ollama
  if ! ollama="$(find_tool ollama)"; then
    say "Installing Ollama (Homebrew)"
    run brew install ollama
    ollama="$(first_in "$app_dirs" ollama || echo ollama)"
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
  run "$ollama" pull llama3.2
}

choose_note_writer() {
  if find_tool claude >/dev/null; then
    say "Notes and commands: Claude Code"
    note "Each hour's transcript text, and the words of each command, go to Anthropic through Claude Code."
    return
  fi
  say "Claude Code not found where Jarvis looks"
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
  run swift build ${swift_flags[@]+"${swift_flags[@]}"} --package-path "$repo" -c release --product JarvisApp
  note "Build took $((SECONDS - started)) s."
  bin="$(swift build ${swift_flags[@]+"${swift_flags[@]}"} --package-path "$repo" -c release --show-bin-path)"

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
  # Checked again right before the swap, in case Jarvis was opened during the build.
  refuse_if_running
  run rm -rf "$app"
  run mv "$staging" "$app"
}

launch() {
  say "Opening Jarvis"
  run open "$app"
  cat <<MSG

Look for the Jarvis icon in the menu bar.
  1. Allow microphone access when macOS asks.
  2. Screen Recording is asked for once, for call audio only. You can say no and allow it later from the menu.
  3. To import iPhone Voice Memos, allow Full Disk Access: System Settings > Privacy & Security >
     Full Disk Access > add Jarvis (the menu has a button that opens that page).
  4. Click Start listening. Turn on Demo mode to see a note in 2 minutes.
  After a reinstall macOS may ask for the microphone again, and Screen Recording or Full Disk Access
  can switch off without a prompt. Turn them back on from the lines in Jarvis's menu.

Privacy: tell people when you are recording them. Consent and local laws apply to you.
Guide: https://yashmangal19.github.io/jarvis/guide.html
MSG
}

if [ "$bundle_only" = 1 ]; then
  check_swift
  refuse_if_running
  run mkdir -p "$prefix"
  build_and_bundle
  exit 0
fi

refuse_if_running
check_system
install_whisper
install_models
choose_note_writer
run mkdir -p "$prefix"
build_and_bundle
launch
