#!/usr/bin/env bash
# Scenario `accounts-settings` (design 31 §7.1, PLAN §2.5): detent's Accounts pane against the live accountd. Each
# control is clicked in the real window on casement (the window is placed by the compositor; clicks are relative to
# its frame, `casementctl debug windows`), and accountd's own state is what is checked afterwards, never detent's.
# Real accountd, sill (the compositor's shell, and the sheet host), detent at its pin, the rig's fake mail servers.
#
#   boot      casement, recorded bus, fakes, Secret Service, accountd, sill, detent (named org.quire.Settings, role
#             `settings`, with the programs' schema fixtures); the fake mail account added through the sheet, an app
#             (org.quire.Mail) granted Mail
#   open      Accounts in the sidebar, Manage on the account (capture of the list and of the account)
#   service   the Mail switch is turned off: accountd's `service.mail` row says so and the app that held the grant is
#             no longer offered the account (request-grant: none); turned on again, the account is back
#   keep      Remove account, then Keep: the account is still there (capture of the question)
#   revoke    Revoke on the app's row: the app's grants (porter-rig-client grants) are empty
#   remove    Remove account, then Remove account in the question: the account is gone from the registry and from
#             the settings module, and the audit file says removed
#   added     an account added through the sheet while detent is open shows in its pane (accountd sends Changed on an add)
#   sign-in   Sign in again on that account: accountd opens the sign-in sheet (Settings reauthenticates any account)
#   scan      the secret scan
#
# budget: 300
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
OUT_DIR=$(scenario_out accounts-settings)
ACCOUNT=fake-mail-ada-rig.test

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

mail_has_no_grants() { rigc org.quire.Mail grants | python3 -I -c 'import json,sys; sys.exit(0 if json.loads(sys.stdin.readline()).get("grants") == [] else 1)'; }
service_mail() { settings_get "accounts.$ACCOUNT.service.mail"; }
detent_mapped() { [ -n "$(detent_frame 2>/dev/null)" ]; }
no_account() { ! has_account; }
has_account() { settings_describe | python3 -I -c 'import json,sys; sys.exit(0 if any(k["path"].startswith("accounts.'"$ACCOUNT"'.") for k in json.load(sys.stdin)["key"]) else 1)'; }
# The controls, by role and accessible name (detent's labels; detent_press, harness/lib/accounts.sh). A row's
# buttons name the account or app they act on ("Manage Home cloud"), so they are pressed by their lead ("Manage …").
press_accounts() { detent_press option Accounts; }
press_manage() { detent_press button "Manage …"; }
press_mail_switch() { detent_press switch Mail; }
press_revoke() { detent_press button "Revoke …"; }
press_remove() { detent_press button "Remove account …"; }
press_sign_in_again() { detent_press button "Sign in again …"; }
# The question's buttons come after the page's own Remove account button in the document.
press_question_keep() { detent_press button Keep; }
press_question_remove() { detent_press button "Remove account …" -1; }

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
  sheet_grant org.quire.Mail mail mail grant || return 1
  detent_start
  acc_wait 30 detent_mapped || { echo "detent never mapped" >&2; tail -5 "$OUT_DIR/detent.log" >&2; return 1; }
  sleep 4
  detent_focus
}

step_open() {
  press_accounts; sleep 1; acc_shot 1-accounts-list
  press_manage; sleep 1; acc_shot 2-account
}

step_service() {
  local before after
  before=$(service_mail)
  press_mail_switch; sleep 1; acc_shot 3-mail-off
  after=$(service_mail)
  [ "$before" != "$after" ] || { echo "the Mail switch changed nothing in accountd (service.mail is still $before)" >&2; return 1; }
  rigc org.quire.Mail request-grant mail --class mail >"$OUT_DIR/off.log" 2>&1
  grep -q '"result":"none"' "$OUT_DIR/off.log" || { echo "with Mail off the app is still offered the account: $(cat "$OUT_DIR/off.log")" >&2; return 1; }
  press_mail_switch; sleep 1
  [ "$(service_mail)" = "$before" ] || { echo "turned on again, service.mail is $(service_mail), not $before" >&2; return 1; }
  rigc org.quire.Mail request-grant mail --class mail >"$OUT_DIR/on.log" 2>&1
  grep -q '"result":"granted"' "$OUT_DIR/on.log" || { echo "with Mail on again the app is not offered the account: $(cat "$OUT_DIR/on.log")" >&2; return 1; }
}

step_revoke() {
  press_revoke; sleep 1; acc_shot 4-revoked
  acc_wait 10 mail_has_no_grants \
    || { echo "the app still has grants: $(rigc org.quire.Mail grants)" >&2; return 1; }
}

step_keep() {
  press_remove; sleep 1; acc_shot 5-remove-question
  press_question_keep; sleep 1
  has_account || { echo "Keep removed the account" >&2; return 1; }
}

step_remove() {
  press_remove; sleep 1
  press_question_remove
  acc_wait 15 no_account || { echo "the account is still in the settings module after Remove" >&2; return 1; }
  sleep 1; acc_shot 6-removed
  grep -q "$ACCOUNT" "$STATE/porter/registry.json" && { echo "the registry still holds the account" >&2; return 1; }
  grep -q '"kind":"removed"' "$STATE/quire/accountd/audit.jsonl" || { echo "no removed event in the audit file" >&2; return 1; }
  return 0
}

# window_differs A B: the detent window of capture A differs from B's by more than 0.3% of its pixels (the rest of
# the output holds the bar's clock).
window_differs() {
  python3 -I - "$OUT_DIR/$1.png" "$OUT_DIR/$2.png" <<'PY'
import sys
from PIL import Image, ImageChops
box = (510, 198, 1410, 838)
a = Image.open(sys.argv[1]).convert("RGB").crop(box)
b = Image.open(sys.argv[2]).convert("RGB").crop(box)
diff = ImageChops.difference(a, b).convert("L").point(lambda v: 255 if v > 12 else 0)
share = sum(1 for v in diff.tobytes() if v) / (box[2] - box[0]) / (box[3] - box[1])
print("window differs by %.2f%%" % (share * 100), file=sys.stderr)
sys.exit(0 if share > 0.003 else 1)
PY
}

step_added_shows() {
  # A new account, added while detent is open, must show in its Accounts pane (accountd tells the pane).
  sheet_add_fake_mail || return 1
  has_account || { echo "accountd's settings module does not list the added account" >&2; return 1; }
  sleep 4; acc_shot 7-after-add
  window_differs 6-removed 7-after-add || {
    echo "detent still shows 'No accounts' 4 s after an account was added: accountd sent no SettingsModule1.Changed for it, so the pane never re-reads" >&2
    return 1
  }
}

step_sign_in() {
  press_accounts; sleep 1; press_manage; sleep 1; acc_shot 8-account-again
  press_sign_in_again; sleep 2; acc_shot 9-after-sign-in-again
  if sheet_shown; then sheet_shot 10-sign-in-again; sheet_key Escape; return 0; fi
  echo "Sign in again opened no sheet: $(grep reauthenticate "$OUT_DIR/accountd.log" | tail -n 1)" >&2
  return 1
}

step_scan() { scan_end; }

run_steps step_boot step_open step_service step_keep step_revoke step_remove step_added_shows step_sign_in step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd daemon detent rig-servers secrets add; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
