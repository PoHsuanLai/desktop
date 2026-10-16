#!/usr/bin/env bash
# The desktop's own system files: the list of its programs, the input service and the keyboard map. Three parts,
# each run on its own by install.sh (it passes the prefix, the staging root and where the checkouts are):
#
#   install/system.sh PART [--dry-run] [--prefix DIR] [--destdir DIR] [--siblings DIR]
#   install/system.sh --remove PART [same flags]
#
#   callers    /etc/quire/desktop-callers.toml, from dist/: which program is the shell, the updater, the portal and so on.
#              The update service and the screen-sharing service read it once, when they start, and refuse everybody
#              without it, so this part comes before anything that installs or starts them. Always replaced (an
#              administrator adds rows in /etc/quire/desktop-callers.d/, which is never touched).
#   turnstile  the input service: its program (built by install.sh as you, from the checkout beside this one), its
#              socket and service in /usr/lib/systemd/system, the device rule that closes /dev/uinput to everybody
#              but it, and the list that loads the kernel module. Then it reloads systemd and the device rules and
#              starts the socket. No part of the desktop gives /dev/uinput to the person or to a group.
#   keycap     the keyboard map: its program (built by install.sh), its service, the rule that lets the person at the
#              keyboard restart it without a password, and /usr/lib/keycap/keycap.toml (dist/keycap.toml: Caps Lock
#              switches the input method), always replaced. That is keycap's vendor file, laid under the administrator's
#              /etc/keycap/keycap.toml, which this never reads, writes or removes. It does not run keycap's own
#              installer, which would give the `input` group the device file and the service a drop-in to open it.
#
# Never runs sudo. A place you cannot write stops it with the command to run as root (through whichever of sudo, doas
# or pkexec this machine has). Under --destdir it only copies files, as you. Safe to run again: a file already in
# place and identical is left alone. --remove takes away what this put in place, each file only while it is still what
# was written, and stops what it started.
#
# Needs from the machine: systemd and udev (all three supported families have both); nothing is installed from a
# package, so there are no apt, dnf or pacman lines. restorecon is used when SELinux is there (Fedora).
# Exit: 0 done, 1 something failed or a place is not writable, 2 bad usage or a missing file.
set -euo pipefail
ORIG_ARGS=("$@")
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

mode=install
if [ "${1:-}" = --remove ]; then mode=remove; shift; fi
part=${1:-}
case "$part" in callers | turnstile | keycap) shift ;; -h | --help) usage; exit 0 ;; *) usage >&2; die "name a part: callers, turnstile or keycap" ;; esac
parse_flags "$@"
DIST="$(cd "$SRC/../dist" && pwd)"
vendor_units=/usr/lib/systemd/system
turnstile_bin=${TURNSTILE_BIN:-$siblings/turnstile/target/release/turnstile}
keycap_bin=${KEYCAP_BIN:-$siblings/keycap/target/release/keycap}

# files: "MODE SOURCE DEST" per line of this part, DEST without the staging root. Programs come first.
files() {
  case "$part" in
    callers)
      echo "644 $DIST/desktop-callers.toml /etc/quire/desktop-callers.toml" ;;
    turnstile)
      echo "755 $turnstile_bin $prefix/bin/turnstile"
      echo "644 $siblings/turnstile/dist/turnstile.socket $vendor_units/turnstile.socket"
      echo "644 $siblings/turnstile/dist/turnstile.service $vendor_units/turnstile.service"
      echo "644 $siblings/turnstile/dist/72-turnstile.rules /etc/udev/rules.d/72-turnstile.rules"
      echo "644 $siblings/turnstile/dist/turnstile-modules.conf /etc/modules-load.d/turnstile.conf" ;;
    keycap)
      echo "755 $keycap_bin $prefix/bin/keycap"
      echo "644 $siblings/keycap/dist/keycap.service $vendor_units/keycap.service"
      echo "644 $siblings/keycap/dist/keycap.polkit.rules /etc/polkit-1/rules.d/keycap.polkit.rules"
      echo "644 $DIST/keycap.toml /usr/lib/keycap/keycap.toml" ;;
  esac
}

