#!/usr/bin/env bash
# Scenario `session-crash-guard` (plan P1-SESS): session/desktop-session's crash-loop guard, in the jail.
#
# desktop-session runs a stand-in for casement (this script's `--fake-casement` mode) that starts the
# real headless casement with two outputs and, unless it was given --safe, injects
# `casementctl debug fault panic-after-frames 1` so it panics at once. The session must then:
#   guard       start casement three times, each ending in a quick exit, then start `casement --safe`
#   safe        the --safe casement stays up on one output (pixman, no effects) and the session
#               does not exit
#   ends        with a stand-in that always panics, the --safe run's quick exit ends the session with
#               status 1 and a guard log line (the other login entry stays available); when the rollback
#               program is there, the log also names the command to go back by hand
#   state       without DESKTOP_SESSION_STATE, guard.log is kept in $XDG_STATE_HOME/desktop-session (it must
#               outlive the session; the runtime folder does not) and casement.log stays in the runtime folder
#   components  none run by default (DESKTOP_SESSION_NESTED=1: no systemd, no sill); with
#               DESKTOP_SESSION_STUBS the session starts its components from stand-in programs: sill as
#               the unit sill.service (and again after it exits), the power-key inhibitor,
#               the wallet (pam_kwallet_init, then ksecretd when nothing owns the Secret Service) and
#               detent --first-run; all are gone when the session ends
# This is the direct-child path (DESKTOP_SESSION_NESTED=1); the real session runs casement as casement.service
# (needs a systemd user manager, first-login check) with the same guard decisions.
# Nothing outside the jail's scratch is read or written; the session is ended by its PID.
#
# budget: 90
# Exit: 0 pass | 1 a step failed | 2 outside the jail | 3 artefacts missing (harness/scenario-build.sh).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"

# The stand-in casement the session runs. Inside the jail's scenario environment (bus, tools).
if [ "${1:-}" = --fake-casement ]; then
  shift
  real="${FAKE_CASEMENT_TOOLS:?}/bin/casement"
  safe=0
  for arg in "$@"; do [ "$arg" != --safe ] || safe=1; done
  if [ "$safe" = 1 ] && [ "${FAKE_CASEMENT_ALWAYS_PANIC:-}" != 1 ]; then
    exec "$real" "$@"
  fi
  "$real" "$@" &
  pid=$!
  trap 'kill "$pid" 2>/dev/null' TERM INT
  for _ in $(seq 100); do
    "$FAKE_CASEMENT_TOOLS/bin/casementctl" debug fault panic-after-frames 1 >/dev/null 2>&1 && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  # Pointer moves keep frames coming, so the injected panic fires even on an idle output.
  ( x=10; while kill -0 "$pid" 2>/dev/null; do
      x=$(( x % 700 + 10 ))
      "$FAKE_CASEMENT_TOOLS/bin/casementctl" debug inject "move $x 100" >/dev/null 2>&1
      sleep 0.1
    done ) &
  nudger=$!
  status=0
  wait "$pid" || status=$?
  kill "$nudger" 2>/dev/null || true
  exit "$status"
fi

source "$HERE/../harness/lib/all.sh"
source "$HERE/../harness/lib/scenario.sh"
require_jail
scenario_need "$SCEN_TOOLS/bin/casement" "$SCEN_TOOLS/bin/casementctl" "$SCEN_TOOLS/bin/fake-logind" \
  "$HERE/../session/desktop-session"

OUT_DIR=$(scenario_out session-crash-guard)
RUN="$OUT_DIR/run"
mkdir -p "$RUN"
chmod 700 "$RUN"
SESSION_PID=
LOGIND_PID=

cleanup() {
  [ -z "$SESSION_PID" ] || kill "$SESSION_PID" 2>/dev/null
  [ -z "$SESSION_PID" ] || wait "$SESSION_PID" 2>/dev/null
  [ -z "$LOGIND_PID" ] || kill "$LOGIND_PID" 2>/dev/null
  private_bus_stop
}
trap cleanup EXIT

