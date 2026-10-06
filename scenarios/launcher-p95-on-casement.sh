#!/usr/bin/env bash
# Scenario `launcher-p95-on-casement` (plan 20 §5.2, P0 exit): sill's launcher opens in under 100 ms
# (p95) over 20 toggles on casement, in the jail.
#
# sill's own accept-launcher measures it (`dev/accept/launcher.sh --only toggle`: 20 `sill launcher
# toggle` round trips, each timed on the daemon's side). That script enforces its budget only on a
# release build on a quiet host and otherwise prints the figure and passes; a phase gate must not pass
# silently, so this scenario reads the printed `p95 N ms` and fails when N is 100 or more, or when no
# figure was printed, whatever the build and the load. The script's own verdict must be 0 too.
#
# budget: 240
# Exit: 0 pass | 1 over budget, no figure, or the script failed | 2 outside the jail | 3 artefacts missing.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/scenario.sh"
require_jail
scenario_need "$SCEN_TOOLS/bin/casement" "$SCEN_TOOLS/bin/casementctl" "$SCEN_TOOLS/bin/fake-logind" \
  "$SCEN_BUILD/sill-target/debug/sill"

BUDGET_MS=100
export SILL_COMPOSITOR=casement SILL_PREBUILT=1 SILL_PROFILE=debug
export CARGO_TARGET_DIR="$SCEN_BUILD/sill-target" CASEMENT_REPO="$SCEN_SIB/casement" CASEMENT_TOOLS="$SCEN_TOOLS"
OUT_DIR=$(scenario_out launcher-p95)

rc=0
"$SCEN_SRC/sill/dev/accept/launcher.sh" --only toggle >"$OUT_DIR/launcher.log" 2>&1 </dev/null || rc=$?
cat "$OUT_DIR/launcher.log"

p95=$(sed -n 's/.*p50 [0-9.]* ms, p95 \([0-9.]*\) ms, max .*/\1/p' "$OUT_DIR/launcher.log" | tail -n 1)
if [ -z "$p95" ]; then echo "FAIL no 'p50 .. p95 .. max' line: the toggle step did not measure (launcher.sh exit $rc)"; exit 1; fi
python3 -c "import sys; sys.exit(0 if float('$p95') < $BUDGET_MS else 1)" \
  || { echo "FAIL launcher open p95 $p95 ms is not under $BUDGET_MS ms"; exit 1; }
if [ "$rc" != 0 ]; then echo "FAIL launcher.sh --only toggle exited $rc (p95 $p95 ms was in budget)"; exit 1; fi
echo "PASS launcher open p95 $p95 ms < $BUDGET_MS ms over 20 toggles on casement"
