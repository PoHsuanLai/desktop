#!/usr/bin/env bash
# Fails unless release/system-files.list is exactly slipway's list of system files a release may place.
# slipway refuses a whole release that holds a path its list does not name, so a difference here is a release
# that packs and then cannot be installed (or a list that was widened on one side only).
#
#   release/check-system-list.sh --slipway DIR
#
#   --slipway DIR   a slipway checkout, at the rev manifest.toml pins (the workflow's sibling checkout)
#
# Reads DIR/crates/slipway-core/src/release/system.rs; builds and runs nothing. Needs python3.
# Exit: 0 the same, 1 different, 2 bad usage or no such file.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slipway) dir=${2:?}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$dir" ] || { usage >&2; exit 2; }
src="$dir/crates/slipway-core/src/release/system.rs"
[ -f "$src" ] || { echo "check-system-list.sh: $src is not there" >&2; exit 2; }
command -v python3 >/dev/null || { echo "check-system-list.sh: python3 is not installed" >&2; exit 2; }
exec python3 -I "$HERE/release.py" system-list "$src"
