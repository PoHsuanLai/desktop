#!/usr/bin/env bash
# The distro helpers under install/ in a scratch directory: the family from an os-release file, the package
# table and the install lines per family, the escalation program, the cargo helper (a build runs from / with --manifest-path), and the check
# mode against a made-up machine. Nothing reads the real /etc/os-release or writes outside the scratch
# directory; the programs the checks look for are stubs on a PATH of its own.
#
#   distro-check.sh
# Exit 0 pass, 1 a check failed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HERE/../install"
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT

# shellcheck source=../install/distro.sh
source "$INSTALL_DIR/distro.sh"
# shellcheck source=../install/packages.sh
source "$INSTALL_DIR/packages.sh"
# shellcheck source=../install/check.sh
source "$INSTALL_DIR/check.sh"

fail() { echo "distro-check: $*" >&2; exit 1; }
expect() { # WHAT GOT WANT
  [ "$2" = "$3" ] || fail "$1: got '$2', wanted '$3'"
}
contains() { # WHAT TEXT NEEDLE
  case "$2" in *"$3"*) ;; *) fail "$1: no '$3' in: $2" ;; esac
}
lacks() { # WHAT TEXT NEEDLE
  case "$2" in *"$3"*) fail "$1: unexpected '$3' in: $2" ;; esac
}
osr() { # NAME CONTENT: an os-release file; prints its path
  printf '%s\n' "$2" >"$tmp/$1"
  echo "$tmp/$1"
}

