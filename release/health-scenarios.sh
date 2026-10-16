#!/usr/bin/env bash
# Two scenarios for the start check, with slipway's real programs on a throwaway computer (a CI container):
#
#   good-starts-are-kept    install two releases, then two logins that each run `slipway recover` before the
#                           compositor and `slipway confirm` after the shell answers: the newest release stays,
#                           however many more computers restarts follow
#   failed-starts-restore   install two releases, then restarts of the computer that never reach `confirm`: a start
#                           repeated inside one restart is not counted, the third restart puts the previous release
#                           back (`slipway recover` exits 5 and says so), and that release is then left alone
#
# What it fakes, and why: the health program counts restarts of the computer by reading the kernel's boot id, a path
# it cannot be told otherwise, so a new boot id is bound over /proc/sys/kernel/random/boot_id for each restart (this
# needs root and the right to mount, which `docker run --privileged` has). `pkexec` is a stand-in that runs the program
# it is given, because the container is already root and has no polkit agent. Everything else is real: the signed
# releases (a throwaway key, the repo's own pack.sh), slipway-apply, slipway-health, and `slipway`, as the session runs them.
#
#   release/health-scenarios.sh --helpers DIR --policy FILE --really
#
#   --helpers DIR  the built slipway, slipway-apply, slipway-rollback and slipway-health
#   --policy FILE  slipway's polkit file (installed, then checked, as release/smoke.sh does)
#   --really       yes, this machine may be changed (/etc/slipway, /usr/libexec, /opt, a mount over /proc)
#
# Exit: 0 both pass, 1 a check failed, 2 bad usage, not root, a tool missing, or the boot id cannot be replaced
# (the scenarios cannot run here; CI treats that as a failure).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/lib.sh
. "$HERE/lib.sh"
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
helpers="" policy="" really=no
while [ $# -gt 0 ]; do
  case "$1" in
    --helpers) helpers=${2:?}; shift ;;
    --policy) policy=${2:?}; shift ;;
    --really) really=yes ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[ -d "$helpers" ] && [ -f "$policy" ] || { usage >&2; exit 2; }
[ "$really" = yes ] || { echo "health-scenarios.sh: this changes the whole computer; add --really on a throwaway one" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "health-scenarios.sh: run as root (in the container)" >&2; exit 2; }
for tool in python3 zstd minisign mount umount; do
  command -v "$tool" >/dev/null || { echo "health-scenarios.sh: $tool is not installed ($(install_hint "$tool"))" >&2; exit 2; }
done
for program in slipway slipway-apply slipway-rollback slipway-health; do
  [ -x "$helpers/$program" ] || { echo "health-scenarios.sh: $helpers/$program is not there" >&2; exit 2; }
done

BOOT_ID=/proc/sys/kernel/random/boot_id
tmp=$(mktemp -d)
bound=no
cleanup() {
  [ "$bound" = no ] || umount "$BOOT_ID" 2>/dev/null || true
  rm -rf -- "${tmp:?}" /opt/quire-scenario-*
}
trap cleanup EXIT
fail=0
check() { echo "FAIL health scenarios: $*" >&2; fail=1; }

# --- the machine: slipway's own install, a key, three signed releases, a fake pkexec, a boot id we control ---------
for program in slipway-apply slipway-rollback slipway-health; do install -Dm755 "$helpers/$program" "/usr/libexec/$program"; done
install -Dm644 "$policy" /usr/share/polkit-1/actions/org.quire.slipway.policy
"$HERE/check-helpers.sh" >/dev/null

minisign -G -W -p "$tmp/key.pub" -s "$tmp/key.sec" >/dev/null
install -Dm644 "$tmp/key.pub" /usr/share/slipway/release.pub
: >"$tmp/exports.toml"
printf 'A release made for a scenario.\n' >"$tmp/notes.txt"
for version in 1.0.0 2.0.0 3.0.0; do
  mkdir -p "$tmp/stage-$version/opt/quire/current/bin"
  printf '#!/bin/sh\necho %s\n' "$version" >"$tmp/stage-$version/opt/quire/current/bin/tool"
  chmod 755 "$tmp/stage-$version/opt/quire/current/bin/tool"
  MINISIGN_KEY_FILE="$tmp/key.sec" MINISIGN_PASSWORD="" SOURCE_DATE_EPOCH=1790000000 \
    "$HERE/pack.sh" --stage "$tmp/stage-$version" --version "$version" --notes "$tmp/notes.txt" \
    --out "$tmp/release-$version" --exports "$tmp/exports.toml" >/dev/null
done

