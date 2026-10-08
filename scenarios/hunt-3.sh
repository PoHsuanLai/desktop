#!/usr/bin/env bash
# Hunt 3: the consent window (accounts-hunt brief item 3).
#
#   boot      a fake mail account added through the sheet
#   at-once   two apps ask for Mail at the same moment: both get a window, one after the other, each answered on its own
#   lacks     an app asks for Calendar and Storage, kinds the only account lacks: what the person and the app see
#   names     an app with a long id, and one that is not a desktop id at all: how the window names it
#   keys      Shift-Tab from the first button, Tab wrapping, Return on each button
#   photos    CANNOT RUN: the Photos picker-only consent needs a Google account, and Google has no client in the jail
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
OUT_DIR=$(scenario_out hunt-3)

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

ask() { rigc_bg "$OUT_DIR/$2.log" "$1" request-grant "${3:-mail}" --class "${4:-mail}"; ASKED=$ACC_LAST; }
result_of() { acc_wait "${2:-10}" grep -q '"result"' "$OUT_DIR/$1.log" && head -n 1 "$OUT_DIR/$1.log" || echo none; }

step_boot() {
  hunt_boot_mail || return 1
  sheet_add_fake_mail || return 1
}

step_at_once() {
  local a b
  ask org.quire.One two1; ask org.quire.Two two2
  sheet_await || return 1; sleep 1.5; sheet_shot k1-first
  sheet_key Tab; sheet_key Enter; sleep 2
  a=$(result_of two1 6); b=$(result_of two2 3)
  obs "two at once, first answered Always: one=$a two=$b sheet=$(sheet_state)"
  sheet_shot k2-second
  if sheet_shown; then
    sheet_key Tab; sheet_key Tab; sheet_key Enter; sleep 2
    obs "second answered Don't Allow: two=$(result_of two2 6) sheet=$(sheet_state)"
  else
    bug "the second of two simultaneous requests drew no window (answer $b)"
  fi
  sheet_hidden
}

step_lacks() {
  local a
  ask org.quire.Cal lacks1 calendar calendar; sleep 3
  a=$(result_of lacks1 4); obs "Calendar asked, only mail exists: answer=$a sheet=$(sheet_state)"
  sheet_shot l1-calendar
  if sheet_shown; then sheet_key Escape; sleep 1; fi
  ask org.quire.Files lacks2 storage files; sleep 3
  a=$(result_of lacks2 4); obs "Storage asked, only mail exists: answer=$a sheet=$(sheet_state)"
  sheet_shot l2-storage
  if sheet_shown; then sheet_key Escape; sleep 1; fi
  true
}

step_names() {
  ask org.quire.ATerriblyLongApplicationNameThatKeepsGoingAndGoingAndGoingOnAndOn n1
  sheet_await || return 1; sleep 1.5; sheet_shot m1-long-id
  sheet_key Escape; sleep 1
  ask com.example.some_thing-else n2
  sheet_await || return 1; sleep 1.5; sheet_shot m2-foreign-id
  sheet_key Escape; sleep 1
  ask org.quire.Agent.claude-code n3
  sheet_await || return 1; sleep 1.5; sheet_shot m3-agent-id
  sheet_key Escape; sleep 1
  true
}

step_keys() {
  ask org.quire.K k1
  sheet_await || return 1; sleep 1.5
  sheet_key Tab+shift; sleep 0.3; sheet_shot y1-shift-tab
  sheet_key Tab+shift; sleep 0.3; sheet_shot y2-shift-tab-2
  sheet_key Tab; sheet_key Tab; sheet_key Tab; sleep 0.3; sheet_shot y3-three-tabs
  sheet_key Escape; sleep 1
  ask org.quire.K k2
  sheet_await || return 1; sleep 1.5
  sheet_key Tab; sheet_key Tab; sleep 0.3
  sheet_key Space; sleep 1.5
  obs "Space on Don't Allow: answer=$(result_of k2 5) sheet=$(sheet_state)"
  if sheet_shown; then sheet_key Escape; sleep 1; fi
  true
}

step_scan() { scan_end; }

run_steps step_boot step_at_once step_lacks step_names step_keys step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd daemon rig-servers secrets add; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
