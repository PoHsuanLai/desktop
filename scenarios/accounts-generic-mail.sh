#!/usr/bin/env bash
# Scenario `accounts-generic-mail` (accounts PLAN §8, design 31 §7.1): a password mail account is added through
# accountd's sheet as sill draws it, against fake IMAP and SMTP servers, and an app reaches the IMAP server through
# the daemon's authenticated relay. Real accountd, real sill on casement, the rig's fakes (porter-rig-servers) and
# its fake Secret Service; no network (harness/lib/accounts.sh says how each is set up).
#
#   boot      casement, a recorded private bus, the fakes (IMAP and SMTP over implicit TLS, a scratch CA that accountd
#             trusts through SSL_CERT_FILE), the fake Secret Service, accountd, sill; sill is the sheet host
#   list      an app asks AddAccount: sill draws the provider list (capture)
#   sign-in   "Fake" filters the list, Return picks it; the address and the password are typed (through the
#             compositor), Return sends them, the review step shows Mail, Return is Done: the Request's Response is 0
#   listed    accountd's settings module says the account is `ok` and labelled with the address
#   relay     an app (porter-rig-client) asks for Mail, the consent sheet is drawn (capture), Always Allow; the app's
#             open-authenticated gets a `* PREAUTH` greeting from the IMAP fake: the relay logged in, the app held no
#             password, and the audit file says proxy_opened without a value
#   scan      no planted secret outside the places the design lets it through (harness/lib/secret-scan.py)
#
# The provider is a brand file ("Fake Mail", discovery fixed) and not "Other..." (generic-imap): that provider
# finds servers by autoconfig over HTTPS on 443 or asks a host and dials 993 and 587, none of which a jail can
# bind (ports under 1024); the typed-port form of porter's manual-server answers it and sill's mapping of it is
# the open piece (see accounts-typed-server).
#
# budget: 180
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
OUT_DIR=$(scenario_out accounts-generic-mail)
ACCOUNT=fake-mail-ada-rig.test

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

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
}

step_list() {
  acc_add_start org.quire.Mail
  sheet_await || return 1
  sleep 1
  sheet_shot 1-provider-list || return 1
}

step_sign_in() {
  sheet_settled; sheet_type Fake; sleep 0.5
  sheet_key Enter; sleep 1
  sheet_shot 2-sign-in-form
  sheet_type "$(rigj imap.user)"; sheet_key Tab; sheet_type "$(rigj imap.password)"; sleep 0.5
  sheet_shot 3-sign-in-typed
  sheet_key Enter
  # The review step: wait for it by the sheet changing from the typed form.
  sleep 2; sheet_shot 4-review
  sheet_key Enter
  local response
  response=$(acc_add_response 30) || { echo "AddAccount never answered: $(cat "$OUT_DIR/add.log")" >&2; return 1; }
  case "$response" in '{"response": 0'*) ;; *) echo "AddAccount answered $response" >&2; return 1 ;; esac
  sheet_gone || return 1
  echo "added: $response" >&2
}

step_listed() {
  [ "$(settings_get "accounts.$ACCOUNT.state")" = ok ] || { echo "state is $(settings_get "accounts.$ACCOUNT.state")" >&2; return 1; }
  [ "$(settings_get "accounts.$ACCOUNT.label")" = "$(rigj imap.user)" ] || { echo "label is $(settings_get "accounts.$ACCOUNT.label")" >&2; return 1; }
}

step_relay() {
  rigc_bg "$OUT_DIR/grant.log" org.quire.Mail request-grant mail --class mail
  sheet_await || { cat "$OUT_DIR/grant.log" >&2; return 1; }
  sleep 1; sheet_shot 5-consent
  sheet_key Tab; sheet_key Enter            # Allow Once is first: Tab to Always Allow
  acc_wait 20 grep -q '"result"' "$OUT_DIR/grant.log" || { echo "request-grant never answered" >&2; return 1; }
  grep -q '"result":"granted"' "$OUT_DIR/grant.log" || { cat "$OUT_DIR/grant.log" >&2; return 1; }
  sheet_gone || return 1
  rigc org.quire.Mail open-authenticated mail --class mail --family imap >"$OUT_DIR/relay.log" 2>&1 || { cat "$OUT_DIR/relay.log" >&2; return 1; }
  grep -q '"greeting":"\* PREAUTH' "$OUT_DIR/relay.log" || { echo "no PREAUTH greeting: $(cat "$OUT_DIR/relay.log")" >&2; return 1; }
  grep -q proxy_opened "$STATE/quire/accountd/audit.jsonl" || { echo "no proxy_opened in the audit file:" >&2; cat "$STATE/quire/accountd/audit.jsonl" >&2; return 1; }
  echo "relay: $(cat "$OUT_DIR/relay.log")" >&2
}

step_scan() { scan_end; }

run_steps step_boot step_list step_sign_in step_listed step_relay step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd daemon rig-servers secrets add grant relay; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