# 1. the family from ID and ID_LIKE.
expect fedora "$(distro_family "$(osr fedora 'ID=fedora')")" fedora
expect rocky "$(distro_family "$(osr rocky 'ID=rocky
ID_LIKE="rhel centos fedora"')")" fedora
expect ubuntu "$(distro_family "$(osr ubuntu 'ID=ubuntu
ID_LIKE=debian')")" debian
expect mint "$(distro_family "$(osr mint 'ID=linuxmint
ID_LIKE="ubuntu debian"')")" debian
expect arch "$(distro_family "$(osr arch 'ID=arch')")" arch
expect manjaro "$(distro_family "$(osr manjaro 'ID=manjaro
ID_LIKE=arch')")" arch
expect unknown "$(distro_family "$(osr unknown 'ID=plan9')")" other
expect absent "$(distro_family "$tmp/no-such-file")" other
expect name "$(distro_name "$(osr named 'ID=arch
PRETTY_NAME="Arch Linux"')")" "Arch Linux"
expect "DESKTOP_OS_RELEASE" "$(DESKTOP_OS_RELEASE=$(osr viaenv 'ID=arch') distro_family)" arch

# 2. the package table.
expect debian-xz "$(family_packages debian xz)" xz-utils
expect arch-cc "$(family_packages arch cc)" base-devel
expect dedupe "$(family_packages debian cc make cmake | tr '\n' ' ')" "build-essential cmake "
expect fedora-no-user-bus "$(family_packages fedora user-bus)" ""
expect debian-user-bus "$(family_packages debian user-bus)" dbus-user-session
contains debian-note "$(family_notes debian xwayland-satellite)" "not in the Ubuntu archive"
expect no-note "$(family_notes arch xwayland-satellite)" ""
# every need in the table has an answer (a package, "-" or a note) on all three families.
while read -r _ key _; do
  for fam in fedora debian arch; do
    [ -n "$("packages_$fam" "$key")" ] || fail "no package answer for $key on $fam"
  done
done < <(need_table)

# 3. the install lines, through a made-up escalation program.
export SUDO=asroot
if [ "$(id -u)" != 0 ]; then
  expect dnf-line "$(install_line fedora gcc make)" "asroot dnf install gcc make "
  expect apt-line "$(install_line debian build-essential)" "asroot apt install build-essential "
  expect pacman-line "$(install_line arch base-devel)" "asroot pacman -S base-devel "
  hint=$(DESKTOP_OS_RELEASE=$(osr hint-u 'ID=ubuntu') install_hint bwrap polkit)
  expect hint-ubuntu "$hint" "asroot apt install bubblewrap polkitd pkexec "
  hint=$(DESKTOP_OS_RELEASE=$(osr hint-x 'ID=plan9') install_hint bwrap)
  contains hint-other-dnf "$hint" "fedora: asroot dnf install bubblewrap"
  contains hint-other-apt "$hint" "debian: asroot apt install bubblewrap"
  contains hint-other-pacman "$hint" "arch: asroot pacman -S bubblewrap"
fi
unset SUDO

# 4. escalation: $SUDO, then sudo, doas, pkexec; none at all prints the command for root.
mkdir -p "$tmp/none" "$tmp/doas" "$tmp/both"
ln -s "$(command -v id)" "$tmp/none/id"
ln -s "$(command -v id)" "$tmp/doas/id"
printf '#!/bin/sh\n' >"$tmp/doas/doas"; chmod +x "$tmp/doas/doas"
cp "$tmp/doas/doas" "$tmp/both/pkexec"
cp "$tmp/doas/doas" "$tmp/both/doas"
expect override "$(SUDO='sudo -n' escalation_program)" "sudo -n"
expect doas "$(PATH=$tmp/doas escalation_program)" doas
expect doas-before-pkexec "$(PATH=$tmp/both escalation_program)" doas
if (PATH=$tmp/none escalation_program >/dev/null); then fail "an escalation program was found on an empty PATH"; fi
if [ "$(id -u)" != 0 ]; then
  expect hint-doas "$(PATH=$tmp/doas as_root_hint systemctl reload x)" "doas systemctl reload x "
  expect hint-none "$(PATH=$tmp/none as_root_hint systemctl reload x)" "as root: systemctl reload x "
  if (PATH=$tmp/none escalate true 2>"$tmp/escalate.err"); then fail "escalate ran with no program"; fi
  contains escalate-says "$(cat "$tmp/escalate.err")" "Run this yourself, as root"
fi

# 5. building from outside the tree: cargo runs from /, names the manifest, gets the tree's pinned toolchain and the
# settings its config gives besides the linker, and never RUSTFLAGS. cargo and rustup are stubs.
# shellcheck source=../install/cargo.sh
source "$INSTALL_DIR/cargo.sh"
mkdir -p "$tmp/cargobin" "$tmp/trees/sill" "$tmp/trees/casement"
printf '#!/bin/sh\necho "cwd=$PWD TC=${RUSTUP_TOOLCHAIN:-} FLAGS=${RUSTFLAGS-unset} TARGET=$CARGO_TARGET_DIR $*"\n' >"$tmp/cargobin/cargo"
printf '#!/bin/sh\nexit 0\n' >"$tmp/cargobin/rustup"
chmod +x "$tmp/cargobin"/*
printf '[toolchain]\nchannel = "1.2.3"\ncomponents = ["rustfmt"]\n' >"$tmp/trees/sill/rust-toolchain.toml"
unset RUSTFLAGS CARGO_TARGET_DIR
expect toolchain "$(tree_toolchain "$tmp/trees/sill")" "1.2.3"
expect no-toolchain "$(tree_toolchain "$tmp/trees/casement")" ""
expect git-config "$(tree_configs "$tmp/trees/sill")" "net.git-fetch-with-cli=true"
expect no-config "$(tree_configs "$tmp/trees/casement")" ""
expect build-outside "$(PATH=$tmp/cargobin:$PATH build_outside "$tmp/trees/sill" -p sill)" \
  "cwd=/ TC=1.2.3 FLAGS=unset TARGET=$tmp/trees/sill/target build --release --locked --manifest-path $tmp/trees/sill/Cargo.toml --config net.git-fetch-with-cli=true -p sill"
expect build-outside-plain "$(CARGO_TARGET_DIR=$tmp/t PATH=$tmp/cargobin:$PATH build_outside "$tmp/trees/casement" -p casement)" \
  "cwd=/ TC= FLAGS=unset TARGET=$tmp/t build --release --locked --manifest-path $tmp/trees/casement/Cargo.toml -p casement"

# 6. the check mode on a made-up machine: an empty PATH of stubs, an empty root, a fake dpkg and ldconfig.
bin="$tmp/machine/bin" root="$tmp/machine/root"
mkdir -p "$bin" "$root"
for tool in grep awk sed tr cat id uname dirname basename mktemp; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
run_machine() { # OS-RELEASE-CONTENT [ARGS]: the check on the machine as it is now; sets machine_out and machine_rc
  local content=$1
  shift
  machine_rc=0
  machine_out=$(PATH=$bin DESKTOP_OS_RELEASE=$(osr machine-os "$content") DESKTOP_CHECK_ROOT=$root \
    DESKTOP_LDCONFIG=$tmp/no-ldconfig SUDO=asroot run_check "$@" 2>&1) || machine_rc=$?
}
printf '#!/bin/sh\nexit 1\n' >"$bin/dpkg"; chmod +x "$bin/dpkg"   # dbus-user-session is not installed
run_machine 'ID=ubuntu
ID_LIKE=debian' --runtime-only
expect bare-rc "$machine_rc" 1
contains bare-bwrap "$machine_out" "missing: bwrap"
contains bare-apt "$machine_out" "apt install"
contains bare-user-bus "$machine_out" "dbus-user-session"
contains bare-vulkan "$machine_out" "libvulkan1"
lacks bare-no-dnf "$machine_out" "dnf install"
run_machine 'ID=arch' --runtime-only
contains arch-pacman "$machine_out" "pacman -S"
contains arch-note "$machine_out" "vulkan-radeon"
run_machine 'ID=fedora'
contains no-rustup "$machine_out" "https://sh.rustup.rs"

# Now give the machine everything the runtime list wants.
for tool in pkexec bwrap curl xdg-open Xwayland gnome-keyring-daemon; do printf '#!/bin/sh\n' >"$bin/$tool"; chmod +x "$bin/$tool"; done
printf '#!/bin/sh\nexit 0\n' >"$bin/dpkg"; chmod +x "$bin/dpkg"
printf '#!/bin/sh\nprintf "\\tlibvulkan.so.1 (libc6,x86-64) => /usr/lib/libvulkan.so.1\\n"\n' >"$tmp/ldconfig"; chmod +x "$tmp/ldconfig"
mkdir -p "$root/usr/libexec" "$root/usr/share/vulkan/icd.d"
for portal in xdg-desktop-portal xdg-desktop-portal-gtk; do : >"$root/usr/libexec/$portal"; done
: >"$root/usr/share/vulkan/icd.d/lvp_icd.json"
machine_rc=0
machine_out=$(PATH=$bin DESKTOP_OS_RELEASE=$(osr machine-os 'ID=ubuntu
ID_LIKE=debian') DESKTOP_CHECK_ROOT=$root DESKTOP_LDCONFIG=$tmp/ldconfig SUDO=asroot run_check --runtime-only 2>&1) || machine_rc=$?
expect full-rc "$machine_rc" 0
contains full-all-there "$machine_out" "all there"
lacks full-nothing-missing "$(printf '%s\n' "$machine_out" | sed -n '/needed to run/,/recommended/p')" "missing:"
echo "distro-check: ok"
