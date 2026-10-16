#!/usr/bin/env bash
# Scenario `sill-boots-on-casement` (plan §4.14): sill boots on casement headless, in the jail.
#
# The jail, a headless casement and the sill daemon on one private bus come up through sill's own
# dev/lib (start_compositor, launch_daemon: what `dev/accept.sh --compositor casement` uses); this
# script only asserts the boot. Steps, each waiting on what it needs (a socket, a ping, a frame
# counter), never on a fixed sleep:
#   boot      casement up, the daemon answers `ping`
#   surfaces  a bar and a dock exist on the output and each has drawn a frame
#   capture   `sill debug capture` of the bar reports done and writes a PNG
#   quit      `sill quit` ends the daemon on its own, with no panic in its log, and casement is
#             still up (it outlived its client)
#
# budget: 90
# Exit: 0 pass | 1 a step failed | 2 outside the jail | 3 artefacts missing (harness/scenario-build.sh).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/scenario.sh"
require_jail
scenario_need "$SCEN_TOOLS/bin/casement" "$SCEN_TOOLS/bin/casementctl" "$SCEN_TOOLS/bin/fake-logind" \
  "$SCEN_BUILD/sill-target/debug/sill"

export SILL_COMPOSITOR=casement SILL_PREBUILT=1 SILL_PROFILE=debug
export CARGO_TARGET_DIR="$SCEN_BUILD/sill-target" CASEMENT_TOOLS="$SCEN_TOOLS"
floor_shim sill-boots-on-casement   # no program here takes a power a floor row can allow: casement starts with an empty floor, so nothing waits on a question
# shellcheck source=/dev/null
source "$SCEN_SRC/sill/dev/lib/all.sh"
OUT_DIR=$(scenario_out sill-boots-on-casement)

cleanup() {
  stop_daemon
  stop_compositor
  scratch_drop
}
trap cleanup EXIT

# wait_for TENTHS CMD...: up to TENTHS tenths of a second for CMD to succeed and print something; prints it.
wait_for() {
  local tenths=$1 out; shift
  for _ in $(seq "$tenths"); do
    out=$("$@" 2>/dev/null) && [ -n "$out" ] && { echo "$out"; return 0; }
    sleep 0.1
  done
  return 1
}

step_boot() {
  start_compositor || return 1
  scratch_new
  build || return 1
  launch_daemon
}

step_surfaces() {
  local bar dock
  bar=$(wait_for 300 bar_name) || { echo "no bar in 'sill debug stats'" >&2; return 1; }
  dock=$(wait_for 300 dock_name) || { echo "no dock in 'sill debug stats'" >&2; return 1; }
  for surface in "$bar" "$dock"; do
    wait_for 300 frames_drawn "$surface" >/dev/null || { echo "$surface never drew a frame" >&2; return 1; }
    echo "$surface drew $(frames_of "$surface") frame(s)" >&2
  done
}
bar_name() { surface_named sill-bar-; }
dock_name() { surface_named sill-dock-; }
frames_drawn() { local n; n=$(frames_of "$1"); [ "${n:-0}" -ge 1 ] && echo "$n"; }

step_capture() {
  local bar
  bar=$(bar_name) || return 1
  sill debug capture "$bar" "$OUT_DIR/bar.png" >"$OUT_DIR/capture.log" 2>&1 || return 1
  grep -q '"kind":"done"' "$OUT_DIR/capture.log" && [ -s "$OUT_DIR/bar.png" ]
}

step_quit() {
  stop_daemon || return 1
  if grep -q panicked "$OUT_DIR/daemon.log"; then echo "the daemon panicked:" >&2; grep panicked "$OUT_DIR/daemon.log" >&2; return 1; fi
  local pid
  pid=$(sed -n 's/^\(export \)\{0,1\}CASEMENT_PID=//p' "$CASEMENT_ENV")
  kill -0 "$pid" 2>/dev/null || { echo "casement ($pid) is gone" >&2; return 1; }
}

run_steps step_boot step_surfaces step_capture step_quit
if [ "$STATUS" != 0 ]; then
  echo "--- daemon.log (tail)" >&2; tail -20 "$OUT_DIR/daemon.log" >&2
  echo "--- casement-up.log (tail)" >&2; tail -20 "$OUT_DIR/casement-up.log" >&2
  [ -z "${CASEMENT_ENV:-}" ] || { echo "--- casement.log (tail)" >&2; tail -20 "$(dirname "$CASEMENT_ENV")/casement.log" >&2; }
fi
exit "$STATUS"