# wait_for TENTHS CMD...: succeeds as soon as CMD does.
wait_for() {
  local tenths=$1; shift
  for _ in $(seq "$tenths"); do
    "$@" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# count PATTERN FILE: how many lines match.
count() { grep -c -- "$1" "$2" 2>/dev/null || true; }

# start_session NAME [ENV=VALUE...]: a fresh desktop-session with its own state dir; sets STATE.
start_session() {
  local name=$1; shift
  STATE="$OUT_DIR/state-$name"
  rm -rf "$STATE"
  env XDG_RUNTIME_DIR="$RUN" DESKTOP_SESSION_NESTED=1 DESKTOP_SESSION_STATE="$STATE" \
    DESKTOP_SESSION_QUICK_SECS=30 FAKE_CASEMENT_TOOLS="$SCEN_TOOLS" \
    DESKTOP_SESSION_CASEMENT_CMD="$SELF --fake-casement" \
    DESKTOP_SESSION_BACKEND_ARGS="--backend headless --clock wall --outputs A-1:800x600@60000:120:0,0;B-1:800x600@60000:120:800,0" \
    "$@" "$HERE/../session/desktop-session" >"$OUT_DIR/session-$name.log" 2>&1 &
  SESSION_PID=$!
}

stop_session() {
  [ -z "$SESSION_PID" ] || kill "$SESSION_PID" 2>/dev/null
  [ -z "$SESSION_PID" ] || wait "$SESSION_PID" 2>/dev/null
  SESSION_PID=
}

step_bus() {
  private_bus_start || return 1
  "$SCEN_TOOLS/bin/fake-logind" >"$OUT_DIR/fake-logind.log" 2>&1 </dev/null &
  LOGIND_PID=$!
}

guard_reaches_safe() {
  start_session safe
  wait_for 300 grep -q 'switching to casement --safe' "$STATE/guard.log" || { echo "the guard never went to --safe" >&2; return 1; }
  [ "$(count 'starting casement (quick' "$STATE/guard.log")" = 3 ] || { echo "not three normal starts first:" >&2; cat "$STATE/guard.log" >&2; return 1; }
  [ "$(count 'exited [1-9][0-9]* after' "$STATE/guard.log")" -ge 3 ] || { echo "the normal runs did not fail:" >&2; cat "$STATE/guard.log" >&2; return 1; }
  wait_for 200 grep -q 'starting casement --safe' "$STATE/guard.log" || return 1
}

safe_stays_up_on_one_output() {
  local outputs
  # wait for the safe casement to answer on the bus
  outputs=
  for _ in $(seq 100); do
    outputs=$("$SCEN_TOOLS/bin/casementctl" debug output list --json 2>/dev/null) && [ -n "$outputs" ] && break
    sleep 0.1
  done
  [ -n "$outputs" ] || { echo "no output list from the --safe casement" >&2; return 1; }
  [ "$(printf '%s' "$outputs" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 1 ] \
    || { echo "--safe has more than one output: $outputs" >&2; return 1; }
  sleep 3
  kill -0 "$SESSION_PID" 2>/dev/null || { echo "the session ended" >&2; return 1; }
  ! grep -q 'ends the session' "$STATE/guard.log" || { echo "the guard ended the session although --safe was up" >&2; return 1; }
  stop_session
}

safe_failing_ends_the_session() {
  local rc=0
  start_session ends FAKE_CASEMENT_ALWAYS_PANIC=1 DESKTOP_SESSION_ROLLBACK_HELPER="$(command -v true)"
  wait_for 600 bash -c "! kill -0 $SESSION_PID" || { echo "the session did not end" >&2; return 1; }
  wait "$SESSION_PID" || rc=$?
  SESSION_PID=
  [ "$rc" = 1 ] || { echo "exit $rc, expected 1" >&2; return 1; }
  grep -q 'casement --safe exited quickly' "$STATE/guard.log" || return 1
  grep -q 'the crash guard ends the session' "$STATE/guard.log" || return 1
  grep -q "by hand.*pkexec $(command -v true)" "$STATE/guard.log" || { echo "no way back named:" >&2; cat "$STATE/guard.log" >&2; return 1; }
}

# Without DESKTOP_SESSION_STATE the decisions go to the person's state folder, so they outlive the session.
guard_log_outlives_the_runtime_folder() {
  local kept="$OUT_DIR/xdg-state"
  rm -rf "$kept"
  start_session kept DESKTOP_SESSION_STATE= XDG_STATE_HOME="$kept" HOME="$OUT_DIR/home"
  wait_for 100 grep -q 'starting casement' "$kept/desktop-session/guard.log" || { echo "no guard.log in the state folder" >&2; return 1; }
  [ ! -e "$RUN/desktop-session/guard.log" ] || { echo "guard.log is also in the runtime folder" >&2; return 1; }
  [ -e "$RUN/desktop-session/casement.log" ] || { echo "casement.log is not in the runtime folder" >&2; return 1; }
  stop_session
  [ -s "$kept/desktop-session/guard.log" ] || { echo "guard.log did not survive the session" >&2; return 1; }
}

# stub_components: stand-in programs that log each call to $OUT_DIR/stubs.log. sill exits at once the
# first time (the session must start it again); the rest stay up.
stub_components() {
  local d="$OUT_DIR/stubs" n
  rm -rf "$d" "$OUT_DIR/stubs.log" "$OUT_DIR/sill-ran" "$OUT_DIR/unit.pid"; mkdir -p "$d"
  for n in ksecretd pam_kwallet_init detent; do
    printf '#!/bin/sh\necho "%s $*" >>"%s"\n[ "%s" = pam_kwallet_init ] || [ "%s" = detent ] || exec sleep 300\n' \
      "$n" "$OUT_DIR/stubs.log" "$n" "$n" >"$d/$n"
  done
  printf '#!/bin/sh\necho "sill $*" >>"%s"\nif [ ! -e "%s/sill-ran" ]; then : >"%s/sill-ran"; exit 1; fi\nexec sleep 300\n' \
    "$OUT_DIR/stubs.log" "$OUT_DIR" "$OUT_DIR" >"$d/sill"
  printf '#!/bin/sh\necho "systemd-inhibit $*" >>"%s"\nexec sleep 300\n' "$OUT_DIR/stubs.log" >"$d/systemd-inhibit"
  # systemd-run starts the program after `--` detached and remembers its pid as the unit's; systemctl answers
  # for that unit: ActiveState follows the pid, stop ends it.
  printf '#!/bin/sh\necho "systemd-run $*" >>"%s"\nwhile [ "$1" != -- ]; do shift; done; shift\n"$@" </dev/null >/dev/null 2>&1 &\necho $! >"%s/unit.pid"\n' \
    "$OUT_DIR/stubs.log" "$OUT_DIR" >"$d/systemd-run"
  printf '#!/bin/sh\np=$(cat "%s/unit.pid" 2>/dev/null)\ncase "$*" in\n  *ActiveState*) if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo active; else echo inactive; fi ;;\n  *stop*) [ -z "$p" ] || kill "$p" 2>/dev/null; rm -f "%s/unit.pid" ;;\nesac\nexit 0\n' \
    "$OUT_DIR" "$OUT_DIR" >"$d/systemctl"
  printf '#!/bin/sh\nexit 1\n' >"$d/busctl"
  chmod +x "$d"/*
}

components_start_and_end_with_the_session() {
  local d="$OUT_DIR/stubs" log="$OUT_DIR/stubs.log" want
  stub_components
  start_session comps PAM_KWALLET5_LOGIN=1 DESKTOP_SESSION_STUBS="$d" DESKTOP_SESSION_FIRST_RUN_DELAY=1 \
    DESKTOP_SESSION_CASEMENT_CMD="$SCEN_TOOLS/bin/casement"
  wait_for 300 grep -q 'detent --first-run' "$log" || { echo "no first run:" >&2; cat "$log" >&2; return 1; }
  [ "$(count '^sill run' "$log")" -ge 2 ] || { sleep 3; [ "$(count '^sill run' "$log")" -ge 2 ]; } \
    || { echo "sill was not started again after it exited:" >&2; cat "$log" >&2; return 1; }
  # ksecretd starts only after the wallet has waited 5 s for an owner of the Secret Service.
  wait_for 100 grep -q '^ksecretd' "$log" || true
  for want in 'systemd-run --user --unit=sill --slice=app.slice --collect --quiet -p Type=exec' 'systemd-inhibit --what=handle-power-key --who=desktop-session' \
    '^pam_kwallet_init' '^ksecretd'; do
    grep -q -- "$want" "$log" || { echo "missing: $want" >&2; cat "$log" >&2; return 1; }
  done
  stop_session
  sleep 1
  ! pgrep -f "$d/" >/dev/null || { echo "components outlived the session:" >&2; pgrep -af "$d/" >&2; return 1; }
}

for name in step_bus guard_reaches_safe safe_stays_up_on_one_output safe_failing_ends_the_session \
  guard_log_outlives_the_runtime_folder components_start_and_end_with_the_session; do
  STEP_BUDGET=60 step "$name" "$name" || true
done
if [ "$STEP_WORST" != 0 ]; then
  for f in "$OUT_DIR"/state-*/guard.log; do echo "--- $f" >&2; cat "$f" >&2; done
fi
steps_exit
