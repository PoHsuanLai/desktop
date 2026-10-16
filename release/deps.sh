#!/usr/bin/env bash
# Prints the packages the release flow needs on a family of Linux, one per line (so a caller can pass them to
# the package manager). The one list the workflow, a person building locally and the smoke jobs share.
# Names are from REPORT.md section 2 of the distro audit; those marked `# unverified` were written from memory.
#
#   release/deps.sh FAMILY ROLE
#
#   FAMILY  debian (Ubuntu 24.04 and later), fedora, arch, or auto (from /etc/os-release)
#   ROLE    tools    what the release scripts themselves use: git, curl, tar, python3, zstd, minisign
#           build    tools plus compilers and the development packages the components link against
#           runtime  tools plus the libraries the built programs load, for the smoke jobs
#
# Rust itself comes from rustup (the repos pin 1.98.1; no distro ships it), and Zig from release/install-zig.sh.
# Exit: 0 printed, 2 bad usage.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/lib.sh
. "$HERE/lib.sh"
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
[ $# -eq 2 ] || { usage >&2; exit 2; }
family=$1 role=$2
[ "$family" != auto ] || family=$(release_family)

tools_debian="git ca-certificates curl tar gzip xz-utils findutils python3 zstd minisign"          # minisign: universe (unverified)
tools_fedora="git ca-certificates curl tar gzip xz findutils which python3 zstd minisign"
tools_arch="git ca-certificates curl tar gzip xz findutils which python zstd minisign"

build_debian="build-essential cmake pkg-config clang libclang-dev perl binutils
  libwayland-dev wayland-protocols libxkbcommon-dev libinput-dev libseat-dev libudev-dev libdrm-dev
  libgbm-dev libegl-dev libgles-dev libpixman-1-dev libpipewire-0.3-dev libpulse-dev libpam0g-dev
  libasound2-dev libfontconfig-dev libfreetype-dev libharfbuzz-dev libxml2-dev libpng-dev libdbus-1-dev
  libx11-dev libxcb1-dev libdav1d-dev libvulkan-dev libssl-dev"
build_fedora="gcc gcc-c++ make cmake pkgconf-pkg-config clang clang-devel llvm-devel perl-core binutils
  wayland-devel wayland-protocols-devel libxkbcommon-devel libinput-devel libseat-devel systemd-devel libdrm-devel
  mesa-libgbm-devel mesa-libEGL-devel mesa-libGL-devel pixman-devel pipewire-devel pulseaudio-libs-devel pam-devel
  alsa-lib-devel fontconfig-devel freetype-devel harfbuzz-devel libxml2-devel libpng-devel dbus-devel
  libX11-devel libxcb-devel libdav1d-devel vulkan-loader-devel openssl-devel"
build_arch="base-devel cmake clang perl
  wayland wayland-protocols libxkbcommon libinput seatd systemd-libs libdrm mesa libglvnd pixman pipewire libpulse
  pam alsa-lib fontconfig freetype2 harfbuzz libxml2 libpng dbus libx11 libxcb dav1d vulkan-icd-loader openssl"

runtime_debian="libwayland-client0 libwayland-server0 libxkbcommon0 xkb-data libinput10 libseat1 libudev1 libdrm2
  libgbm1 libegl1 libgles2 libgl1 libpixman-1-0 libpipewire-0.3-0t64 libpulse0 libpam0g libasound2t64
  libfontconfig1 libfreetype6 libharfbuzz0b libxml2 libpng16-16t64 libdbus-1-3 libx11-6 libxcb1 libdav1d7
  libvulkan1 mesa-vulkan-drivers"                                                                   # t64 names and libdav1d7: unverified
runtime_fedora="wayland libxkbcommon xkeyboard-config libinput libseat systemd-libs libdrm mesa-libgbm mesa-libEGL
  mesa-libGL pixman pipewire-libs pulseaudio-libs pam alsa-lib fontconfig freetype harfbuzz libxml2 libpng
  dbus-libs libX11 libxcb libdav1d vulkan-loader mesa-vulkan-drivers"                               # libdav1d: unverified
runtime_arch="wayland libxkbcommon xkeyboard-config libinput seatd systemd-libs libdrm mesa libglvnd pixman pipewire
  libpulse pam alsa-lib fontconfig freetype2 harfbuzz libxml2 libpng dbus libx11 libxcb dav1d vulkan-icd-loader"

case "$family" in debian|fedora|arch) ;; *) echo "deps.sh: unknown family '$family' (debian, fedora, arch or auto)" >&2; exit 2 ;; esac
# shellcheck disable=SC2086  # the lists are space-separated words on purpose
pick() { local var="$1_$family"; printf '%s\n' ${!var}; }
case "$role" in
  tools) pick tools ;;
  build) { pick tools; pick build; } | sort -u ;;
  runtime) { pick tools; pick runtime; } | sort -u ;;
  *) echo "deps.sh: unknown role '$role' (tools, build, runtime)" >&2; exit 2 ;;
esac
