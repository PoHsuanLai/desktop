#!/usr/bin/env bash
# Install a packed release with slipway's privileged helper on THIS computer and check the result: every
# export is a link to a file of the release, every system file is in place, `current` names the release,
# every program's libraries resolve, and installing the same version again is refused. For a throwaway
# machine (a CI container): it writes /etc/slipway, /opt/quire, /usr/local/bin, /usr/share and the system
# folders as root. It refuses to run as anyone else, or without --really.
#
#   release/smoke.sh --release DIR --pubkey FILE --helper PATH --really [--root DIR]
#
#   --release DIR  the packed release (release.toml, release.toml.minisig, bundle.tar.zst)
#   --pubkey FILE  the key it is signed with
#   --helper PATH  the built slipway-apply
#   --root DIR     the install root (default /opt/quire)
#   --really       yes, this machine may be changed
#
# Exit: 0 all checks pass, 1 a check failed, 2 bad usage, not root or a tool missing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/lib.sh
. "$HERE/lib.sh"
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
release="" pub="" helper="" root=/opt/quire really=0
while [ $# -gt 0 ]; do
  case "$1" in
    --release) release=${2:?}; shift ;;
    --pubkey) pub=${2:?}; shift ;;
    --helper) helper=${2:?}; shift ;;
    --root) root=${2:?}; shift ;;
    --really) really=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$release" ] && [ -f "$pub" ] && [ -x "$helper" ] || { usage >&2; exit 2; }
[ "$really" = 1 ] || { echo "smoke.sh: this changes the whole computer; add --really on a throwaway one" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "smoke.sh: run as root (in the container)" >&2; exit 2; }
for tool in python3 zstd minisign; do
  command -v "$tool" >/dev/null || { echo "smoke.sh: $tool is not installed ($(install_hint "$tool"))" >&2; exit 2; }
done
release=$(cd "$release" && pwd)

step() { echo "== $*"; }
step "verify the release"
"$HERE/verify.sh" "$release" --pubkey "$pub"

step "install the key and the settings the helper reads"
install -Dm644 "$pub" /usr/share/slipway/release.pub
install -d /etc/slipway
printf 'root = "%s"\npubkey_path = "/usr/share/slipway/release.pub"\n' "$root" >/etc/slipway/config.toml

step "slipway-apply"
"$helper" "$release"

step "what is in place"
python3 -I "$HERE/release.py" installed "$release" "$root"

step "libraries resolve here"
"$HERE/check-ldd.sh" --stage "$root/current"

step "the same version again is refused"
set +e
"$helper" "$release" >/dev/null 2>&1
code=$?
set -e
[ "$code" = 3 ] || { echo "smoke.sh: installing the same version again exited $code, not 3 (refused)" >&2; exit 1; }
echo "smoke: pass"
