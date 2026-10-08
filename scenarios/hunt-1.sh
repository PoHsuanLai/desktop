#!/usr/bin/env bash
# Hunt 1: error paths of the add sheet, as a person meets them (accounts-hunt brief item 1).
#
#   boot      as accounts-generic-mail, plus "Dead Mail" (a brand file whose servers refuse connections)
#   cancel    Escape at the provider list; Escape and the Cancel button on the form; Back from the form
#   wrong     a wrong password on Fake Mail: the sheet says so, stays on the form, and a corrected password then adds
#   dead      Dead Mail: the servers are unreachable: the sheet says so (and does not hang)
#   twice     the same address added twice
#   drop      the asking app goes away while the sheet is open: the sheet goes
#   long      a 300-character address on the form and in the error
#
# budget: 400
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
OUT_DIR=$(scenario_out hunt-1)

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

# The form's buttons, in sheet coordinates (capture 3 of accounts-generic-mail): Back, Cancel, Continue.
BACK="1025 627"; CANCEL="1094 627"

# open_form PROVIDER-WORDS: the sheet opened, the provider picked by search and Return.
open_form() {
  acc_add_start org.quire.Mail
  sheet_await || return 1; sheet_settled; sleep 1
  sheet_type "$1"; sleep 0.5; sheet_key Enter; sleep 1.5
}

step_boot() { hunt_boot_mail; }

step_cancel() {
  local a
  # at the list
  acc_add_start org.quire.Mail
  sheet_await || return 1; sheet_settled; sleep 1
  sheet_key Escape; sleep 1
  a=$(add_answer 5); obs "Escape at the list: answer=$a sheet=$(sheet_state)"
  sheet_hidden || bug "the sheet is still drawn after Escape at the list"
  # on the form, Escape
  open_form Fake; sheet_shot c1-form
  sheet_key Escape; sleep 1
  a=$(add_answer 5); obs "Escape on the form: answer=$a sheet=$(sheet_state)"
  sheet_shot c2-after-escape-form
  if sheet_shown; then bug "Escape on the form leaves the sheet drawn (answer $a)"; sheet_key Escape; sleep 1; fi
  # on the form, the Cancel button
  open_form Fake
  sheet_click $CANCEL; sleep 1
  a=$(add_answer 5); obs "Cancel button on the form: answer=$a sheet=$(sheet_state)"
  sheet_shot c3-after-cancel-button
  if sheet_shown; then bug "the Cancel button on the form leaves the sheet drawn (answer $a)"; sheet_key Escape; sleep 1; fi
  # Back to the list
  open_form Fake
  sheet_click $BACK; sleep 1; sheet_shot c4-after-back
  sheet_key Escape; sleep 1
  a=$(add_answer 5); obs "Back, then Escape at the list: answer=$a sheet=$(sheet_state)"
  if sheet_shown; then sheet_key Escape; sleep 1; fi
  sheet_hidden
}

step_wrong() {
  local a
  open_form Fake
  sheet_type "$(rigj imap.user)"; sheet_key Tab; sheet_type "not-the-password"; sleep 0.3
  sheet_key Enter; sleep 1; sheet_shot w1-working
  sleep 3; sheet_shot w2-wrong-password
  a=$(add_answer 1); obs "wrong password: answer=$a sheet=$(sheet_state)"
  sheet_shown || { bug "the sheet is gone after a wrong password (answer $a)"; return 1; }
  # Correct it: select all in the focused field and type the right one.
  sheet_key a+ctrl; sheet_type "$(rigj imap.password)"; sleep 0.3; sheet_shot w3-retyped
  sheet_key Enter; sleep 3; sheet_shot w4-after-retry
  sheet_key Enter; sleep 1
  a=$(add_answer 15); obs "corrected password: answer=$a"
  case "$a" in *'"result":"added"'*) ;; *) bug "after a corrected password the add did not finish: $a (w3, w4 show it)"; sheet_key Escape; return 1 ;; esac
  sheet_gone
}

step_twice() {
  local a
  obs "accounts before the second add: $(accounts_now)"
  open_form Fake
  sheet_type "$(rigj imap.user)"; sheet_key Tab; sheet_type "$(rigj imap.password)"; sleep 0.3
  sheet_key Enter; sleep 3; sheet_shot t1-after-submit
  a=$(add_answer 1); obs "same address twice: answer=$a sheet=$(sheet_state)"
  if sheet_shown; then sheet_key Enter; sleep 1; sheet_shot t2-after-enter; a=$(add_answer 10); obs "same address twice, after Return on review: answer=$a"; fi
  obs "accounts after the second add: $(accounts_now)"
  sheet_shot t3-end
  if sheet_shown; then sheet_key Escape; sleep 1; fi
}

step_dead() {
  local a
  open_form Dead
  sheet_shot d1-form
  sheet_type "ada@dead.test"; sheet_key Tab; sheet_type "secret-pass"; sleep 0.3
  sheet_key Enter; sleep 1; sheet_shot d2-working
  sleep 6; sheet_shot d3-after-6s
  a=$(add_answer 1); obs "unreachable server: answer=$a sheet=$(sheet_state)"
  sheet_shown || { bug "the sheet is gone after the server was unreachable (answer $a)"; return 1; }
  sleep 10; sheet_shot d4-after-16s
  sheet_key Escape; sleep 1
  a=$(add_answer 3); obs "Escape after the error: answer=$a sheet=$(sheet_state)"
  if sheet_shown; then bug "Escape on the error leaves the sheet drawn"; sheet_key Escape; sleep 1; fi
}

step_drop() {
  open_form Fake
  sheet_type "$(rigj imap.user)"; sleep 0.3
  kill "$ADD_PID" 2>/dev/null; sleep 2
  obs "the asking app was killed with the form open: sheet=$(sheet_state)"
  sheet_shot x1-after-app-killed
  if sheet_shown; then bug "the sheet stays drawn after the app that asked went away"; sheet_key Escape; sleep 1; fi
  true
}

step_long() {
  local long a
  long=$(python3 -I -c 'print("a"*300)')
  open_form Fake
  sheet_type "$long@rig.test"; sheet_key Tab; sheet_type "pw"; sleep 0.5; sheet_shot l1-long-typed
  sheet_key Enter; sleep 4; sheet_shot l2-long-error
  a=$(add_answer 1); obs "300-char address: answer=$a sheet=$(sheet_state)"
  sheet_key Escape; sleep 1
  if sheet_shown; then sheet_key Escape; sleep 1; fi
  true
}

step_scan() { scan_end; }

run_steps step_boot step_cancel step_wrong step_twice step_dead step_drop step_long step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd daemon rig-servers secrets add; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
