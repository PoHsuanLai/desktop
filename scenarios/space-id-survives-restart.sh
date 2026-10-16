#!/usr/bin/env bash
# Scenario `space-id-survives-restart` (plan §4.14): a Space id is stable across a casement restart.
#
# Needs casement 5d47b6d or later: `casement --state-home DIR` (headless writes DIR/spaces.toml) and
# `casement-probe workspaces` (one JSON line per ext-workspace workspace, in announce order:
# {"active","group","id","name"}). Steps, each waiting on the probe's own `done`, never on a sleep:
#   first    two outputs, state home A: the workspace ids are read (at least one per output, all
#            present, all distinct)
#   restart  casement is stopped by the pid in its env file and started again on the same state
#            home A and the same outputs: the same ids come back, in the same order
#   fresh    casement started on an empty state home B: no id is one of A's
#
# budget: 60
# Exit: 0 pass | 1 a step failed | 2 outside the jail | 3 artefacts missing (harness/scenario-build.sh).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/scenario.sh"
require_jail
scenario_need "$SCEN_TOOLS/bin/casement" "$SCEN_TOOLS/bin/casement-probe" "$SCEN_TOOLS/bin/fake-logind"

export CASEMENT_TOOLS="$SCEN_TOOLS" CASEMENT_REPO="$SCEN_SIB/casement"
floor_make space-id-survives-restart   # the probe takes no power: an empty floor, so nothing waits on a question
# shellcheck source=/dev/null
source "$SCEN_SIB/casement/dev/lib/compositor.sh"
OUT_DIR=$(scenario_out space-id-survives-restart)
OUTPUTS='HEADLESS-1:1280x720@60000:120:0,0;HEADLESS-2:1280x720@60000:120:1280,0'
PROBE="$SCEN_TOOLS/bin/casement-probe"
STATE_A="$OUT_DIR/state-a"
STATE_B="$OUT_DIR/state-b"
rm -rf "$STATE_A" "$STATE_B"
mkdir -p "$STATE_A" "$STATE_B"

cleanup() { stop_compositor || true; }
trap cleanup EXIT

# ids_to FILE: the workspace ids the running casement announces, one per line in announce order.
ids_to() {
  "$PROBE" workspaces >"$1.json" || { echo "casement-probe workspaces failed:" >&2; cat "$1.json" >&2; return 1; }
  python3 -I -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    ws = json.loads(line)
    if ws.get("id") is None:
        sys.exit("a workspace has no id: " + line)
    print(ws["id"])
' "$1.json" >"$1"
}

# up STATE: a headless casement on the two outputs with STATE as its state home.
up() { start_compositor --outputs "$OUTPUTS" --state-home "$1" --system-dir "$FLOOR_DIR"; }

step_first() {
  up "$STATE_A" || return 1
  ids_to "$OUT_DIR/first.ids" || return 1
  local n; n=$(wc -l <"$OUT_DIR/first.ids")
  [ "$n" -ge 2 ] || { echo "expected at least one workspace per output (2), got $n" >&2; return 1; }
  [ "$(sort -u "$OUT_DIR/first.ids" | wc -l)" = "$n" ] || { echo "duplicate ids:" >&2; cat "$OUT_DIR/first.ids" >&2; return 1; }
  [ -s "$STATE_A/spaces.toml" ] || { echo "no $STATE_A/spaces.toml was written" >&2; return 1; }
}

step_restart() {
  stop_compositor || return 1
  up "$STATE_A" || return 1
  ids_to "$OUT_DIR/second.ids" || return 1
  diff -u "$OUT_DIR/first.ids" "$OUT_DIR/second.ids" >&2 || { echo "the ids changed across the restart" >&2; return 1; }
}

step_fresh() {
  stop_compositor || return 1
  up "$STATE_B" || return 1
  ids_to "$OUT_DIR/fresh.ids" || return 1
  local shared; shared=$(sort "$OUT_DIR/first.ids" "$OUT_DIR/fresh.ids" | uniq -d)
  [ -z "$shared" ] || { echo "a fresh state home got ids it should not share: $shared" >&2; return 1; }
}

STEP_BUDGET=60
step first step_first || true
step restart step_restart || true
step fresh step_fresh || true
steps_exit
