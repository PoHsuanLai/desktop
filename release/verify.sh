#!/usr/bin/env bash
# Check a packed release the way slipway will: the signature on release.toml, the bundle's size and
# digest, every file's digest and mode, nothing in the bundle that is not listed, no links, clean paths,
# exports under the allowed directories and pointing at bundle files.
#
#   release/verify.sh DIR --pubkey FILE
#
# Exit: 0 verified, 1 refused, 2 bad usage or a tool missing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
dir="" pub=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pubkey) pub=${2:?}; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) dir=$1 ;;
  esac
  shift
done
[ -d "$dir" ] && [ -f "$pub" ] || { usage >&2; exit 2; }
for tool in python3 zstd minisign; do
  command -v "$tool" >/dev/null || { echo "verify.sh: $tool is not installed" >&2; exit 2; }
done
exec python3 -I "$HERE/release.py" verify "$dir" "$pub"
