#!/usr/bin/env bash
# Removes Jarvis.app. Your notes and settings in ~/Jarvis stay unless you pass --purge.
#
#   install/uninstall.sh                  remove ~/Applications/Jarvis.app
#   install/uninstall.sh --prefix <dir>   remove <dir>/Jarvis.app
#   install/uninstall.sh --purge          also delete ~/Jarvis (notes, transcripts, index, models, settings)
#   install/uninstall.sh --dry-run        print every action, change nothing
set -euo pipefail

prefix="$HOME/Applications"
jarvis_home="$HOME/Jarvis"   # JarvisPaths.standard
purge=0 dry_run=0

usage() { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
say()   { printf '\033[1m==>\033[0m %s\n' "$*"; }
die()   { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
run() {
  if [ "$dry_run" = 1 ]; then printf '    [dry-run]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)  [ $# -ge 2 ] || die "--prefix needs a folder"; prefix="$2"; shift ;;
    --purge)   purge=1 ;;
    --dry-run) dry_run=1 ;;
    -h|--help) usage; exit 0 ;;
    *)         usage >&2; die "unknown option: $1" ;;
  esac
  shift
done
app="$prefix/Jarvis.app"

# Quit from the menu waits for the current chunk and the whisper servers to shut down; killing the
# app here would skip that and leave the servers running.
if pgrep -x JarvisApp >/dev/null; then
  die "Jarvis is running. Quit it from its menu (Quit), then run this again."
fi

if [ -d "$app" ]; then
  say "Removing $app"
  run rm -rf "$app"
else
  say "No app at $app"
fi

if [ "$purge" = 1 ] && [ -d "$jarvis_home" ]; then
  say "Deleting $jarvis_home: every note, transcript, search index, model and setting. This can't be undone."
  if [ -t 0 ] && [ "$dry_run" = 0 ]; then
    printf '    Type "delete" to confirm: '
    answer=; read -r answer || true
    [ "$answer" = delete ] || die "Cancelled. Nothing in $jarvis_home was deleted."
  fi
  run rm -rf "$jarvis_home"
elif [ -d "$jarvis_home" ]; then
  say "Kept your notes in $jarvis_home (delete them with --purge)"
fi

cat <<MSG

Left in place (remove them yourself if you want):
  - Homebrew packages: brew uninstall whisper-cpp   (and ollama, if you installed it)
  - Permissions in System Settings > Privacy & Security, or: tccutil reset All dev.yashmangal.jarvis
MSG
