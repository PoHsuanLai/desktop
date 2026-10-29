#!/usr/bin/env bash
# Install the desktop: runs each component repo's own installer, in dependency order.
#
#   ./install.sh [--dry-run] [--prefix DIR] [--destdir DIR] [--sysconfdir DIR] [--siblings DIR] [--only NAME[,NAME]]
#   ./install.sh --check [--runtime-only]
#
#   --dry-run      print the plan (what runs, in which order, what is left to you), run nothing, build nothing
#   --prefix DIR   where the software goes (default $PREFIX, else /usr/local)
#   --destdir DIR  a staging root put in front of every path (default $DESTDIR, else none)
#   --sysconfdir   where porter's and steward's caller tables go (default $SYSCONFDIR, else /etc); almanac, docket and cua always use /etc/quire; stoker writes nothing there
#   --siblings DIR where the component repos are checked out side by side (default: the parent of this repo)
#   --check        change nothing: look for what the desktop needs on this machine (Fedora, Ubuntu/Debian, Arch;
#                  the family comes from /etc/os-release) and print the exact dnf, apt or pacman line for what
#                  is missing; exit 1 when something needed is missing. --runtime-only leaves out the build tools
#   --only NAMES   just these components (comma separated: callers, porter, steward, stoker, almanac, docket, cua, detent, casement, sill,
#                  transom, turnstile, keycap, anyview, mailo, files, palmrest, session, fonts)
#
# Order: callers (the list of the desktop's own programs, /etc/quire/desktop-callers.toml, this repo's dist/), porter (the account daemons and the caller table), steward (inferd, the AI broker, and its caller table), stoker (the model catalogue inferd reads), almanac (the memory daemon and its caller table),
# docket (the action router, the companion, the reader and the tool server, with their caller tables; they read
# porter's accounts), cua (the computer-use daemon cuad, for apps that are not ours, and its caller table), detent (Settings), casement (the compositor and
# its user unit), sill (the shell), transom (the portal backend: screen sharing, screenshots; its
# scripts/install.sh builds it), turnstile (the input service that makes virtual keyboards and pads, from install/system.sh), keycap (the
# keyboard map, also from install/system.sh), anyview, mailo, files (the file manager), palmrest (the touchpad service, also from install/system.sh), and last the session itself (this repo's
# install/install.sh: the desktop-session script, the user target and the login entry "sill (casement)"). Each
# component's installer is its
# own: this script passes the prefix and the staging root through and nothing else, and stops at the first
# one that fails. "callers" is first on purpose: the update service (slipway) and the portal backend (transom) read the
# list once, when they start, and refuse every caller without it, so it is in place before anything that installs or starts
# them. turnstile comes before keycap and palmrest, which ask it for their virtual devices. A component whose installer is not in its checkout yet (casement, until its scripts/install.sh
# lands) is reported and skipped; the others carry on.
#
# The colour emoji font (fonts/Noto-COLRv1.ttf) goes to <prefix>/share/fonts/quire/ after the components, unless
# fontconfig already has a COLRv1 Noto Color Emoji (Fedora does; Ubuntu and Arch ship a bitmap build our renderer
# cannot draw). It is the step named "fonts".
#
# palmrest is a system service like keycap and is installed the same way (install/system.sh palmrest), not by its own
# installer: the program, its service in /usr/lib/systemd/system, the rule that gives the mouse's raw node to the `input`
# group and the module options. It runs as a dynamic user, not as you, and not in your session.
#
# keycap is not installed by keycap's own installer: that one gives the `input` group the device file /dev/uinput and the service a
# drop-in to open it, which the desktop closes (the input service owns the node). install/system.sh puts the program, the service,
# the restart rule and /usr/lib/keycap/keycap.toml (Caps Lock; keycap's vendor file, under the administrator's
# /etc/keycap/keycap.toml, which is never touched) instead.
#
# Builds. The repos pin Rust 1.98.1 and need rustup (a distro's rust package is the wrong version). Some
# repos' cargo config asks for clang and mold, which is how they are worked on. An install never reads it
# and never asks for a linker: what this script builds itself (detent, turnstile, keycap, palmrest) runs from / with --manifest-path
# (install/cargo.sh), and each component's own installer does the same for its own build.
#
# Root. This script never runs sudo and never writes under ~/.config or /etc itself. A component runs
# here only when everything it writes is writable by you (a user prefix, or a --destdir); the others are
# listed as "yourself" with the exact command, to run with the privileges they need (sudo, doas or
# pkexec, whichever is installed; $SUDO names another):
#   - needs root: the destination is not writable by you (a system prefix, /etc/systemd/user, /etc)
#   - sill: an installer with fixed destinations that asks for sudo or writes your home itself
#   - callers, turnstile, keycap, palmrest: install/system.sh puts files in /etc, /usr/lib/systemd/system and /usr/local; it never runs sudo
#     itself, so outside a --destdir the root command is printed
#     turnstile and keycap are started as root, and palmrest is believed by the input service for being a root-owned file, so their
#     programs go only where root alone can replace them: when --prefix has a folder the person owns or can write (~/.local), these
#     three go under /usr/local instead and the plan says so; install/system.sh refuses such a prefix on its own (re-audit NEW-ROOT-1)
#   - stoker: the catalogue goes under the prefix; its installer asks for sudo, doas or pkexec itself for a system
#     prefix, so outside a --destdir it is left to you, run as yourself
#   - mailo: the binary under the prefix and its unit in /etc/systemd/user; its installer refuses to run as root
#     and asks for sudo itself, so outside a --destdir it is left to you, run as yourself (never under sudo)
#   - files: the binary, the desktop entry, the two bus services (its own and the desktop's file-manager name) and the intents
#     under the prefix; its installer refuses to run as root and asks for sudo itself for a place you do not own, so outside a
#     --destdir it is left to you, run as yourself (never under sudo)
#   - almanac, docket, cua: their caller tables go to /etc/quire (always replaced) and docket's default settings to
#     /etc/xdg/quire. Their installers refuse to run as root and ask for sudo, doas or pkexec themselves for
#     just those steps, so outside a --destdir they are left to you, run as yourself (never under sudo)
# Exit: 0 done (or the plan printed), 1 a component failed, 2 bad usage or a missing component.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=install/distro.sh
source "$HERE/install/distro.sh"
# shellcheck source=install/cargo.sh
source "$HERE/install/cargo.sh"
# shellcheck source=install/packages.sh
source "$HERE/install/packages.sh"
# shellcheck source=install/rootheld.sh
source "$HERE/install/rootheld.sh"
# shellcheck source=install/check.sh
source "$HERE/install/check.sh"
# shellcheck source=install/fonts.sh
source "$HERE/install/fonts.sh"
ORDER=(callers porter steward stoker almanac docket cua detent casement sill transom turnstile keycap anyview mailo files palmrest session)

