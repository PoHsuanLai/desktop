#!/usr/bin/env bash
# Scenario `desktop-menu-click`: a right click on the desktop opens its menu and picks nothing,
# even when the pointer drifts a little between the press and the release, as a hand's does.
# A deliberate press-drag-release onto the item still picks it (the menu is not just broken).
#
# The jail, a headless casement and the sill daemon on one private bus come up as in
# sill-boots-on-casement. Nothing owns org.quire.Settings on the private bus, so a pick of
# "Change Wallpaper…" shows as sill's log line "opening Settings".
#   boot      casement up, the daemon answers `ping`, the wallpaper has drawn
#   jitter    right press, a 2 px drift down-right, release: no Settings
#   still     right press and release at one point: no Settings
#   drag      right press, a drag well into the item, release: Settings is asked for
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
floor_shim desktop-menu-click sill
# shellcheck source=/dev/null
source "$SCEN_SRC/sill/dev/lib/all.sh"
OUT_DIR=$(scenario_out desktop-menu-click)

cleanup() {
  stop_daemon
  stop_compositor
  scratch_drop
}
trap cleanup EXIT

wait_for() {
  local tenths=$1 out; shift
  for _ in $(seq "$tenths"); do
    out=$("$@" 2>/dev/null) && [ -n "$out" ] && { echo "$out"; return 0; }
    sleep 0.1
  done
  return 1
}
frames_drawn() { local n; n=$(frames_of "$1"); [ "${n:-0}" -ge 1 ] && echo "$n"; }

# The desktop point the gestures start at: clear of the bar and the dock.
X=400 Y=300

asked() { grep -c "opening Settings" "$OUT_DIR/daemon.log" 2>/dev/null || true; }
inject() { casementctl debug inject "$@" >>"$OUT_DIR/inject.log" 2>&1; }
# Close whatever menu is open with a plain click far from it, then let it fade.
dismiss() { inject "move 60 600" "sleep 60" "press left" "sleep 40" "release left" "sleep 600"; }

step_boot() {
  start_compositor || return 1
  scratch_new
  build || return 1
  floor_sill_callers
  launch_daemon || return 1
  local wall
  wall=$(wait_for 300 surface_named sill-wallpaper-) || { echo "no wallpaper surface" >&2; return 1; }
  wait_for 300 frames_drawn "$wall" >/dev/null || { echo "the wallpaper never drew" >&2; return 1; }
  sleep 1
}

# gesture LINES...: one right-button gesture, then the time a pick takes to reach the launcher.
gesture() { inject "$@" "sleep 900"; }

step_jitter() {
  local before; before=$(asked)
  gesture "move $X $Y" "sleep 80" "press right" "sleep 60" "move $((X + 1)) $((Y + 1))" "sleep 20" \
    "move $((X + 2)) $((Y + 2))" "sleep 40" "release right"
  [ "$(asked)" = "$before" ] || { echo "a 2 px drift during a right click opened Settings" >&2; dismiss; return 1; }
  dismiss
}

step_still() {
  local before; before=$(asked)
  gesture "move $X $Y" "sleep 80" "press right" "sleep 60" "release right"
  [ "$(asked)" = "$before" ] || { echo "a right click with no drift opened Settings" >&2; dismiss; return 1; }
  dismiss
}

step_drag() {
  local before; before=$(asked)
  gesture "move $X $Y" "sleep 80" "press right" "sleep 300" "move $((X + 20)) $((Y + 8))" "sleep 40" \
    "move $((X + 40)) $((Y + 14))" "sleep 300" "release right"
  [ "$(asked)" != "$before" ] || { echo "a press-drag-release onto Change Wallpaper… picked nothing" >&2; dismiss; return 1; }
}

run_steps step_boot step_jitter step_still step_drag
if [ "$STATUS" != 0 ]; then
  echo "--- inject.log (tail)" >&2; tail -20 "$OUT_DIR/inject.log" >&2
  echo "--- daemon.log (tail)" >&2; tail -20 "$OUT_DIR/daemon.log" >&2
fi
exit "$STATUS"
