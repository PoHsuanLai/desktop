#!/usr/bin/env bash
# Installs Zig from the official tarball, checking its SHA-256 first. (temor builds with Zig; no distro ships a
# fixed 0.16.x: Fedora and Arch drift, Ubuntu 24.04 has none.)
#
#   release/install-zig.sh [--version X] [--sha256 HEX] [--dest DIR]
#
#   --version X   default 0.16.0
#   --sha256 HEX  the tarball's digest (default: the one published at ziglang.org/download/index.json for the
#                 default version, x86_64-linux); required with any other --version
#   --dest DIR    where the compiler goes (default /opt/zig); DIR/zig is the program. A link to it is
#                 made in /usr/local/bin when that is writable.
#
# x86_64 Linux only. Needs curl, tar, xz and sha256sum.
# Exit: 0 installed, 1 the download or the check failed, 2 bad usage or a tool missing.
set -euo pipefail
version=0.16.0 sha="" dest=/opt/zig
default_sha=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version=${2:?}; shift ;;
    --sha256) sha=${2:?}; shift ;;
    --dest) dest=${2:?}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[[ "$dest" == /*zig* ]] || { echo "install-zig.sh: --dest must be an absolute path with 'zig' in its name (it is replaced): $dest" >&2; exit 2; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "install-zig.sh: not a release version: $version" >&2; exit 2; }
if [ -z "$sha" ]; then
  [ "$version" = 0.16.0 ] || { echo "install-zig.sh: give --sha256 for version $version" >&2; exit 2; }
  sha=$default_sha
fi
for tool in curl tar xz sha256sum; do
  command -v "$tool" >/dev/null || { echo "install-zig.sh: $tool is not installed" >&2; exit 2; }
done
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT
name="zig-x86_64-linux-$version"
curl -fsSL --proto '=https' --retry 3 -o "$tmp/zig.tar.xz" "https://ziglang.org/download/$version/$name.tar.xz" \
  || { echo "install-zig.sh: cannot download Zig $version" >&2; exit 1; }
echo "$sha  $tmp/zig.tar.xz" | sha256sum -c --quiet - || { echo "install-zig.sh: the Zig tarball does not match $sha" >&2; exit 1; }
mkdir -p "$dest"
tar -C "$tmp" -xf "$tmp/zig.tar.xz"
rm -rf -- "${dest:?}"
mv "$tmp/$name" "$dest"
[ ! -w /usr/local/bin ] || ln -sfn "$dest/zig" /usr/local/bin/zig
"$dest/zig" version
