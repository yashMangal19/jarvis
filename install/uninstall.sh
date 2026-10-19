#!/usr/bin/env bash
# Removes Jarvis.app. Your notes and settings in ~/Library/Application Support/Jarvis stay unless you pass --purge.
# Run with --help for the options.
set -euo pipefail

prefix="$HOME/Applications"
jarvis_home="$HOME/Library/Application Support/Jarvis"   # JarvisPaths.standard
purge=0 yes=0 dry_run=0

usage() {
  cat <<'HELP'
Usage:
  install/uninstall.sh                  remove ~/Applications/Jarvis.app
  install/uninstall.sh --prefix <dir>   remove <dir>/Jarvis.app
  install/uninstall.sh --purge          also delete ~/Library/Application Support/Jarvis (notes, transcripts,
                                        index, models, settings);
                                        asks you to type "delete" first
  install/uninstall.sh --purge --yes    the same without asking; required when not run from a terminal
  install/uninstall.sh --dry-run        print every action, change nothing
HELP
}
say()   { printf '\033[1m==>\033[0m %s\n' "$*"; }
die()   { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
run() {
  if [ "$dry_run" = 1 ]; then printf '    [dry-run]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)  [ $# -ge 2 ] || die "--prefix needs a folder"; prefix="$2"; shift ;;
    --purge)   purge=1 ;;
    --yes)     yes=1 ;;
    --dry-run) dry_run=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         usage >&2; die "unknown option: $1" ;;
  esac
  shift
done
[ "$yes" = 0 ] || [ "$purge" = 1 ] || die "--yes only goes with --purge."
app="$prefix/Jarvis.app"

# Quit from the menu waits for the current chunk and the whisper servers to shut down; killing the
# app here would skip that and leave the servers running.
if pgrep -x JarvisApp >/dev/null; then
  die "Jarvis is running. Quit it from its menu (Quit), then run this again."
fi

# Confirmed before anything is removed, so a refusal leaves everything as it was. Deleting the data home
# can't be undone: without a terminal to type "delete" in, only an explicit --yes allows it (DEC-36).
purge_now=0
if [ "$purge" = 1 ] && [ -d "$jarvis_home" ]; then
  say "--purge deletes $jarvis_home: every note, transcript, voice-command record, search index, model and setting. This can't be undone."
  if [ "$yes" = 1 ]; then
    purge_now=1
  elif [ -t 0 ]; then
    if [ "$dry_run" = 1 ]; then
      printf '    [dry-run] would ask you to type "delete" to confirm\n'
    else
      printf '    Type "delete" to confirm: '
      answer=; read -r answer || true
      [ "$answer" = delete ] || die "Cancelled. Nothing was removed."
    fi
    purge_now=1
  else
    die "Not run from a terminal, so there is no way to type \"delete\" to confirm. Nothing was removed.
       To delete $jarvis_home anyway, run: install/uninstall.sh --purge --yes"
  fi
fi

if [ -d "$app" ]; then
  say "Removing $app"
  run rm -rf "$app"
else
  say "No app at $app"
fi

if [ "$purge_now" = 1 ]; then
  run rm -rf "$jarvis_home"
elif [ -d "$jarvis_home" ]; then
  say "Kept your notes in $jarvis_home (delete them with --purge)"
fi

cat <<MSG

Left in place (remove them yourself if you want):
  - Homebrew packages: brew uninstall whisper-cpp   (and ollama, if you installed it)
  - Permissions in System Settings > Privacy & Security, or: tccutil reset All dev.yashmangal.jarvis
MSG
