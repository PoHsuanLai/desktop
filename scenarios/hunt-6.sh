#!/usr/bin/env bash
# Hunt 6: the dark theme on every accounts screen (accounts-hunt brief item 6): text contrast, icons, clipped or overlapping text.
# The light theme's captures are the other probes'. Same walk as hunt-1/2/3/4 in one boot.
#
#   boot      theme = "dark" written before anything starts; a fake mail account added through the sheet
#   sheet     provider list, form, error (Microsoft without a client), browser wait, review
#   consent   the consent window
#   detent    the Accounts page, one account, the remove question
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
OUT_DIR=$(scenario_out hunt-6)
HUNT_THEME=${HUNT_THEME:-dark}

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

detent_mapped() { [ -n "$(detent_frame 2>/dev/null)" ]; }

step_boot() {
  hunt_boot_mail || return 1
  sheet_add_fake_mail || return 1
}

step_sheet() {
  acc_add_start org.quire.Mail
  sheet_await || return 1; sheet_settled; sleep 1
  sheet_shot s1-list
  sheet_type Micro; sleep 0.5; sheet_key Enter; sleep 2; sheet_shot s2-no-client
  sheet_key Escape; sleep 1
  acc_add_start org.quire.Mail
  sheet_await || return 1; sheet_settled; sleep 1
  sheet_type Fake; sleep 0.4; sheet_key Enter; sleep 1.2; sheet_shot s3-form
  sheet_type "$(rigj imap.user)"; sheet_key Tab; sheet_type "$(rigj imap.password)"; sleep 0.4
  sheet_key Enter; sleep 2.5; sheet_shot s4-review
  sheet_key Escape; sleep 1
  true
}

step_consent() {
  rigc_bg "$OUT_DIR/c.log" org.quire.Mail request-grant mail --class mail
  sheet_await || return 1; sleep 1.5; sheet_shot c1-consent
  sheet_key Tab; sheet_key Enter; sleep 1.5
}

step_detent() {
  detent_start
  acc_wait 30 detent_mapped || { echo "detent never mapped" >&2; return 1; }
  sleep 4; detent_focus
  detent_press option Accounts; sleep 1.5; acc_shot d1-list
  detent_press button Manage; sleep 1.5; acc_shot d2-account
  detent_press button "Remove account"; sleep 1; acc_shot d3-question
}

step_scan() { scan_end; }

run_steps step_boot step_sheet step_consent step_detent step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd daemon detent rig-servers secrets add; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
