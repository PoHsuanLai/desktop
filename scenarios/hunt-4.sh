#!/usr/bin/env bash
# Hunt 4: detent's Accounts pane (accounts-hunt brief item 4 and the a11y half of 5).
#
#   boot      nine fake mail accounts typed through the sheet, a Claude Code account (needs_login), grants for two apps,
#             detent open
#   list      the Accounts page: every row, in what order, how it scrolls; the probe listing (role and name of every control)
#   manage    Manage on the first account, and on the agent account: rows, switches, grants, expires row (captures, listing)
#   restart   accountd stopped and started again with detent open: what the pane shows meanwhile and after
#   keys      Tab through the pane: focus visible, order
#
# budget: 900
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
OUT_DIR=$(scenario_out hunt-4)

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

detent_mapped() { [ -n "$(detent_frame 2>/dev/null)" ]; }
# add_mail ADDRESS: Fake Mail added through the sheet under that address (the password is the rig's).
add_mail() {
  acc_add_start org.quire.Mail
  sheet_await || return 1; sheet_settled; sleep 0.5
  sheet_type Fake; sleep 0.4; sheet_key Enter; sleep 1
  sheet_type "$1"; sheet_key Tab; sheet_type "$(rigj imap.password)"; sleep 0.3
  sheet_key Enter; sleep 2; sheet_key Enter
  acc_add_response 30 >/dev/null || return 1
  sheet_gone
}
listing() { detent_listing >"$OUT_DIR/$1.tsv"; }

step_boot() {
  hunt_boot_mail || return 1
  local i
  for i in 1 2 3 4 5 6 7 8 9; do add_mail "user$i@rig.test" || { echo "adding user$i failed" >&2; return 1; }; done
  acc_add_start org.quire.Mail
  sheet_await || return 1; sheet_settled; sleep 0.5
  sheet_type "Claude Code"; sleep 0.4; sheet_key Enter; sleep 2; sheet_key Enter
  acc_add_response 20 >/dev/null; sheet_gone || return 1
  obs "accounts: $(accounts_now)"
  sheet_grant org.quire.Mail mail mail g1 || return 1
  sheet_grant org.quire.Calendar mail mail g2 || return 1
  detent_start
  acc_wait 30 detent_mapped || { echo "detent never mapped" >&2; tail -5 "$OUT_DIR/detent.log" >&2; return 1; }
  sleep 4
  detent_focus
}

step_list() {
  detent_press option Accounts; sleep 1.5
  acc_shot 1-list; listing 1-list
  # scroll: the page is long; PageDown/End through the focused window
  dkey Tab; sleep 0.3; acc_shot 1b-first-tab
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do dkey Tab; done; sleep 0.5; acc_shot 1c-twelve-tabs; listing 1c-twelve-tabs
  dkey End; sleep 0.8; acc_shot 1d-end; listing 1d-end
  obs "controls on the list: $(wc -l <"$OUT_DIR/1-list.tsv")"
}

step_manage() {
  detent_press button Manage; sleep 1.5
  acc_shot 2-manage; listing 2-manage
  dkey End; sleep 0.8; acc_shot 2b-manage-end; listing 2b-manage-end
}

step_restart() {
  accountd_stop; sleep 3; acc_shot 3-accountd-down; listing 3-accountd-down
  accountd_start || return 1
  sleep 5; acc_shot 4-accountd-back; listing 4-accountd-back
}

step_scan() { scan_end; }

run_steps step_boot step_list step_manage step_restart step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd daemon detent rig-servers secrets add; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