# content SOURCE: what is installed from SOURCE: a service names the program where this install put it.
content() {
  case "$1" in
    */turnstile.service) sed -E "s|^ExecStart=[^ ]*|ExecStart=$prefix/bin/turnstile|" "$1" ;;
    */keycap.service) sed -E "s|^ExecStart=[^ ]*|ExecStart=$prefix/bin/keycap|" "$1" ;;
    *) cat "$1" ;;
  esac
}

# put MODE SOURCE DEST: DEST (under the staging root) holds SOURCE's content with MODE, owned by root when we are root. The
# file is written beside DEST and renamed over it, so a reader never sees half of it.
put() {
  local mode=$1 source=$2 dest=$destdir$3 owner=() staged
  if [ "$(id -u)" = 0 ]; then owner=(-o root -g root); fi
  if [ -f "$dest" ] && content "$source" | cmp -s - "$dest" && [ "$(stat -c %a "$dest")" = "$mode" ] \
    && { [ "$(id -u)" != 0 ] || [ "$(stat -c %U:%G "$dest")" = root:root ]; }; then
    note "already in place: $dest"
    return 0
  fi
  note "$dest ($mode)"
  [ "$dry" = 0 ] || return 0
  install -d -m 755 "${owner[@]}" "$(dirname "$dest")"
  staged=$dest.new.$$
  content "$source" | install -m "$mode" "${owner[@]}" /dev/stdin "$staged"
  mv -f "$staged" "$dest"
  changed=1
}
changed=0

# Live: really changing this machine (not a staging root, not a dry run).
live() { [ -z "$destdir" ] && [ "$dry" = 0 ]; }
systemd_running() { [ -d /run/systemd/system ]; }

# run DESCRIPTION CMD...: one step on the machine, said first. A failure is told and does not stop the rest.
run() {
  local what=$1; shift
  note "$what"
  note "    \$ $*"
  "$@" || note "that did not work; run it again by hand: $*"
}

settle() { # the units, the device rules and the kernel module take effect; $1 the unit to start
  if ! live; then note "staged or dry run: nothing is reloaded or started"; return 0; fi
  if [ "$(id -u)" != 0 ]; then return 0; fi
  if command -v restorecon >/dev/null 2>&1; then
    while read -r _ _ dest; do restorecon -F "$dest" 2>/dev/null || true; done < <(files)
  fi
  if ! systemd_running; then note "systemd is not running here: start $1 yourself when it is"; return 0; fi
  run "tell systemd about the new files" systemctl daemon-reload
  case "$part" in
    turnstile)
      run "load the kernel module for virtual input devices now (it loads at every start of the computer anyway)" modprobe uinput
      run "apply the device rules" udevadm control --reload-rules
      run "close /dev/uinput to everybody but the input service" udevadm trigger --subsystem-match=misc
      run "turn the input service on (it starts when something asks for it)" systemctl enable --now turnstile.socket ;;
    keycap)
      # `enable --now` leaves a running service as it is, so a new program or service file needs a restart.
      if [ "$changed" = 1 ] && systemctl is-active --quiet keycap.service; then
        run "a new keyboard map: restart it so it runs (it waits until no key is held)" systemctl restart keycap.service
      else
        run "turn the keyboard map on" systemctl enable --now keycap.service
      fi ;;
  esac
}

