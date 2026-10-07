#!/usr/bin/env bash
# Scenario `accounts-consent` (design 31 §7.1 item on consent): an app asks for Mail, sill draws the consent sheet
# (captured), and each answer gives the right grant, or none; a second request after Always asks nothing.
# Real accountd, sill on casement, the fake IMAP/SMTP and Secret Service of porter's rig. Each case is its own
# app id (porter-rig-client --app-id), so one answer cannot stand in for another.
#
#   boot      as accounts-generic-mail, and the account added through the sheet (sheet_add_fake_mail)
#   always    Always Allow: granted, the grant is `always`; the same app asks again: granted at once, no sheet drawn
#   once      Allow Once: granted, the grant is `once`; the app uses it (a relay opens: PREAUTH); a used once-grant is
#             spent (design: "for one use; accountd drops it after that use"), so its next request must ask again
#   deny      Don't Allow: refused, and the answer is remembered as a refusal: the next request is refused, no sheet
#   escape    Escape: refused, nothing is stored, the next request asks again (the sheet is drawn again)
#   scan      the secret scan (harness/lib/secret-scan.py)
#
# budget: 240
# Exit: 0 pass | 1 a step failed | 2 outside the jail | 3 artefacts missing (harness/scenario-build.sh --accounts).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/scenario.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/accounts.sh"
require_jail
acc_need
acc_env
# shellcheck source=/dev/null
source "$SCEN_BUILD/pin/sill/dev/lib/all.sh"
OUT_DIR=$(scenario_out accounts-consent)

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

# ask APP LOG: a request-grant for Mail as APP, in the background, its output in LOG.
ask() { rigc_bg "$OUT_DIR/$2.log" "$1" request-grant mail --class mail; ASKED=$ACC_LAST; }
# answered LOG: waits for the client's one result line; prints it.
answered() { acc_wait 20 grep -q '"result"' "$OUT_DIR/$1.log" || { echo "no answer in $1.log: $(cat "$OUT_DIR/$1.log")" >&2; return 1; }; head -n 1 "$OUT_DIR/$1.log"; }
# grants_of APP: the app's grants as JSON lines.
grants_of() { rigc "$1" grants; }
# grant_field APP FIELD: the first grant's field (scope, decision), or `none`.
grant_field() {
  grants_of "$1" | python3 -I -c '
import json, sys
g = json.loads(sys.stdin.readline()).get("grants", [])
print(g[0][sys.argv[1]] if g else "none")' "$2"
}

step_boot() {
  start_compositor || return 1
  scratch_new; acc_dirs
  build || return 1
  scan_begin
  rig_start --imap --smtp --tls implicit || return 1
  secrets_start || return 1
  acc_config; acc_fake_mail_provider
  accountd_start || return 1
  sill_start || return 1
  sheet_add_fake_mail || return 1
}

step_always() {
  local app=org.quire.Always out
  ask $app always1
  sheet_await || return 1; sleep 1; sheet_shot 1-consent
  sheet_key Tab; sheet_key Enter
  out=$(answered always1) || return 1
  case "$out" in *'"result":"granted"'*'"already":false'*|*'"already":false'*'"result":"granted"'*) ;; *) echo "not granted: $out" >&2; return 1 ;; esac
  sheet_gone || return 1
  [ "$(grant_field $app scope)" = always ] || { echo "the grant is $(grant_field $app scope), not always" >&2; return 1; }
  ask $app always2
  out=$(answered always2) || return 1
  case "$out" in *'"already":true'*) ;; *) echo "the second request was not answered from the grant: $out" >&2; return 1 ;; esac
  sheet_hidden || { echo "a sheet was drawn for the second request" >&2; return 1; }
}

step_once() {
  local app=org.quire.Once out
  ask $app once1
  sheet_await || return 1; sleep 1
  sheet_key Enter                                  # Allow Once is first
  out=$(answered once1) || return 1
  case "$out" in *'"result":"granted"'*) ;; *) echo "not granted: $out" >&2; return 1 ;; esac
  sheet_gone || return 1
  [ "$(grant_field $app scope)" = once ] || { echo "the grant is $(grant_field $app scope), not once" >&2; return 1; }
  rigc $app open-authenticated mail --class mail --family imap >"$OUT_DIR/once-use.log" 2>&1 \
    && grep -q PREAUTH "$OUT_DIR/once-use.log" || { echo "the once-grant did not open a relay: $(cat "$OUT_DIR/once-use.log")" >&2; return 1; }
  # Used once: spent.
  [ "$(grant_field $app scope)" = none ] || { echo "a once-grant is still there after its use (scope $(grant_field $app scope)): it opens relays again and again" >&2; return 1; }
}

step_deny() {
  local app=org.quire.Never out
  ask $app deny1
  sheet_await || return 1; sleep 1
  sheet_key Tab; sheet_key Tab; sheet_key Enter    # Don't Allow is third
  out=$(answered deny1) || return 1
  case "$out" in *'"result":"refused"'*) ;; *) echo "not refused: $out" >&2; return 1 ;; esac
  sheet_gone || return 1
  ask $app deny2
  out=$(answered deny2) || return 1
  case "$out" in *'"result":"none"'*|*'"result":"refused"'*) ;; *) echo "the second request after Don't Allow was: $out" >&2; return 1 ;; esac
  sheet_hidden || { echo "a sheet was drawn after Don't Allow" >&2; return 1; }
}

step_escape() {
  local app=org.quire.Esc out
  ask $app esc1
  sheet_await || return 1; sleep 1
  sheet_key Escape
  out=$(answered esc1) || return 1
  case "$out" in *'"result":"refused"'*) ;; *) echo "Escape was not a refusal: $out" >&2; return 1 ;; esac
  sheet_gone || return 1
  [ "$(grant_field $app decision)" = none ] || { echo "Escape stored $(grant_field $app decision)" >&2; return 1; }
  ask $app esc2
  sheet_await || { echo "the request after Escape did not ask again" >&2; return 1; }
  sheet_key Escape
  answered esc2 >/dev/null || return 1
  sheet_gone
}

step_scan() { scan_end; }

run_steps step_boot step_always step_once step_deny step_escape step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd daemon rig-servers secrets add; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
