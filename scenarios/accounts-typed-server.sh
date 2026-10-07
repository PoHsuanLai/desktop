#!/usr/bin/env bash
# Scenario `accounts-typed-server` (porter's manual-server form, accounts PLAN §8): when the lookup of an address finds no
# server, accountd asks for one by hand (protocol, host, security, port, outgoing server, login name) and the account added
# from it logs in through the relay. sill draws the form (its dd048640 maps the new fields) and the scenario fills it in with
# clicks and keys; the server is the rig's fake POP3 with STARTTLS on its own port, the outgoing one its fake SMTP with
# STARTTLS. Real accountd, sill on casement, the rig's fake Secret Service.
#
# The address is a Fastmail one on purpose: the lookup runs offline in the jail, and a lookup that cannot reach anything
# is answered `failed: unreachable` (no form) -- the typed form is offered only when the lookup MISSES. An address a shipped
# provider claims (fastmail.com) is answered `Outcome::Provider` by the search without any network, which the generic
# sign-in turns into "ask for the servers" (porter-families generic/mail.rs `look`).
#
# After a pop-up's value is chosen the sheet takes no keys until it is clicked again (Tab and typed text are lost), so each
# field is focused with a click (positions are the sheet's, the output being 1920x1080).
#
#   boot      casement, recorded bus, the fakes (POP3 and SMTP, STARTTLS), Secret Service, accountd, sill
#   form      AddAccount for generic-imap: the address and password form (capture); submitting a claimed address brings
#             the typed-server form (capture): the protocol pop-up reads IMAP and the server is guessed imap.fastmail.com
#   typed     POP3 chosen (the server guess becomes pop.fastmail.com), the host, STARTTLS, the fake's port, the outgoing
#             host, STARTTLS and port, the login name; Continue; the review step shows Mail (capture); Done: `added`
#   relay     an app asks for Mail (the consent sheet, Always Allow) and opens an authenticated relay to the POP3 server:
#             the relay logs in (the POP3 fake's attempts lever lists one accepted login as the account's user, with the
#             password the app never held) and greets the app `+OK porter relay ready`
#   scan      the secret scan
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
OUT_DIR=$(scenario_out accounts-typed-server)

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

# The porter in the build has the form.
grep -q 'Protocol,' "$SCEN_BUILD/pin/porter/crates/porter-core/src/sheet/fields.rs" || {
  echo "SKIP accounts-typed-server: porter has no typed mail server form (FieldKind::Protocol)" >&2; exit 2; }

# Where the form's controls are (sheet coordinates): pop-ups, their items below them, text fields, Continue.
PROTOCOL="907 362"; SERVER="1025 410"; SECURITY="922 458"; PORT="1025 506"
OUT_SERVER="1025 596"; OUT_SECURITY="922 644"; OUT_PORT="1025 692"; USER="1025 783"; CONTINUE="1177 859"
# shellcheck disable=SC2086
click() { sheet_click $1; }
# shellcheck disable=SC2086
replace() { sheet_replace $1 "$2"; }

step_boot() {
  start_compositor || return 1
  scratch_new; acc_dirs
  build || return 1
  scan_begin
  rig_start --pop3 --smtp --tls starttls || return 1
  secrets_start || return 1
  acc_config
  accountd_start || return 1
  sill_start || return 1
}

step_form() {
  acc_add_start org.quire.Mail generic-imap
  sheet_await || return 1; sheet_settled; sleep 1
  sheet_shot 1-address-and-password
  sheet_type ada@fastmail.com; sheet_key Tab; sheet_type "$(rigj pop3.password)"; sheet_key Enter; sleep 3
  sheet_shot 2-typed-form
  [ "$(opaque_pixels "$OUT_DIR/2-typed-form.png")" -gt 1000 ] || return 1
}

step_typed() {
  click "$PROTOCOL"; sheet_key ArrowDown; sheet_key Enter; sleep 1; sheet_shot 3-pop3
  replace "$SERVER" 127.0.0.1
  # The Security pop-up redraws the form below it: a field typed before that settles is lost (seen under a loaded gate).
  click "$SECURITY"; sheet_key ArrowDown; sheet_key Enter; sleep 1.5
  replace "$PORT" "$(rigj pop3.port)"
  replace "$OUT_SERVER" 127.0.0.1
  click "$OUT_SECURITY"; sheet_key ArrowDown; sheet_key Enter; sleep 1.5
  replace "$OUT_PORT" "$(rigj smtp.port)"
  replace "$USER" "$(rigj pop3.user)"
  sheet_shot 4-filled
  click "$CONTINUE"; sleep 3; sheet_shot 5-review
  sheet_key Enter
  local response
  response=$(acc_add_response 30) || { echo "AddAccount never answered: $(cat "$OUT_DIR/add.log")" >&2; return 1; }
  acc_added "$response" || { echo "AddAccount answered $response (captures 4 and 5 show the form and the step after it)" >&2; return 1; }
  sheet_gone || return 1
  echo "added $ACCOUNT" >&2
}

step_relay() {
  rigc_bg "$OUT_DIR/grant.log" org.quire.Mail request-grant mail --class mail
  sheet_await || { cat "$OUT_DIR/grant.log" >&2; return 1; }
  sleep 1; sheet_key Tab; sheet_key Enter
  acc_wait 20 grep -q '"result":"granted"' "$OUT_DIR/grant.log" || { cat "$OUT_DIR/grant.log" >&2; return 1; }
  # The account must carry the ports typed in step_typed: a default port here means a typed field was lost, not a relay fault.
  grep -q "127.0.0.1:$(rigj pop3.port)" "$OUT_DIR/grant.log" || { echo "the account's POP3 endpoint is not the typed port $(rigj pop3.port) (step_typed lost a field; capture 4 shows the form): $(cat "$OUT_DIR/grant.log")" >&2; return 1; }
  sheet_gone || return 1
  rigc org.quire.Mail open-authenticated mail --class mail --family pop3 >"$OUT_DIR/relay.log" 2>&1 || { cat "$OUT_DIR/relay.log" >&2; return 1; }
  grep -q '"greeting":"+OK porter relay ready' "$OUT_DIR/relay.log" || { echo "no relay greeting: $(cat "$OUT_DIR/relay.log")" >&2; return 1; }
  rigctl GET /pop3/attempts | grep -q '"outcome":"accepted"' || { echo "the POP3 fake saw no accepted login: $(rigctl GET /pop3/attempts)" >&2; return 1; }
  rigctl GET /pop3/attempts | grep -q "\"user\":\"$(rigj pop3.user)\"" || { echo "the login was not as $(rigj pop3.user): $(rigctl GET /pop3/attempts)" >&2; return 1; }
  echo "relay: $(cat "$OUT_DIR/relay.log")" >&2
}

step_scan() { scan_end; }

run_steps step_boot step_form step_typed step_relay step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd daemon rig-servers secrets add grant relay; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
