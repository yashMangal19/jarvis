#!/usr/bin/env bash
# Fills in the Homebrew formula for a release tag (J-024): the source tarball's checksum, and both whisper models
# at their pinned revision with their pinned checksums from install/whisper-models.txt (J-026, DEC-53). Dry run
# by default: prints what would change and changes nothing. With --apply it edits Formula/jarvis.rb in the tap and makes a LOCAL commit there;
# pushing the tap stays a human step. Run with --help for the options.
set -euo pipefail

repo_url="https://github.com/yashMangal19/jarvis"
manifest="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/whisper-models.txt"
tag="" tap="$HOME/homebrew-tap" apply=0 tarball_sha=""

usage() {
  cat <<'HELP'
Usage:
  install/release-formula.sh --tag v0.1.0                 dry run: show the formula changes, change nothing
  install/release-formula.sh --tag v0.1.0 --apply         write Formula/jarvis.rb and commit it in the tap (no push)
Options:
  --tap <dir>            the tap checkout (default ~/homebrew-tap)
  --tarball-sha <sha>    use this instead of downloading the tag's source tarball
The whisper models' URLs and checksums come from install/whisper-models.txt; nothing large is downloaded.
HELP
}

die() { printf 'release-formula: %s\n' "$*" >&2; exit 1; }
is_sha() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
sha_of_url() { curl -fsSL --retry 3 "$1" | shasum -a 256 | cut -d' ' -f1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)          [ $# -ge 2 ] || die "--tag needs a value"; tag="$2"; shift ;;
    --tap)          [ $# -ge 2 ] || die "--tap needs a folder"; tap="$2"; shift ;;
    --apply)        apply=1 ;;
    --tarball-sha)  [ $# -ge 2 ] || die "--tarball-sha needs a value"; tarball_sha="$2"; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--tag must look like v0.1.0"
formula="$tap/Formula/jarvis.rb"
[ -f "$formula" ] || die "no formula at $formula"
tarball_url="$repo_url/archive/refs/tags/$tag.tar.gz"

if [ -z "$tarball_sha" ]; then
  # The tarball exists only once the tag is pushed; GitHub answers 404 before that.
  curl -fsSLI "$tarball_url" >/dev/null 2>&1 || die "$tag is not on GitHub yet ($tarball_url). Push the tag first."
  printf 'Downloading %s to checksum it…\n' "$tarball_url"
  tarball_sha="$(sha_of_url "$tarball_url")"
fi
[ -f "$manifest" ] || die "no model manifest at $manifest"
revision="$(awk '$1 == "revision" { print $2 }' "$manifest")"
small_sha="$(awk '$1 == "ggml-small.bin" { print $2 }' "$manifest")"
base_sha="$(awk '$1 == "ggml-base.en.bin" { print $2 }' "$manifest")"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "no pinned revision in $manifest"
is_sha "$tarball_sha" || die "not a sha256: $tarball_sha"
is_sha "$small_sha" || die "ggml-small.bin isn't pinned in $manifest"
is_sha "$base_sha" || die "ggml-base.en.bin isn't pinned in $manifest"

# The formula's first url/sha256 pair is the source tarball; the sha256 after ggml-small.bin is the small model's.
# Each model resource: its url moves to the pinned revision and the sha256 that follows it to the pinned value.
updated="$(URL="$tarball_url" TSHA="$tarball_sha" REV="$revision" SSHA="$small_sha" BSHA="$base_sha" perl -0pe '
  s{^(  url ")[^"]+(")}{$1$ENV{URL}$2}m;
  s{^  # PLACEHOLDER: no v\d+\.\d+\.\d+ tag exists yet\..*\n}{}m;
  s{^(  sha256 ")[0-9a-f]{64}(")}{$1$ENV{TSHA}$2}m;
  s{\n\s*# PLACEHOLDER: replace with the file.s sha256\.}{}s;
  for my $m (["ggml-small.bin", $ENV{SSHA}], ["ggml-base.en.bin", $ENV{BSHA}]) {
    my ($file, $sha) = @$m;
    s{(url "https://huggingface\.co/ggerganov/whisper\.cpp/resolve/)[^/"]+(/\Q$file\E"\n(?:\s*#[^\n]*\n)*\s*sha256 ")[0-9a-f]{64}(")}{$1$ENV{REV}$2$sha$3}s;
  }
' "$formula")"

if diff -q "$formula" <(printf '%s\n' "$updated") >/dev/null; then
  printf 'Formula already up to date for %s.\n' "$tag"
  exit 0
fi
printf '\nChanges to %s:\n' "$formula"
diff -u "$formula" <(printf '%s\n' "$updated") | tail -n +3 || true

grep -q '0\{64\}' <<<"$updated" && die "a placeholder sha256 is still in the formula; nothing written"
if [ "$apply" = 1 ]; then
  printf '%s\n' "$updated" > "$formula"
  ruby -c "$formula" >/dev/null || die "the edited formula doesn't parse; fix it before committing"
  git -C "$tap" add Formula/jarvis.rb
  git -C "$tap" commit -q -m "jarvis $tag: source tarball and ggml-small.bin checksums"
  printf '\nCommitted in %s (not pushed). Push it with: git -C %q push\n' "$tap" "$tap"
else
  printf '\nDry run: nothing written. Add --apply to write and commit (still no push).\n'
fi
