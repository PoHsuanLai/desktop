#!/usr/bin/env bash
# Pack a staged tree into a signed release: release.toml, release.toml.minisig, bundle.tar.zst.
#
#   release/pack.sh --stage DIR --version X --notes FILE --out DIR [--exports FILE] [--components FILE]
#
#   --stage DIR       the destdir build.sh staged into; DIR/opt/quire/current is what is packed
#   --version X       semver, no leading v
#   --notes FILE      plain-text release notes
#   --out DIR         where the three files go
#   --exports FILE    extra exports (default release/exports.toml)
#   --components FILE extra "name rev" lines that are not in manifest.toml (build.sh writes it)
#
# Environment: MINISIGN_KEY_FILE (the secret key), MINISIGN_PASSWORD (read by minisign from stdin; empty
# for a key without one). SOURCE_DATE_EPOCH fixes the date. The bundle is deterministic: sorted, mtime 0,
# owner 0, modes 0644 or 0755. Needs python3 (stdlib), zstd, minisign.
# Exit: 0 packed, 1 refused or failed, 2 bad usage or a tool missing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/lib.sh
. "$HERE/lib.sh"
stage="" version="" notes="" out="" exports="$HERE/exports.toml" comps=""
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --stage) stage=${2:?}; shift ;;
    --version) version=${2:?}; shift ;;
    --notes) notes=${2:?}; shift ;;
    --out) out=${2:?}; shift ;;
    --exports) exports=${2:?}; shift ;;
    --components) comps=${2:?}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$stage" ] && [ -n "$version" ] && [ -n "$notes" ] && [ -n "$out" ] || { usage >&2; exit 2; }
for tool in python3 zstd minisign; do
  command -v "$tool" >/dev/null || { echo "pack.sh: $tool is not installed ($(install_hint "$tool"))" >&2; exit 2; }
done
exec python3 -I "$HERE/release.py" pack "$stage" "$version" "$notes" "$out" "$HERE/../manifest.toml" "$exports" "$comps"
