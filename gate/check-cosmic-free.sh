#!/usr/bin/env bash
# No COSMIC left in any manifest repo (owner decision 2026-10-14). For each repo of the manifest, plus desktop itself,
# checked out under ROOT side by side:
#   - `git grep -i -E 'cosmic|system76|cctk'` finds nothing outside cosmic-free-allow.txt, and
#   - no Cargo.lock lists a package named cosmic-* or a pop-os/cosmic git source.
# Every offending match is printed. A repo absent from ROOT is noted and skipped; no repo at all is an error.
#
#   check-cosmic-free.sh [ROOT]     ROOT defaults to the desktop gate's checkout directory
# Allow file: one `<repo>:<path glob>  # reason` per line; the glob matches the whole path (`*` crosses `/`).
# Exit 0 COSMIC-FREE, 1 COSMIC FOUND, 2 usage or nothing to check.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../harness/lib/manifest.sh
source "$HERE/../harness/lib/manifest.sh"
ROOT_DIR="${1:-${DESKTOP_GATE_DIR:-$HOME/rs-wt/desktop-gate}}"
ALLOW="${COSMIC_FREE_ALLOW:-$HERE/cosmic-free-allow.txt}"
PATTERN='cosmic|system76|cctk'
[ -d "$ROOT_DIR" ] || { echo "no such directory: $ROOT_DIR" >&2; exit 2; }
[ -r "$ALLOW" ] || { echo "no allow file: $ALLOW" >&2; exit 2; }

found=0 scanned=0

allowed() { # REPO PATH
  local line glob
  while IFS= read -r line; do
    line=${line%%#*}; line=${line%"${line##*[![:space:]]}"}
    case "$line" in "$1":*) ;; *) continue ;; esac
    glob=${line#*:}
    # shellcheck disable=SC2254  # the glob is the point
    case "$2" in $glob) return 0 ;; esac
  done <"$ALLOW"
  return 1
}

scan_text() { # REPO DIR
  local r=$1 d=$2 out rc=0 path rest
  out=$(git -C "$d" grep --untracked -n -I -i -E "$PATTERN" -- . ':!Cargo.lock' ':!**/Cargo.lock') || rc=$?
  [ "$rc" != 128 ] || { echo "$r: git grep failed in $d" >&2; found=$((found + 1)); return; }
  [ -n "$out" ] || return 0
  while IFS= read -r line; do
    path=${line%%:*}; rest=${line#*:}
    allowed "$r" "$path" || { echo "$r:$path:$rest"; found=$((found + 1)); }
  done <<<"$out"
}

scan_locks() { # REPO DIR
  local r=$1 d=$2 lock hits
  while IFS= read -r lock; do
    [ -n "$lock" ] || continue
    hits=$(grep -n -E '^name = "cosmic-|pop-os/cosmic' "$d/$lock") || true
    [ -z "$hits" ] || { while IFS= read -r l; do echo "$r:$lock:$l"; found=$((found + 1)); done <<<"$hits"; }
  done < <(git -C "$d" ls-files --cached --others --exclude-standard -- 'Cargo.lock' '**/Cargo.lock')
}

for r in $(manifest_repos) desktop; do
  d="$ROOT_DIR/$r"
  if [ ! -d "$d" ]; then echo "(skipped $r: not under $ROOT_DIR)"; continue; fi
  scanned=$((scanned + 1))
  scan_text "$r" "$d"
  scan_locks "$r" "$d"
done

[ "$scanned" -gt 0 ] || { echo "no repo under $ROOT_DIR" >&2; exit 2; }
if [ "$found" = 0 ]; then echo "COSMIC-FREE ($scanned repos)"; exit 0; fi
echo "COSMIC FOUND ($found)"
exit 1
