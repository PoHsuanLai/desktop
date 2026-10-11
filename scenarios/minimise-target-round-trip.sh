#!/usr/bin/env bash
# Scenario `minimise-target-round-trip` (plan §4.14, FD-05, P2): the shell's minimise target round trip, in the jail.
#
# casement starts headless (1920x1080) with CASEMENT_DEBUG_PEER_UNITS="casement-probe=sill.service" (a test-only,
# debug-inject-build override: no systemd in the jail), so a `casement-probe` session can take the shell
# connection through org.quire.Compositor1.Connect("shell") and act as the dock's owner. Two probe sessions:
#   W  a plain client that maps two toplevels (a and b) and minimises them (xdg_toplevel.set_minimized)
#   S  the shell: shell-connect, a bottom-anchored layer surface given the dock role, then the targets
# Steps, each waiting on a probe note or a casementctl predicate, never on a fixed sleep:
#   boot      casement up with the unit override
#   windows   a and b map; their identifiers (w<id>) are read from `casementctl debug windows`
#   dock      S connects as the shell and its layer surface takes the dock role (no error note)
#   set       a minimise target for a: `debug windows` shows minimise_target inside the dock's rectangle at the size given
#   minimise  a minimised: its minimise_destination is exactly that target rectangle
#   clear     the target for b is set, then cleared (minimise_target null); b minimised: its destination is not the
#             old rectangle (the default, as with no dock)
#
# Needs casement 8383659f or later in the manifest, plus two things the casement-probe/debug bus must offer
# (see the lane report): the probe session verb `minimise NAME` (xdg_toplevel.set_minimized on that toplevel) and
# two fields on every `debug windows` row: "minimised" (bool) and "minimise_destination" ([x,y,w,h] global of the
# last minimise, or null).
#
# budget: 90
# Exit: 0 pass | 1 a step failed | 2 outside the jail | 3 artefacts missing (harness/scenario-build.sh).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../harness/lib/all.sh"
source "$HERE/../harness/lib/scenario.sh"
require_jail
scenario_need "$SCEN_TOOLS/bin/casement" "$SCEN_TOOLS/bin/casementctl" "$SCEN_TOOLS/bin/casement-probe" \
  "$SCEN_TOOLS/bin/fake-logind"

export CASEMENT_TOOLS="$SCEN_TOOLS" CASEMENT_REPO="$SCEN_SIB/casement"
# shellcheck source=/dev/null
source "$SCEN_SIB/casement/dev/lib/compositor.sh"
# shellcheck source=/dev/null
source "$SCEN_SIB/casement/dev/lib/probe.sh"
# shellcheck source=/dev/null
source "$SCEN_SIB/casement/dev/lib/wait.sh"
OUT_DIR=$(scenario_out minimise-target-round-trip)
CTL="$SCEN_TOOLS/bin/casementctl"
APP_A=org.example.minimise.a
APP_B=org.example.minimise.b
ID_A= ID_B=
DOCK_W=300 DOCK_H=64   # the dock layer's size; anchored to the bottom edge, so centred on a 1920-wide output
TARGET_W=48 TARGET_H=48

cleanup() {
  probe_stop_all
  stop_compositor || true
}
trap cleanup EXIT

# row APP FIELD: one field of the `debug windows` row whose class is APP, as compact JSON (nothing, exit 1, when absent).
row() {
  "$CTL" debug windows | python3 -I -c '
import json, sys
for w in json.load(sys.stdin):
    if w.get("class") == sys.argv[1] and sys.argv[2] in w:
        print(json.dumps(w[sys.argv[2]], separators=(",", ":"))); sys.exit(0)
sys.exit(1)' "$1" "$2"
}

# wait_row APP FIELD PYTEST: up to 10 s for the field to satisfy PYTEST (a Python expression of v); prints the value.
wait_row() {
  local v
  for _ in $(seq 100); do
    v=$(row "$1" "$2" 2>/dev/null) && python3 -I -c 'import json,sys; v=json.loads(sys.argv[1]); sys.exit(0 if '"$3"' else 1)' "$v" 2>/dev/null \
      && { echo "$v"; return 0; }
    sleep 0.1
  done
  echo "$1.$2 never satisfied '$3' (last: ${v:-none})" >&2
  return 1
}

