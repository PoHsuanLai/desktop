#!/usr/bin/env bash
# The jail's self-test (plan §4.14).
#
#   selftest.sh           run inside the jail: every check must hold; exit 0, else 1
#   selftest.sh --all     the full proof, run from outside: the checks inside a jail with two
#                         fabricated GPUs, then the negative check
#   selftest.sh --negative  run the checks OUTSIDE the jail and require that they fail
#
# Inside: /dev/input, /dev/dri, /dev/uinput, wayland-0 and the system bus are absent; udmabuf is
# present; the filesystem is read-only apart from scratch; there is no network; HOME and the XDG
# dirs are scratch; a private bus works; fabricated GPU nodes (when asked) are the only ones in
# /sys/dev/char. Checks only stat paths, so running it outside the jail opens no device either.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/all.sh
source "$HERE/lib/all.sh"
UID_=$(id -u)
FAILS=0

check() { # NAME CMD...
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then echo "ok   $name"; else echo "FAIL $name"; FAILS=$((FAILS + 1)); fi
}
absent() { [ ! -e "$1" ]; }
writable() { : >"$1/.selftest.$$" && rm -f "$1/.selftest.$$"; }
read_only() { ! writable "$1"; }
only_loopback() { [ "$(awk -F'[: ]+' 'NR > 2 { print $2 }' /proc/net/dev | grep -vxc lo)" = 0 ]; }
under_scratch() { case "$1" in "${JAIL_SCRATCH:-/nonexistent}"/*) return 0 ;; *) return 1 ;; esac; }

fabricated_gpus_exact() { # N: exactly the fabricated nodes 226:200.. exist, each with device/drm
  local n=$1 i
  [ "$(find /sys/dev/char -mindepth 1 -maxdepth 1 | wc -l)" = "$n" ] || return 1
  for ((i = 0; i < n; i++)); do [ -d "/sys/dev/char/226:$((200 + i))/device/drm" ] || return 1; done
}

private_bus_works() {
  ( private_bus_start && trap private_bus_stop EXIT \
    && [ "$DBUS_SESSION_BUS_ADDRESS" = "$DBUS_SYSTEM_BUS_ADDRESS" ] \
    && case "$DBUS_SESSION_BUS_ADDRESS" in unix:path=/tmp/*|unix:*/tmp/*) true ;; *) false ;; esac )
}

egl_surfaceless_llvmpipe() { # skipped (ok) where eglinfo is not installed
  [ -z "$(jail_violations)" ] || return 1   # never probe GL outside the jail (it may open render nodes)
  command -v eglinfo >/dev/null || return 0
  local out r; out=$(eglinfo -B 2>&1 || true)   # exits non-zero for the GBM/X11 platforms it cannot open
  r=$(printf '%s\n' "$out" | grep 'renderer: ') || return 1
  [ -n "$r" ] && ! printf '%s\n' "$r" | grep -qv llvmpipe
}

checks() {
  check "require_jail holds (no /dev/input, no wayland-0, no system bus, PID 1 is bwrap)" bash -c "source '$HERE/lib/jail.sh'; [ -z \"\$(jail_violations)\" ]"
  check "/dev/input absent" absent /dev/input
  check "/dev/dri absent" absent /dev/dri
  check "/dev/uinput absent" absent /dev/uinput
  check "/dev/hidraw* absent" bash -c '! ls /dev/hidraw* 2>/dev/null | grep -q .'
  check "wayland-0 absent" absent "/run/user/$UID_/wayland-0"
  check "system bus socket absent" absent /run/dbus/system_bus_socket
  check "/run holds only the user dir" bash -c "[ \"\$(ls /run)\" = user ]"
  check "/dev/udmabuf present" test -c /dev/udmabuf
  check "PID 1 is bwrap" bash -c '[ "$(cat /proc/1/comm)" = bwrap ]'
  check "root filesystem read-only" read_only /usr
  check "/tmp writable (tmpfs)" writable /tmp
  check "HOME is under scratch" under_scratch "${HOME:-}/x"
  check "XDG_RUNTIME_DIR is /run/user/UID" bash -c "[ \"\${XDG_RUNTIME_DIR:-}\" = /run/user/$UID_ ]"
  check "XDG config, state, cache are under scratch" bash -c "$(declare -f under_scratch); under_scratch \"\$XDG_CONFIG_HOME/x\" && under_scratch \"\$XDG_STATE_HOME/x\" && under_scratch \"\$XDG_CACHE_HOME/x\""
  check "scratch writable" writable "${JAIL_SCRATCH:-/nonexistent}"
  check "no network but loopback" only_loopback
  check "no display or bus variables leaked" bash -c '[ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}${DBUS_SESSION_BUS_ADDRESS:-}${DBUS_SYSTEM_BUS_ADDRESS:-}" ]'
  check "private bus starts, serves both roles" private_bus_works
  check "every EGL renderer is llvmpipe (when eglinfo exists)" egl_surfaceless_llvmpipe
  check "fabricated GPU nodes match JAIL_GPUS=${JAIL_GPUS:-0}" fabricated_gpus_exact "${JAIL_GPUS:-0}"
}

in_jail_mode() {
  checks
  if [ "$FAILS" = 0 ]; then echo "SELFTEST PASS"; else echo "SELFTEST FAIL ($FAILS)"; return 1; fi
}

negative_mode() {
  if [ -z "$(jail_violations)" ]; then
    echo "negative check can only run outside the jail" >&2; return 2
  fi
  echo "negative check: running the checks outside the jail, expecting FAIL"
  if "$0" >"${TMPDIR:-/tmp}/selftest-negative.$$" 2>&1; then
    cat "${TMPDIR:-/tmp}/selftest-negative.$$"; rm -f "${TMPDIR:-/tmp}/selftest-negative.$$"
    echo "NEGATIVE CHECK FAIL: the selftest passed outside the jail"; return 1
  fi
  grep -E '^SELFTEST' "${TMPDIR:-/tmp}/selftest-negative.$$"; rm -f "${TMPDIR:-/tmp}/selftest-negative.$$"
  echo "NEGATIVE CHECK PASS: the selftest fails outside the jail"
}

case "${1:-}" in
  "") in_jail_mode ;;
  --negative) negative_mode ;;
  --all)
    rc=0
    "$HERE/jail.sh" --fabricate-gpus 2 -- "$HERE/selftest.sh" || rc=$?
    [ "$rc" = 0 ] || exit "$rc"
    negative_mode ;;
  *) echo "usage: selftest.sh [--all|--negative]" >&2; exit 64 ;;
esac
