#!/usr/bin/env bash
# Check out every repo of manifest.toml at its pinned rev, side by side, as the release build needs them
# (path dependencies resolve across them). Shallow: each is fetched by its exact rev.
#
#   release/checkout.sh --siblings DIR [--extra NAME=URL@REF]...
#
#   --siblings DIR   where the repos go (DIR/<name>); one already at its rev is left alone
#   --extra N=U@R    a repo that is not in the manifest yet (slipway), at a branch, tag or rev
#
# Environment: RELEASE_READ_TOKEN, a read-only token for the private repos (sent as an HTTP header, never
# written into a remote or a file).
# Exit: 0 done, 1 a fetch failed, 2 bad usage.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sib="" extras=()
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --siblings) sib=${2:?}; shift ;;
    --extra) extras+=("${2:?}"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$sib" ] || { usage >&2; exit 2; }
mkdir -p "$sib"
auth=()
if [ -n "${RELEASE_READ_TOKEN:-}" ]; then
  header=$(printf 'x-access-token:%s' "$RELEASE_READ_TOKEN" | base64 -w0)
  echo "::add-mask::$header"
  auth=(-c "http.extraheader=Authorization: basic $header")
fi

fetch() { # NAME URL REF
  local dir="$sib/$1"
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$3" ]; then echo "$1: already at $3"; return 0; fi
  rm -rf "$dir"; mkdir -p "$dir"
  git -C "$dir" init -q
  GIT_TERMINAL_PROMPT=0 git -C "$dir" "${auth[@]}" fetch -q --depth 1 "$2" "$3" || { echo "checkout.sh: cannot fetch $1 at $3" >&2; return 1; }
  git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
  echo "$1: $(git -C "$dir" rev-parse HEAD)"
}

# name url rev per manifest repo
while read -r name url rev; do
  fetch "$name" "$url" "$rev"
done < <(awk '
  /^\[repo\./ { name = $0; sub(/^\[repo\./, "", name); sub(/\]$/, "", name); next }
  /^\[/ { name = "" }
  name != "" && $1 == "url" { gsub(/"/, "", $3); url = $3 }
  name != "" && $1 == "rev" { gsub(/"/, "", $3); print name, url, $3 }' "$HERE/../manifest.toml")
for extra in ${extras[@]+"${extras[@]}"}; do
  name=${extra%%=*}; rest=${extra#*=}; fetch "$name" "${rest%@*}" "${rest##*@}"
done