# shell_ok NAME: the last `probe: {json}` note of session NAME carries no "error".
shell_ok() { ! probe_log "$1" | grep '^probe: {' | tail -1 | grep -q '"error"'; }

# turn S: the session has run what was sent and the compositor has seen it (requests leave on the next turn).
turn() { probe_sync "$1"; }

step_boot() {
  export CASEMENT_DEBUG_PEER_UNITS="casement-probe=sill.service"
  start_compositor || return 1
}

step_windows() {
  probe_start W || return 1
  probe_do W toplevel a "app=$APP_A" size=400x300 pattern=gradient || return 1
  probe_do W toplevel b "app=$APP_B" size=400x300 pattern=gradient || return 1
  probe_wait W '^probe: mapped a 400x300$' && probe_wait W '^probe: mapped b 400x300$' || return 1
  wait_for "mapped $APP_A" && wait_for "mapped $APP_B" || return 1
  ID_A=$(wait_row "$APP_A" identifier 'True' | tr -d '"') && ID_B=$(wait_row "$APP_B" identifier 'True' | tr -d '"') || return 1
  echo "windows: a=$ID_A b=$ID_B" >&2
}

step_dock() {
  probe_start S || return 1
  probe_do S shell-connect || return 1
  shell_ok S || { echo "shell-connect was refused (is CASEMENT_DEBUG_PEER_UNITS honoured by this casement build?):" >&2; probe_log S >&2; return 1; }
  probe_do S layer d level=top "size=${DOCK_W}x${DOCK_H}" anchor=bottom || return 1
  probe_do S shell-role dock d || return 1
  shell_ok S || { echo "the dock role was refused:" >&2; probe_log S >&2; return 1; }
  turn S
}

step_set() {
  local target
  probe_do S minimise-target "$ID_A" 20 8 "$TARGET_W" "$TARGET_H" || return 1
  shell_ok S || { echo "minimise-target refused:" >&2; probe_log S >&2; return 1; }
  turn S
  target=$(wait_row "$APP_A" minimise_target 'v is not None') || return 1
  TARGET_A=$target
  python3 -I -c '
import json, sys
x, y, w, h = json.loads(sys.argv[1]); dw, dh, tw, th = map(int, sys.argv[2:6])
dock_x = (1920 - dw) // 2; dock_y = 1080 - dh
ok = (w, h) == (tw, th) and dock_x <= x and x + w <= dock_x + dw and dock_y <= y and y + h <= dock_y + dh
sys.exit(0 if ok else "target %s is not a %dx%d rectangle inside the dock (%d,%d %dx%d)" % (sys.argv[1], tw, th, dock_x, dock_y, dw, dh))' \
    "$target" "$DOCK_W" "$DOCK_H" "$TARGET_W" "$TARGET_H"
}

step_minimise() {
  probe_do W minimise a || return 1
  wait_row "$APP_A" minimised 'v is True' >/dev/null || return 1
  local dest
  dest=$(wait_row "$APP_A" minimise_destination 'v is not None') || return 1
  [ "$dest" = "$TARGET_A" ] || { echo "a minimised to $dest, not to its target $TARGET_A" >&2; return 1; }
}

step_clear() {
  probe_do S minimise-target "$ID_B" 20 8 "$TARGET_W" "$TARGET_H" || return 1
  turn S
  wait_row "$APP_B" minimise_target 'v is not None' >/dev/null || return 1
  probe_do S minimise-clear "$ID_B" || return 1
  shell_ok S || { echo "minimise-clear refused:" >&2; probe_log S >&2; return 1; }
  turn S
  wait_row "$APP_B" minimise_target 'v is None' >/dev/null || return 1
  probe_do W minimise b || return 1
  wait_row "$APP_B" minimised 'v is True' >/dev/null || return 1
  local dest
  dest=$(wait_row "$APP_B" minimise_destination 'v is not None') || return 1
  [ "$dest" != "$TARGET_A" ] || { echo "b minimised to the cleared target $dest" >&2; return 1; }
}

for name in step_boot step_windows step_dock step_set step_minimise step_clear; do
  STEP_BUDGET=45 step "$name" "$name" || break
done
if [ "$STEP_WORST" != 0 ]; then
  for f in "$(casement_state_dir)"/probe/*.log "$(casement_state_dir)"/casement.log; do
    [ -f "$f" ] && { echo "--- $f (tail)" >&2; tail -25 "$f" >&2; }
  done
fi
steps_exit
