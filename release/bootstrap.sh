#!/usr/bin/env bash
# First install of the desktop on a machine: fetches the latest release, checks it, and hands it to slipway's
# privileged helper. Run slipway's scripts/install.sh with --pubkey first: it installs three programs in
# /usr/libexec (slipway-apply installs a release, slipway-rollback goes back and asks for the administrator's
# password, slipway-health keeps the record of which starts went well), the one polkit file that names them and
# the key at /usr/share/slipway/release.pub. This script checks all of that (release/check-helpers.sh) before it
# asks for anything.
#
#   release/bootstrap.sh [--pubkey FILE] [--base URL] [--verify-only]
#
#   --pubkey FILE   the key to check the release against (default /usr/share/slipway/release.pub)
#   --base URL      where the three files are (default the latest release of PoHsuanLai/desktop-releases)
#   --verify-only   download and verify, install nothing
#
# Downloads release.toml, release.toml.minisig and bundle.tar.zst into a fresh temporary directory, runs
# release/verify.sh on them, then `pkexec /usr/libexec/slipway-apply <dir>`; the helper checks everything again
# as root before it switches /opt/quire/current. The directory is removed at the end.
# Exit: 0 installed (or verified), 1 a download, the check or the helper failed, 2 bad usage or a tool missing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/lib.sh
. "$HERE/lib.sh"
pub=/usr/share/slipway/release.pub
base=https://github.com/PoHsuanLai/desktop-releases/releases/latest/download
helper=/usr/libexec/slipway-apply
verify_only=0
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --pubkey) pub=${2:?}; shift ;;
    --base) base=${2:?}; shift ;;
    --verify-only) verify_only=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
for tool in curl python3 zstd minisign; do
  command -v "$tool" >/dev/null || { echo "bootstrap.sh: $tool is not installed ($(install_hint "$tool"))" >&2; exit 2; }
done
[ -f "$pub" ] || { echo "bootstrap.sh: no key at $pub: run slipway's scripts/install.sh --pubkey FILE first" >&2; exit 2; }
if [ "$verify_only" = 0 ]; then
  [ -x "$helper" ] || { echo "bootstrap.sh: no $helper: run slipway's scripts/install.sh --pubkey FILE first" >&2; exit 2; }
  command -v pkexec >/dev/null || { echo "bootstrap.sh: pkexec is not installed ($(install_hint polkit))" >&2; exit 2; }
  if ! complete=$("$HERE/check-helpers.sh" 2>&1); then
    echo "$complete" >&2
    echo "bootstrap.sh: slipway's install is not complete: run its scripts/install.sh --pubkey FILE again" >&2
    exit 2
  fi
fi

dir=$(mktemp -d)
trap 'rm -rf -- "${dir:?}"' EXIT
for f in release.toml release.toml.minisig bundle.tar.zst; do
  echo "downloading $f"
  curl -fL --proto '=https,file' --retry 3 -sS -o "$dir/$f" "$base/$f" || { echo "bootstrap.sh: cannot download $base/$f" >&2; exit 1; }
done
"$HERE/verify.sh" "$dir" --pubkey "$pub" || { echo "bootstrap.sh: the release does not verify; nothing was installed" >&2; exit 1; }
[ "$verify_only" = 0 ] || exit 0
pkexec "$helper" "$dir"
