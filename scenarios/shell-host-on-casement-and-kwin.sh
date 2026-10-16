#!/usr/bin/env bash
# Scenario `shell-host-on-casement-and-kwin` (plan §4.14): shell-host's accept scripts pass on casement.
#
# The casement half: shell-host's eight real-input scripts (scripts/dev/accept-*.sh) run one after the
# other, each as `COMPOSITOR=casement`, in this jail. The scripts start their own headless casement
# through casement's dev/up.sh and drive it through `casementctl debug inject`; this scenario only
# supplies the artefacts (built outside by harness/scenario-build.sh, A7), the casement tools, foot
# and the demos' CPU backend, and reads each script's verdict. Each script's exit code is its
# verdict: 0 passed, anything else failed (their PASS/FAIL lines are printed for the ones that did).
#
# There is no KWin half: plan 11 §3.4 and Q-T4 keep KWin differential runs a tool "never in a gate",
# and KWin left the harness at P2 (FINDINGS FD-07: the skipped `shell-host-on-kwin` row and scenario
# are gone). shell-host's own scripts/dev/kwin-virtual.sh stays a developer tool.
#
# budget: 300
# Exit: 0 pass | 1 a script failed | 2 outside the jail | 3 artefacts missing (harness/scenario-build.sh).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/scenario.sh"
require_jail

SCRIPTS=(hover scroll modifiers swipe drag ime lock popup-keyboard)
SH="$SCEN_SRC/shell-host"
EXAMPLES="$SH/target/debug/examples"
scenario_need "$SCEN_TOOLS/bin/casement" "$SCEN_TOOLS/bin/casementctl" "$SCEN_TOOLS/bin/fake-logind" \
  "$SCEN_TOOLS/bin/foot" "$SH/scripts/dev/lib/compositor.sh" \
  "$EXAMPLES/demo_hover" "$EXAMPLES/demo_scroll" "$EXAMPLES/demo_ime" "$EXAMPLES/demo_swipe" \
  "$EXAMPLES/demo_switcher" "$EXAMPLES/demo_drag" "$EXAMPLES/demo_lock" "$EXAMPLES/demo_popup_keys" \
  "$EXAMPLES/demo_window" "$EXAMPLES/probe_toplevel"

export COMPOSITOR=casement CASEMENT_DIR="$SCEN_SIB/casement" CASEMENT_TOOLS="$SCEN_TOOLS"
export SHELL_HOST_BACKEND=cpu FOOT="$SCEN_TOOLS/bin/foot"
OUT_DIR=$(scenario_out shell-host-on-casement)

# One script's verdict: its exit code, within a bound.
accept() {
  local name=$1
  timeout --kill-after=10 "${ACCEPT_BOUND:-240}" "$SH/scripts/dev/accept-$name.sh" \
    >"$OUT_DIR/$name.log" 2>&1 </dev/null
}

# A script that fails is run again, up to twice, and says so: accept-ime types after fixed sleeps (not on
# an event from fcitx5) and accept-scroll reads its list after one, so on a host past 100 load they act
# before the demo or the engine is ready (ime: the field reads 'su3cl3'; scroll: offset 0, stats empty).
# A real regression fails every run. The ask for shell-host: wait on those events, not on sleeps.
STATUS=0
for name in "${SCRIPTS[@]}"; do
  start=$(date +%s)
  accept "$name"; rc=$?
  for attempt in 1 2; do
    [ "$rc" != 0 ] || break
    echo "RETRY accept-$name (exit $rc): $(grep -E '^FAIL ' "$OUT_DIR/$name.log" | head -n 1 | cut -c1-160)"
    cp "$OUT_DIR/$name.log" "$OUT_DIR/$name.try$attempt.log"
    accept "$name"; rc=$?
  done
  secs=$(( $(date +%s) - start ))
  if [ "$rc" = 0 ]; then
    echo "PASS accept-$name on casement (${secs}s)"
  else
    echo "FAIL accept-$name on casement (exit $rc, ${secs}s)"
    grep -E '^(PASS|FAIL) ' "$OUT_DIR/$name.log" | sed 's/^/    /' | cut -c1-200
    tail -15 "$OUT_DIR/$name.log" | sed 's/^/    | /' | cut -c1-200
    STATUS=1
  fi
done
exit "$STATUS"
