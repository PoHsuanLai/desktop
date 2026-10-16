#!/usr/bin/env bash
# Installs rustup from its published program for one version, checking its SHA-256 first, with no toolchain
# (each repo pins its own in rust-toolchain.toml, installed afterwards). It replaces `curl https://sh.rustup.rs | sh`, which
# runs whatever the address serves that day.
#
#   release/install-rustup.sh [--version X] [--sha256 HEX]
#
#   --version X   default 1.29.1
#   --sha256 HEX  the digest of rustup-init for x86_64-unknown-linux-gnu at that version (static.rust-lang.org
#                 publishes it beside the program, as rustup-init.sha256); required with any other --version
#
# x86_64 Linux only. Needs curl and sha256sum. Puts rustup in ~/.cargo/bin.
# Exit: 0 installed, 1 the download or the check failed, 2 bad usage or a tool missing.
set -euo pipefail
version=1.29.1 sha=""
default_sha=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version=${2:?}; shift ;;
    --sha256) sha=${2:?}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "install-rustup.sh: not a release version: $version" >&2; exit 2; }
if [ -z "$sha" ]; then
  [ "$version" = 1.29.1 ] || { echo "install-rustup.sh: give --sha256 for version $version" >&2; exit 2; }
  sha=$default_sha
fi
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "install-rustup.sh: not a SHA-256: $sha" >&2; exit 2; }
for tool in curl sha256sum; do
  command -v "$tool" >/dev/null || { echo "install-rustup.sh: $tool is not installed" >&2; exit 2; }
done
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT
curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$tmp/rustup-init" \
  "https://static.rust-lang.org/rustup/archive/$version/x86_64-unknown-linux-gnu/rustup-init" \
  || { echo "install-rustup.sh: cannot download rustup-init $version" >&2; exit 1; }
echo "$sha  $tmp/rustup-init" | sha256sum -c --quiet - || { echo "install-rustup.sh: rustup-init does not match $sha" >&2; exit 1; }
chmod 755 "$tmp/rustup-init"
"$tmp/rustup-init" -y --default-toolchain none --profile minimal --no-modify-path
