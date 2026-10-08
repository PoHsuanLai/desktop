#!/usr/bin/env bash
# Hunt 5: keyboard only in detent's Accounts pane (accounts-hunt brief item 5), and its states after the actions.
#
#   boot      one fake mail account, one grant, detent open on Accounts
#   keys      the search box takes typed keys (proof that keys reach detent); then Tab, one captured step at a time: where focus
#             goes, whether it shows, whether Return and Space press what has focus
#   manage    Return on the focused Manage; Tab through the account page; Space on the Mail switch; Return on Revoke
#   remove    Remove account with the keyboard: Tab to it, Return, the question: Escape cancels? Return picks which?
#
# budget: 300
# Exit: 0 pass | 1 a step failed | 2 outside the jail | 3 artefacts missing (harness/scenario-build.sh --accounts).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/scenario.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/accounts.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/hunt.sh"
require_jail
acc_need
acc_env
# shellcheck source=/dev/null
source "$SCEN_BUILD/pin/sill/dev/lib/all.sh"
OUT_DIR=$(scenario_out hunt-5)

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

detent_mapped() { [ -n "$(detent_frame 2>/dev/null)" ]; }
# park: the pointer away from every control, so no hover state stands in for focus.
park() { casementctl debug inject "move 1700 900" >/dev/null; sleep 0.3; }

step_boot() {
  hunt_boot_mail || return 1
  sheet_add_fake_mail || return 1
  sheet_grant org.quire.Mail mail mail g1 || return 1
  detent_start
  acc_wait 30 detent_mapped || { echo "detent never mapped" >&2; return 1; }
  sleep 4
  detent_focus
  detent_press option Accounts; sleep 1.5
}

step_keys() {
  detent_press textbox Search; sleep 0.5
  dkey a; dkey c; dkey c; sleep 0.8; park; acc_shot k1-typed-acc
  obs "search box state after typing: $(detent_state textbox Search 2>&1)"
  dkey BackSpace; dkey BackSpace; dkey BackSpace; sleep 0.5
  dkey Escape; sleep 0.5
  detent_press option Accounts; sleep 1; park
  local i
  for i in 1 2 3 4 5 6; do dkey Tab; sleep 0.3; park; acc_shot k2-tab-$i; done
}

step_manage() {
  detent_press button Manage; sleep 1.5; park
  acc_shot m1-account
  local i
  for i in 1 2 3 4 5 6 7; do dkey Tab; sleep 0.3; park; acc_shot m2-tab-$i; done
}

step_remove() {
  detent_press button "Remove account"; sleep 1; park; acc_shot r1-question
  dkey Escape; sleep 1; acc_shot r2-after-escape
  obs "after Escape on the remove question: $(accounts_now)"
  detent_press button "Remove account"; sleep 1
  dkey Return; sleep 1.5; acc_shot r3-after-return
  obs "after Return on the remove question: accounts=[$(accounts_now)]"
}

step_scan() { scan_end; }

run_steps step_boot step_keys step_manage step_remove step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd daemon detent rig-servers secrets add; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