mkdir -p "$tmp/bin" "$tmp/home"
printf '#!/bin/sh\nexec "$@"\n' >"$tmp/bin/pkexec"
chmod 755 "$tmp/bin/pkexec"
uuid() { cat /proc/sys/kernel/random/uuid; }
uuid >"$tmp/boot_id"
mount --bind "$tmp/boot_id" "$BOOT_ID" 2>"$tmp/mount.err" || { cat "$tmp/mount.err" >&2; echo "health-scenarios.sh: cannot replace the boot id (a container needs --privileged)" >&2; exit 2; }
bound=yes
[ "$(cat "$BOOT_ID")" = "$(cat "$tmp/boot_id")" ] || { echo "health-scenarios.sh: the replaced boot id is not what is read" >&2; exit 2; }

restart_computer() { uuid >"$tmp/boot_id"; }
# slipway ARGS...: the user program, as the session runs it: its own home, the stand-in pkexec first on the path.
slipway() {
  env HOME="$tmp/home" XDG_STATE_HOME="$tmp/home/state" XDG_CONFIG_HOME="$tmp/home/config" XDG_CACHE_HOME="$tmp/home/cache" \
    PATH="$tmp/bin:$PATH" "$helpers/slipway" "$@"
}
# status_of ARGS...: the exit status of `slipway ARGS`, its words kept in $tmp/said.
status_of() { local rc=0; slipway "$@" >"$tmp/said" 2>&1 || rc=$?; echo "$rc"; }
expect() { # WANT WHAT ARGS...: `slipway ARGS` exits WANT
  local want=$1 what=$2 got; shift 2
  got=$(status_of "$@")
  [ "$got" = "$want" ] || check "$what: slipway $* exited $got, wanted $want ($(tr '\n' ' ' <"$tmp/said"))"
}

# fresh_machine NAME: an empty install root of its own, named by the system settings, with 1.0.0 then 2.0.0 installed.
fresh_machine() {
  root="/opt/quire-scenario-$1"
  rm -rf -- "$root" "$tmp/home"
  mkdir -p "$tmp/home"
  install -d /etc/slipway
  printf 'root = "%s"\npubkey_path = "/usr/share/slipway/release.pub"\n' "$root" >/etc/slipway/config.toml
  /usr/libexec/slipway-apply "$tmp/release-1.0.0" >/dev/null
  /usr/libexec/slipway-apply "$tmp/release-2.0.0" >/dev/null
}
installed() { basename "$(readlink -f "$root/current")"; }
expect_installed() { # VERSION WHEN
  [ "$(installed)" = "$1" ] || check "$2: $(installed) is installed, wanted $1"
}

good_starts_are_kept() {
  local login boot
  fresh_machine good
  expect_installed 2.0.0 "after the install"
  for login in 1 2; do
    restart_computer
    expect 0 "login $login, before the compositor" recover
    expect 0 "login $login, after the shell answered" confirm
  done
  for boot in 3 4 5 6; do
    restart_computer
    expect 0 "restart $boot, a confirmed release" recover
  done
  expect_installed 2.0.0 "after two confirmed logins and four more restarts"
}

failed_starts_restore() {
  local again boot
  fresh_machine failed
  expect_installed 2.0.0 "after the install"
  # A start repeated inside one restart is one start: nothing a program of the person does may force a rollback.
  restart_computer
  for again in 1 2 3 4 5 6; do expect 0 "the first restart, start $again" recover; done
  expect_installed 2.0.0 "after six starts in one restart"
  restart_computer
  expect 0 "the second restart" recover
  expect_installed 2.0.0 "after two restarts"
  restart_computer
  expect 5 "the third restart" recover
  grep -qi 'previous version' "$tmp/said" || check "the third restart: no word that the previous version came back: $(cat "$tmp/said")"
  expect_installed 1.0.0 "after the third restart"
  # The release that was put back is known to work: it is not put back again for the restarts that follow.
  for boot in 4 5 6; do
    restart_computer
    expect 0 "restart $boot, after the previous version came back" recover
  done
  expect_installed 1.0.0 "after the restarts that followed"
  # A newer release then starts its own count.
  /usr/libexec/slipway-apply "$tmp/release-3.0.0" >/dev/null
  restart_computer
  expect 0 "the first restart on 3.0.0" recover
  expect_installed 3.0.0 "after the first restart on 3.0.0"
}

echo "== good starts are kept"
good_starts_are_kept
echo "== failed starts restore the previous version"
failed_starts_restore
[ "$fail" = 0 ] || exit 1
echo "health scenarios: pass (good starts are kept, failed starts restore the previous version)"