install_part() {
  local source
  case "$part" in
    callers) step "the list of the desktop's own programs (/etc/quire/desktop-callers.toml)"
      note "The update service, the screen-sharing service and the input service read it when they start, and refuse"
      note "everybody without it. Rows an administrator adds go in /etc/quire/desktop-callers.d/."
      if [ -d "$destdir/etc/quire" ] && [ -n "$(find "$destdir/etc/quire" -maxdepth 0 -perm /022)" ]; then
        die "$destdir/etc/quire can be written by someone other than root; the services refuse a list in such a folder. Fix it first: chmod go-w /etc/quire" 1
      fi ;;
    turnstile) step "the input service (virtual keyboards and pads for keycap and palmrest, and nobody else)" ;;
    keycap) step "the keyboard map (keycap)" ;;
  esac
  while read -r _ source _; do
    [ -f "$source" ] || {
      case "$source" in
        */bin/*) die "$source is not there: build it first, as yourself (install.sh does: ./install.sh --only $part)" 2 ;;
        *) die "$source is not there: keep the checkout beside this one or pass --siblings" 2 ;;
      esac
    }
  done < <(files)
  local dests=()
  while read -r _ _ dest; do dests+=("$dest"); done < <(files)
  need_write "${dests[@]}"
  while read -r fmode source dest; do put "$fmode" "$source" "$dest"; done < <(files)
  if [ "$part" = keycap ]; then
    note "Caps Lock switches the input method (/usr/lib/keycap/keycap.toml). /etc/keycap/keycap.toml is yours and is not touched: rules you put there win."
    # An earlier, stand-alone install of keycap left things that undo the desktop's choices.
    if [ -z "$destdir" ] && [ -e /etc/systemd/system/keycap.service ]; then
      note "WARNING: /etc/systemd/system/keycap.service from an earlier install hides the one just placed; remove it, then run: systemctl daemon-reload"
    fi
    if [ -z "$destdir" ] && [ -e /etc/systemd/system/keycap.service.d/10-uinput.conf ]; then
      note "WARNING: /etc/systemd/system/keycap.service.d/10-uinput.conf lets the keyboard map open /dev/uinput itself; remove it, the input service makes the devices now"
    fi
    if [ -z "$destdir" ] && [ -e /etc/udev/rules.d/70-keycap.rules ] && grep -q uinput /etc/udev/rules.d/70-keycap.rules; then
      note "WARNING: /etc/udev/rules.d/70-keycap.rules gives a group the device file; the input service's rule (72) overrides it, but remove it all the same"
    fi
  fi
  if [ "$part" = callers ]; then
    note "Services that were already running keep what they read at their start: log out and in (or restart them) to use the new list."
  fi
  case "$part" in
    turnstile) settle turnstile.socket ;;
    keycap) settle keycap.service ;;
  esac
  step "done"
}

remove_part() {
  local fmode source dest present=()
  step "removing the $part files this install put in place"
  while read -r fmode source dest; do
    [ -e "$destdir$dest" ] && present+=("$dest")
    : "$fmode"
  done < <(files)
  [ "${#present[@]}" = 0 ] || need_write "${present[@]}"
  if live && [ "$(id -u)" = 0 ] && systemd_running; then
    case "$part" in
      turnstile) run "stop the input service" systemctl disable --now turnstile.socket turnstile.service ;;
      keycap) run "stop the keyboard map (the keyboards go back to the system)" systemctl disable --now keycap.service ;;
    esac
  fi
  while read -r fmode source dest; do
    if [ ! -e "$destdir$dest" ]; then note "absent: $destdir$dest"
    elif [ ! -f "$source" ]; then note "kept (its source $source is not here to compare with): $destdir$dest"
    elif content "$source" | cmp -s - "$destdir$dest"; then
      note "remove: $destdir$dest"
      [ "$dry" = 1 ] || rm -f -- "$destdir$dest"
    else note "kept (not what the installer wrote): $destdir$dest"
    fi
    : "$fmode"
  done < <(files)
  if live && [ "$(id -u)" = 0 ] && systemd_running; then
    run "tell systemd the files are gone" systemctl daemon-reload
    [ "$part" != turnstile ] || run "apply the device rules" udevadm control --reload-rules
    [ "$part" != turnstile ] || run "give /dev/uinput back to the system's own rules" udevadm trigger --subsystem-match=misc
  fi
  step "done"
}

[ "$dry" = 0 ] || echo "dry run: nothing below is executed"
if [ "$mode" = remove ]; then remove_part; else install_part; fi
