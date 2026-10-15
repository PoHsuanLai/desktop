#!/usr/bin/env bash
# Install the desktop: runs each component repo's own installer, in dependency order.
#
#   ./install.sh [--dry-run] [--prefix DIR] [--destdir DIR] [--sysconfdir DIR] [--siblings DIR] [--only NAME[,NAME]]
#   ./install.sh --check [--runtime-only]
#
#   --dry-run      print the plan (what runs, in which order, what is left to you), run nothing, build nothing
#   --prefix DIR   where the software goes (default $PREFIX, else /usr/local)
#   --destdir DIR  a staging root put in front of every path (default $DESTDIR, else none)
#   --sysconfdir   where porter's caller table goes (default $SYSCONFDIR, else /etc)
#   --siblings DIR where the component repos are checked out side by side (default: the parent of this repo)
#   --check        change nothing: look for what the desktop needs on this machine (Fedora, Ubuntu/Debian, Arch;
#                  the family comes from /etc/os-release) and print the exact dnf, apt or pacman line for what
#                  is missing; exit 1 when something needed is missing. --runtime-only leaves out the build tools
#   --only NAMES   just these components (comma separated: porter, detent, casement, sill, keycap, anyview, mailo,
#                  palmrest, session, fonts)
#
# Order: porter (the account daemons and the caller table), detent (Settings), casement (the compositor and
# its user unit), sill (the shell), keycap, anyview, mailo, palmrest, and last the session itself (this repo's
# install/install.sh: the desktop-session script, the user target and the login entry "sill (casement)"). Each
# component's installer is its
# own: this script passes the prefix and the staging root through and nothing else, and stops at the first
# one that fails. A component whose installer is not in its checkout yet (casement, until its scripts/install.sh
# lands) is reported and skipped; the others carry on.
#
# The colour emoji font (fonts/Noto-COLRv1.ttf) goes to <prefix>/share/fonts/quire/ after the components, unless
# fontconfig already has a COLRv1 Noto Color Emoji (Fedora does; Ubuntu and Arch ship a bitmap build our renderer
# cannot draw). It is the step named "fonts".
#
# porter always goes to /usr, whatever --prefix says: its daemons read the data they ship (providers, the
# client table, the model catalog) only from /usr/share for now.
#
# Builds. The repos pin Rust 1.98.1 and need rustup (a distro's rust package is the wrong version). Some
# repos' cargo config asks for clang and mold; when either is missing the build uses the system linker
# instead (install/linker.sh), and says so.
#
# Root. This script never runs sudo and never writes under ~/.config or /etc itself. A component runs
# here only when everything it writes is writable by you (a user prefix, or a --destdir); the others are
# listed as "yourself" with the exact command, to run with the privileges they need (sudo, doas or
# pkexec, whichever is installed; $SUDO names another):
#   - needs root: the destination is not writable by you (a system prefix, /etc/systemd/user, /etc)
#   - sill, palmrest: installers with fixed destinations that ask for sudo or write your home themselves
#   - keycap: its system files go to /etc and /usr/local; it stages only under --destdir
# Exit: 0 done (or the plan printed), 1 a component failed, 2 bad usage or a missing component.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=install/distro.sh
source "$HERE/install/distro.sh"
# shellcheck source=install/linker.sh
source "$HERE/install/linker.sh"
# shellcheck source=install/packages.sh
source "$HERE/install/packages.sh"
# shellcheck source=install/check.sh
source "$HERE/install/check.sh"
# shellcheck source=install/fonts.sh
source "$HERE/install/fonts.sh"
ORDER=(porter detent casement sill keycap anyview mailo palmrest session)

# Where porter goes, whatever --prefix says. Its daemons look for providers, clients.toml and the stoker
# catalog only under /usr/share (finding B1). Remove this, and the --prefix /usr below, once porter searches
# XDG_DATA_DIRS.
PORTER_PREFIX=/usr

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

# What a component is: its directory, its installer (relative), the command words after the installer, the
# environment it takes, the places it writes, and why it is left to you (empty: it can run here).
dir="" script="" args=() envs=() writes=() yourself="" optional=0

# describe NAME: fills the variables above for one component.
describe() {
  dir="$siblings/$1" args=() envs=() writes=() yourself="" optional=0
  case "$1" in
    porter)
      script=scripts/install.sh
      args=(--prefix "$PORTER_PREFIX" --sysconfdir "$sysconfdir")
      [ -z "$destdir" ] || args+=(--destdir "$destdir")
      writes=("$destdir$PORTER_PREFIX" "$destdir$sysconfdir") ;;
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
    keycap)
      script=install.sh
      envs=("DESTDIR=$destdir")
      writes=("$destdir/etc" "$destdir/usr/local")
      [ -n "$destdir" ] || yourself="its system files go to /etc and /usr/local, which only root writes" ;;
    anyview)
      script=dist/install.sh
      args=(--prefix "$prefix")
      envs=("DESTDIR=$destdir")
      writes=("$destdir$prefix") ;;
    mailo)
      script=dist/install.sh
      envs=("MAILO_PREFIX=$destdir$prefix" "MAILO_UNIT_DIR=$destdir/etc/systemd/user")
      writes=("$destdir$prefix" "$destdir/etc/systemd/user") ;;
    palmrest)
      script=install.sh
      yourself="it installs a user service under your home and prints root commands for the udev rules" ;;
    session)
      # This repo's own session installer (never sudo; it stops with the root command when a place is not writable).
      dir="$HERE"
      script=install/install.sh
      args=(--prefix "$prefix" --sysconfdir "$sysconfdir")
      [ -z "$destdir" ] || args+=(--destdir "$destdir")
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
case " ${selected[*]} " in *" porter "*)
  [ "$prefix" = "$PORTER_PREFIX" ] || echo "note: porter goes to $PORTER_PREFIX, not $prefix: its daemons read what they ship only from $PORTER_PREFIX/share" ;;
esac
command -v rustup >/dev/null || echo "note: rustup was not found. Building from source needs it (the repos pin Rust 1.98.1): $RUSTUP_LINE"
plain_linker_notice
if [ "${#left[@]}" -gt 0 ] && ! faster_linker_present && [ "$(host_arch)" = x86_64 ]; then
  echo "for the ones left to you, build with the system linker too: export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=cc RUSTFLAGS="
fi
[ "$dry" = 0 ] || exit 0

done_list=()
for name in "${run[@]:-}"; do
  [ -n "$name" ] || continue
  describe "$name"
  echo "== $name"
  # detent installs a built binary; build it first when it is not there.
  if [ "$name" = detent ] && [ -z "${DETENT_BIN:-}" ] && [ ! -x "$dir/target/release/detent" ]; then
    (cd "$dir" && { use_plain_linker "$dir" || true; } && cargo build --release --locked) || {
      echo "install.sh: detent failed: its release build. Installed so far: ${done_list[*]:-nothing}. Not run: the rest." >&2
      exit 1
    }
  fi
  status=0
  # The component's own build (if it has one) sees the system linker when clang or mold is missing.
  (cd "$dir" && { use_plain_linker "$dir" || true; } && env "${envs[@]}" "./$script" "${args[@]}") || status=$?
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

echo "installed: ${done_list[*]:-nothing}"
if [ "${#absent[@]}" -gt 0 ]; then
  echo "not installed (no installer in the checkout yet): ${absent[*]}"
fi
if [ "${#left[@]}" -gt 0 ]; then
  echo "left to you (the commands are in the plan above): ${left[*]}"
fi