prefix=${PREFIX:-/usr/local}
destdir=${DESTDIR:-}
sysconfdir=${SYSCONFDIR:-/etc}
siblings="$(dirname "$HERE")"
only=""
dry=0
check=0
check_args=()

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "install.sh: $*" >&2; exit "${2:-2}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --check) check=1 ;;
    --runtime-only) check_args+=(--runtime-only) ;;
    --prefix) prefix=${2:?--prefix needs a directory}; shift ;;
    --prefix=*) prefix=${1#--prefix=} ;;
    --destdir) destdir=${2:?--destdir needs a directory}; shift ;;
    --destdir=*) destdir=${1#--destdir=} ;;
    --sysconfdir) sysconfdir=${2:?--sysconfdir needs a directory}; shift ;;
    --sysconfdir=*) sysconfdir=${1#--sysconfdir=} ;;
    --siblings) siblings=${2:?--siblings needs a directory}; shift ;;
    --siblings=*) siblings=${1#--siblings=} ;;
    --only) only=${2:?--only needs names}; shift ;;
    --only=*) only=${1#--only=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument $1" ;;
  esac
  shift
done
if [ "$check" = 1 ]; then
  run_check "${check_args[@]}"
  exit $?
fi
[ "${#check_args[@]}" = 0 ] || die "--runtime-only goes with --check"
case "$prefix" in /*) ;; *) die "--prefix must be an absolute path" ;; esac
destdir=${destdir%/}
prefix=${prefix%/}

# root_prefix: where a program that root runs, or that the input service believes for being root's file, goes (turnstile, keycap,
# palmrest). Anyone who can replace the program could run their own code in its place: the prefix is used only when every
# folder up to / is root's alone (a staging root is the packager's to hold, so it is not checked). Otherwise (--prefix
# ~/.local, say) it is /usr/local, the release's place.
root_prefix() {
  if [ -n "$destdir" ] || ! not_root_held "$prefix/bin" >/dev/null; then printf '%s' "$prefix"; else printf '%s' /usr/local; fi
}

# What a component is: its directory, its installer (relative), the command words after the installer, the
# environment it takes, the places it writes, and why it is left to you (empty: it can run here).
dir="" script="" args=() envs=() writes=() yourself="" optional=0 blurb=""

# describe NAME: fills the variables above for one component.
describe() {
  dir="$siblings/$1" args=() envs=() writes=() yourself="" optional=0 blurb=""
  case "$1" in
    callers)
      # The list of the desktop's own programs, a file of this repo (dist/desktop-callers.toml), placed at the fixed
      # /etc/quire/desktop-callers.toml, root-owned. First on purpose (see the header).
      dir="$HERE"
      script=install/system.sh
      blurb="the list of the desktop's own programs (/etc/quire/desktop-callers.toml): the update service and the screen-sharing service refuse everybody without it, so it goes in first"
      args=(callers)
      [ -z "$destdir" ] || args+=(--destdir "$destdir")
      writes=("$destdir/etc/quire") ;;
    porter)
      script=scripts/install.sh
      args=(--prefix "$prefix" --sysconfdir "$sysconfdir")
      [ -z "$destdir" ] || args+=(--destdir "$destdir")
      writes=("$destdir$prefix" "$destdir$sysconfdir") ;;
    steward)
      # inferd, the AI broker, its unit and its caller table (<sysconfdir>/porter/inferd-callers.toml). Same shape as porter's.
      script=scripts/install.sh
      args=(--prefix "$prefix" --sysconfdir "$sysconfdir")
      [ -z "$destdir" ] || args+=(--destdir "$destdir")
      writes=("$destdir$prefix" "$destdir$sysconfdir") ;;
    stoker)
      # The model catalogue (<prefix>/share/stoker/catalog), which inferd reads from the first XDG_DATA_DIRS entry that has it.
      # Nothing to build. Its installer takes --sysconfdir but writes nothing under it for the catalogue.
      script=scripts/install.sh
      args=(--prefix "$prefix" --sysconfdir "$sysconfdir")
      [ -z "$destdir" ] || args+=(--destdir "$destdir")
      writes=("$destdir$prefix")
      [ -n "$destdir" ] || yourself="its installer asks for sudo, doas or pkexec itself for a system prefix; run it as yourself" ;;
    almanac)
      # memoryd and /etc/quire/memory-callers.toml. The installer has no --sysconfdir: /etc/quire is fixed.
      script=scripts/install.sh
      args=(--prefix "$prefix")
      [ -z "$destdir" ] || args+=(--destdir "$destdir")
      writes=("$destdir$prefix" "$destdir/etc/quire")
      [ -n "$destdir" ] || yourself="its caller table goes to /etc/quire; its installer asks for sudo itself and must not be run as root" ;;
    docket)
      # the daemons, quire-do and /etc/quire/*-callers.toml (fixed, like almanac's), defaults in /etc/xdg/quire.
      script=scripts/install.sh
      args=(--prefix "$prefix")
      [ -z "$destdir" ] || args+=(--destdir "$destdir")
      writes=("$destdir$prefix" "$destdir/etc/quire" "$destdir/etc/xdg/quire")
      [ -n "$destdir" ] || yourself="its caller tables go to /etc/quire; its installer asks for sudo itself and must not be run as root" ;;
    cua)
      # cuad (<prefix>/libexec/quire), its unit, the D-Bus activation files, the Settings schema and
      # /etc/quire/cuad-callers.toml (fixed, like almanac's: cuad reads that path only). Needs at-spi2-core at run time
      # (its installer prints a note when that is missing).
      script=scripts/install.sh
      args=(--prefix "$prefix")
      [ -z "$destdir" ] || args+=(--destdir "$destdir")
      writes=("$destdir$prefix" "$destdir/etc/quire")
      [ -n "$destdir" ] || yourself="its caller table goes to /etc/quire; its installer asks for sudo itself and must not be run as root" ;;
    detent)
      script=scripts/install.sh
      envs=("PREFIX=$prefix" "DESTDIR=$destdir")
      writes=("$destdir$prefix") ;;
    casement)
      script=scripts/install.sh
      optional=1
      args=(--prefix "$prefix" --locked)
      [ -z "$destdir" ] || args+=(--destdir "$destdir")
      writes=("$destdir$prefix") ;;
    sill)
      script=dist/install.sh
      yourself="its installer has fixed destinations (/usr/local, /etc, /usr/share) and asks for sudo" ;;
    transom)
      script=scripts/install.sh
      args=(--prefix "$prefix")
      [ -z "$destdir" ] || args+=(--destdir "$destdir")
      writes=("$destdir$prefix") ;;
    turnstile)
      # The input service: its program (built here, as you), socket and service, the rule that closes /dev/uinput, the module list.
      dir="$HERE"
      script=install/system.sh
      blurb="the input service: it alone makes virtual keyboards and pads, for the keyboard map and the touchpad program, and /dev/uinput is closed to everybody else"
      args=(turnstile --prefix "$(root_prefix)")
      [ -z "$destdir" ] || args+=(--destdir "$destdir")
      args+=(--siblings "$siblings")
      writes=("$destdir$(root_prefix)" "$destdir/usr/lib/systemd/system" "$destdir/etc/udev/rules.d" "$destdir/etc/modules-load.d") ;;
    keycap)
      # The keyboard map, installed by install/system.sh and not by keycap's own installer (see the header).
      dir="$HERE"
      script=install/system.sh
      blurb="the keyboard map: its program and service, the rule that lets you restart it, and /usr/lib/keycap/keycap.toml (Caps Lock switches the input method)"
      args=(keycap --prefix "$(root_prefix)")
      [ -z "$destdir" ] || args+=(--destdir "$destdir")
      args+=(--siblings "$siblings")
      writes=("$destdir$(root_prefix)" "$destdir/usr/lib/systemd/system" "$destdir/etc/polkit-1/rules.d" "$destdir/usr/lib/keycap") ;;
    anyview)
      script=dist/install.sh
      args=(--prefix "$prefix")
      envs=("DESTDIR=$destdir")
      writes=("$destdir$prefix") ;;
    mailo)
      script=dist/install.sh
      envs=("MAILO_PREFIX=$destdir$prefix" "MAILO_UNIT_DIR=$destdir/etc/systemd/user")
      writes=("$destdir$prefix" "$destdir/etc/systemd/user")
      [ -n "$destdir" ] || yourself="its installer builds as you, refuses to run as root and asks for sudo itself; run it as yourself" ;;
    files)
      script=dist/install.sh
      envs=("FILES_PREFIX=$prefix" "FILES_DESTDIR=$destdir")
      writes=("$destdir$prefix")
      [ -n "$destdir" ] || yourself="its installer builds as you, refuses to run as root and asks for sudo itself; run it as yourself" ;;
    palmrest)
      # The touchpad service, installed by install/system.sh and not by palmrest's own installer (see the header).
      dir="$HERE"
      script=install/system.sh
      blurb="the touchpad service: Magic Mouse scrolling and gestures, a system service like the keyboard map, with the rule that gives the mouse's raw node to the input group; it serves only the person at the seat"
      args=(palmrest --prefix "$(root_prefix)")
      [ -z "$destdir" ] || args+=(--destdir "$destdir")
      args+=(--siblings "$siblings")
      writes=("$destdir$(root_prefix)" "$destdir/usr/lib/systemd/system" "$destdir/etc/udev/rules.d" "$destdir/etc/modprobe.d") ;;
    session)
      # This repo's own session installer (never sudo; it stops with the root command when a place is not writable).
      dir="$HERE"
      script=install/install.sh
      # It also puts casement.service and sill.service, root-held, in <sysconfdir>/systemd/user, from the checkouts in --siblings.
      args=(--prefix "$prefix" --sysconfdir "$sysconfdir")
      [ -z "$destdir" ] || args+=(--destdir "$destdir")
      args+=(--siblings "$siblings")
      writes=("$destdir$prefix" "$destdir$sysconfdir" "$destdir/usr/share/wayland-sessions") ;;
    *) die "no component named $1 (known: ${ORDER[*]})" ;;
  esac
}

# writable PATH: PATH, or its nearest existing parent, is writable by this user.
writable() {
  local p=$1
  while [ ! -e "$p" ] && [ "$p" != / ]; do p=$(dirname "$p"); done
  [ -w "$p" ]
}

# needs_root_for PATH: PATH when this user cannot write it (or create it), else nothing.
needs_root_for() { if writable "$1"; then :; else printf '%s' "$1"; fi; }

# needs_root: the first place the component writes that this user cannot (empty when all are writable).
needs_root() {
  local w
  for w in "${writes[@]}"; do
    writable "$w" || { printf '%s' "$w"; return 0; }
  done
}

# command_text: the component's command as a person would type it.
command_text() {
  local words=() e
  for e in "${envs[@]}"; do
    case "$e" in *=) ;; *) words+=("$e") ;; esac
  done
  words+=("$dir/$script" "${args[@]}")
  printf '%q ' "${words[@]}"
}

# root_command_text: the same command run as root, through the escalation program this machine has
# (install/distro.sh); the variables go through env, which sudo, doas and pkexec all take.
root_command_text() {
  local words=() e
  for e in "${envs[@]}"; do
    case "$e" in *=) ;; *) words+=("$e") ;; esac
  done
  words+=("$dir/$script" "${args[@]}")
  if [ "${#words[@]}" -gt $((1 + ${#args[@]})) ]; then as_root_hint env "${words[@]}"; else as_root_hint "${words[@]}"; fi
}

# Which components, in order. "fonts" is the emoji font step, not a component.
selected=()
fonts_wanted=1
if [ -n "$only" ]; then
  case ",$only," in *",fonts,"*) ;; *) fonts_wanted=0 ;; esac
fi
for name in "${ORDER[@]}"; do
  if [ -n "$only" ]; then
    case ",$only," in *",$name,"*) ;; *) continue ;; esac
  fi
  selected+=("$name")
done
if [ -n "$only" ]; then
  for name in ${only//,/ }; do
    case " ${ORDER[*]} fonts " in *" $name "*) ;; *) die "no component named $name (known: ${ORDER[*]} fonts)" ;; esac
  done
fi
[ "${#selected[@]}" -gt 0 ] || [ "$fonts_wanted" = 1 ] || die "nothing selected"

# Plan: decide each component's fate before anything runs.
run=() left=() reasons=() absent=()
for name in "${selected[@]}"; do
  describe "$name"
  if [ ! -x "$dir/$script" ]; then
    [ "$optional" = 1 ] || die "$name: no installer at $dir/$script (--siblings says where the repos are)"
    absent+=("$name")
    continue
  fi
  if [ -n "$yourself" ]; then
    left+=("$name"); reasons+=("$yourself")
  elif root=$(needs_root) && [ -n "$root" ]; then
    left+=("$name"); reasons+=("needs root: $root is not writable by you")
  else
    run+=("$name")
  fi
done

echo "desktop install to ${destdir:+$destdir (staged) }$prefix, $([ "$dry" = 1 ] && echo 'dry run: nothing is executed' || echo 'for real')"
step=0
for name in "${selected[@]}"; do
  describe "$name"
  step=$((step + 1))
  case " ${absent[*]:-} " in
    *" $name "*)
      printf '%d. %-8s skipped (no installer at %s yet; until it lands, put the program and its unit in place another way)\n' \
        "$step" "$name" "$dir/$script"
      continue ;;
  esac
  case " ${run[*]:-} " in
    *" $name "*) printf '%d. %-8s runs   %s\n' "$step" "$name" "$(command_text)" ;;
    *)
      for i in "${!left[@]}"; do [ "${left[$i]}" = "$name" ] && why=${reasons[$i]}; done
      printf '%d. %-8s yourself (%s)\n' "$step" "$name" "$why"
      case "$why" in
        "needs root"*) printf '             cd %q && %s\n' "$dir" "$(root_command_text)" ;;
        *) printf '             cd %q && %s\n' "$dir" "$(command_text)" ;;
      esac ;;
  esac
  [ -z "$blurb" ] || printf '             %s\n' "$blurb"
  case "$name" in
    turnstile | keycap | palmrest)
      [ "$(root_prefix)" = "$prefix" ] || printf '             note: %s runs as root, so its program goes under %s, not %s (a folder you can write would let you replace it)\n' \
        "$name" "$(root_prefix)" "$prefix" ;;
  esac
done
fonts_state=skipped fonts_root=""
if [ "$fonts_wanted" = 1 ]; then
  if [ ! -f "$(emoji_font_src)/Noto-COLRv1.ttf" ]; then
    echo "fonts: no $(emoji_font_src)/Noto-COLRv1.ttf in this checkout; colour emoji will be missing unless the system has a COLRv1 font"
  else
    fonts_state=$(emoji_font_state)
    case "$fonts_state" in
      installed) echo "fonts: the colour emoji font is already in $destdir$(emoji_font_dir)" ;;
      present) echo "fonts: fontconfig already has a COLRv1 Noto Color Emoji; nothing to install" ;;
      wanted)
        if fonts_root=$(needs_root_for "$destdir$(emoji_font_dir)") && [ -n "$fonts_root" ]; then
          fonts_state=yourself
          left+=("fonts"); reasons+=("needs root: $fonts_root is not writable by you")
          echo "fonts: colour emoji font, yourself (needs root: $fonts_root is not writable by you):"
          emoji_font_commands | sed 's/^/             /'
        else
          echo "fonts: runs   colour emoji font to $destdir$(emoji_font_dir)"
        fi
        case "$prefix" in /usr | /usr/local) ;; *) echo "note: fontconfig does not look under $prefix/share/fonts; add $(emoji_font_dir) to its font directories" ;; esac ;;
    esac
  fi
fi
# A prefix other than /usr and /usr/local is on no search path the session has: the D-Bus service files and the data
# porter, stoker and the rest ship are read from XDG_DATA_DIRS, and systemd's user manager reads units from
# /usr/lib, /usr/local/lib and XDG_DATA_DIRS/systemd/user, never <prefix>/lib/systemd/user. Printed, never written.
case "$prefix" in
  /usr | /usr/local) ;;
  *)
    echo "note: $prefix is not on the session's search paths, so what is installed under it is found only if you tell the session:"
    echo "        data and background services: put its share folder in the user manager's XDG_DATA_DIRS, e.g. one line in ~/.config/environment.d/50-quire.conf, then log in again:"
    echo "          XDG_DATA_DIRS=$prefix/share:/usr/local/share:/usr/share"
    echo "        user units: systemd's user manager does not read $prefix/lib/systemd/user at all; link them where it does, as root:"
    echo "          mkdir -p /usr/local/lib/systemd/user && ln -sf $prefix/lib/systemd/user/* /usr/local/lib/systemd/user/" ;;
esac
command -v rustup >/dev/null || echo "note: rustup was not found. Building from source needs it (the repos pin Rust 1.98.1): $RUSTUP_LINE"
[ "$dry" = 0 ] || exit 0

# build_if_needed NAME: for a component this script builds itself, as you (detent, turnstile, keycap, palmrest): build its program when it
# is not there, so the component's installer, which only copies, has it. Anything else: nothing to do. $DETENT_BIN, $TURNSTILE_BIN,
# $KEYCAP_BIN and $PALMREST_BIN name a program built elsewhere. The input service is built with no feature at all (its `fake` is for tests).
build_if_needed() {
  local name=$1 tree="$siblings/$1" var args=()
  case "$name" in
    detent) var=DETENT_BIN ;;
    turnstile) var=TURNSTILE_BIN; args=(-p turnstile) ;;
    keycap) var=KEYCAP_BIN ;;
    palmrest) var=PALMREST_BIN ;;
    *) return 0 ;;
  esac
  [ -z "${!var:-}" ] || return 0
  [ ! -x "$tree/target/release/$name" ] || return 0
  echo "== building $name, as yourself"
  build_outside "$tree" ${args[@]+"${args[@]}"}
}

done_list=()
for name in "${run[@]:-}"; do
  [ -n "$name" ] || continue
  describe "$name"
  echo "== $name"
  # These install a built program; build it first when it is not there.
  build_if_needed "$name" || {
    echo "install.sh: $name failed: its release build. Installed so far: ${done_list[*]:-nothing}. Not run: the rest." >&2
    exit 1
  }
  status=0
  (cd "$dir" && env "${envs[@]}" "./$script" "${args[@]}") || status=$?
  if [ "$status" != 0 ]; then
    echo "install.sh: $name failed (exit $status): $(command_text)" >&2
    echo "install.sh: installed so far: ${done_list[*]:-nothing}. Not run: everything after $name. Fix it and run this again (installers are safe to repeat)." >&2
    exit 1
  fi
  done_list+=("$name")
done

if [ "$fonts_state" = wanted ]; then
  echo "== fonts"
  install_emoji_font || { echo "install.sh: the colour emoji font was not installed. Installed so far: ${done_list[*]:-nothing}." >&2; exit 1; }
  done_list+=(fonts)
fi

# What is left to you may need a program built as yourself first (root must not run the compiler); build it now so the
# commands printed above work as they stand.
for name in "${left[@]:-}"; do
  [ -n "$name" ] && [ "$name" != fonts ] || continue
  build_if_needed "$name" || {
    echo "install.sh: $name: its release build failed; the command printed above needs the program. Installed so far: ${done_list[*]:-nothing}." >&2
    exit 1
  }
done

echo "installed: ${done_list[*]:-nothing}"
if [ "${#absent[@]}" -gt 0 ]; then
  echo "not installed (no installer in the checkout yet): ${absent[*]}"
fi
if [ "${#left[@]}" -gt 0 ]; then
  echo "left to you (the commands are in the plan above): ${left[*]}"
fi
