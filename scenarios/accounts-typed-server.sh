#!/usr/bin/env bash
# Scenario `accounts-typed-server` (porter's manual-server form, accounts PLAN §8): when the lookup of an address finds no
# server, accountd asks for one by hand (protocol, host, security, port, outgoing server, login name) and the account added
# from it logs in through the relay. The server is the rig's fake POP3 with STARTTLS on its own port, the outgoing one its
# fake SMTP with STARTTLS; real accountd (porter branch rig-syncd, which has the form), the rig's fake Secret Service.
#
# sill cannot draw this form yet: its pin maps neither the new FieldKind variants (Protocol, Port, Security,
# OutgoingServer, OutgoingPort, OutgoingSecurity, SessionUrl) nor ProblemKind::Invalid (sill accounts_sheet/props.rs).
# So the sheet host here is a STAND-IN (harness/lib/sheet-standin.py): it owns org.quire.AccountsSheet1 as sill does
# (named `sill-shell.scope`, the caller table's sheet_host), logs each view accountd opens or updates, and sends the
# Input signals this script gives it. What this proves is accountd's side of the form over the sheet's bus interface; it
# does not prove sill draws it. When sill's pin maps the form, the scenario should drive sill's sheet instead (sheet_type
# and sheet_key, as accounts-generic-mail does).
#
# The address is a Fastmail one on purpose: the lookup runs offline in the jail, and a lookup that cannot reach anything
# is answered `failed: unreachable` (no form) -- the typed form is offered only when the lookup MISSES. An address a shipped
# provider claims (fastmail.com) is answered `Outcome::Provider` by the search without any network, which the generic
# sign-in turns into "ask for the servers" (porter-families generic/mail.rs `look`).
#
#   boot      a private bus, the fakes (POP3 and SMTP, STARTTLS), the Secret Service, accountd, the stand-in
#   form      AddAccount for generic-imap: the address and password form; submitting a claimed address's answers
#             brings the typed-server form (a field of kind protocol)
#   typed     protocol pop3, host, STARTTLS, the fake's port, outgoing host and port, STARTTLS, the login name: the
#             review step shows Mail; Confirm: Response 0
#   relay     an app asks for Mail (the consent view goes to the stand-in, answered Always Allow) and opens an
#             authenticated relay to the POP3 server: the relay logs in (USER and PASS with the planted password, which
#             the app never held) and greets the app `+OK porter relay ready`
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
WL=
VIEWS=

cleanup() { acc_stop_all; stop_private_bus; scratch_drop; }
trap cleanup EXIT

# The porter in the build has the form (a build of porter without it makes this scenario a skip).
grep -q 'Protocol,' "$SCEN_BUILD/pin/porter-rig/crates/porter-core/src/sheet/fields.rs" || {
  echo "SKIP accounts-typed-server: porter has no typed mail server form (FieldKind::Protocol)" >&2; exit 2; }

# last_view: the last view the stand-in was shown, as JSON.
last_view() { tail -n 1 "$VIEWS" 2>/dev/null; }
# view_has PATTERN: the last view matches.
view_has() { last_view | grep -q -- "$1"; }
# send JSON: an Input from the sheet host.
send() { printf 'send %s\n' "$1" >"$RIG_DIR/cmds"; }
plain() { printf '{"kind":"%s","value":{"kind":"plain","v":"%s"}}' "$1" "$2"; }

step_boot() {
  start_private_bus || return 1
  scratch_new; acc_dirs
  OUT_BUS=$BUS
  scan_begin
  rig_start --pop3 --smtp --tls starttls || return 1
  secrets_start || return 1
  acc_config
  accountd_start || return 1
  mkfifo "$RIG_DIR/cmds"
  VIEWS="$OUT_DIR/views.jsonl"
  acc_bg "$OUT_DIR/standin.log" python3 -I "$HARNESS_LIB/sheet-standin.py" --bus "$BUS" --proc "$PROC" --log "$VIEWS" --commands "$RIG_DIR/cmds"
  acc_wait 15 grep -q ready "$OUT_DIR/standin.log" || { cat "$OUT_DIR/standin.log" >&2; return 1; }
}

step_form() {
  acc_add_start org.quire.Mail generic-imap
  acc_wait 20 view_has '"kind": "sign_in"' || { echo "no sign-in form: $(last_view)" >&2; return 1; }
  send "{\"kind\":\"submit\",\"v\":[$(plain address ada@fastmail.com),{\"kind\":\"password\",\"value\":{\"kind\":\"secret\",\"v\":\"$(rigj pop3.password)\"}}]}"
  acc_wait 20 view_has '"kind": "protocol"' || { echo "the typed-server form never came; the view is: $(last_view | cut -c1-300)" >&2; return 1; }
}

step_typed() {
  local imap_port smtp_port
  imap_port=$(rigj pop3.port); smtp_port=$(rigj smtp.port)
  send "{\"kind\":\"submit\",\"v\":[$(plain protocol pop3),$(plain server 127.0.0.1),$(plain security starttls),$(plain port "$imap_port"),$(plain outgoing_server 127.0.0.1),$(plain outgoing_security starttls),$(plain outgoing_port "$smtp_port"),$(plain username "$(rigj pop3.user)")]}"
  acc_wait 30 view_has '"kind": "review"' || { echo "no review step: $(last_view | cut -c1-400)" >&2; return 1; }
  send '{"kind":"confirm","v":[{"kind":"mail","toggle":"on"}]}'
  local response
  response=$(acc_add_response 30) || { echo "AddAccount never answered: $(cat "$OUT_DIR/add.log")" >&2; return 1; }
  case "$response" in '{"response": 0'*) ;; *) echo "AddAccount answered $response" >&2; return 1 ;; esac
  ACCOUNT=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["results"]["account"])' "$response")
  echo "added $ACCOUNT" >&2
}

step_relay() {
  rigc_bg "$OUT_DIR/grant.log" org.quire.Mail request-grant mail --class mail
  acc_wait 20 view_has '"kind": "consent"' || { echo "no consent view: $(last_view | cut -c1-300)" >&2; return 1; }
  send "{\"kind\":\"answer\",\"v\":{\"kind\":\"allow\",\"v\":{\"account\":\"$ACCOUNT\",\"scope\":\"always\"}}}"
  acc_wait 20 grep -q '"result":"granted"' "$OUT_DIR/grant.log" || { cat "$OUT_DIR/grant.log" >&2; return 1; }
  rigc org.quire.Mail open-authenticated mail --class mail --family pop3 >"$OUT_DIR/relay.log" 2>&1 || { cat "$OUT_DIR/relay.log" >&2; return 1; }
  grep -q '"greeting":"+OK porter relay ready' "$OUT_DIR/relay.log" || { echo "no relay greeting: $(cat "$OUT_DIR/relay.log")" >&2; return 1; }
  echo "relay: $(cat "$OUT_DIR/relay.log")" >&2
}

step_scan() { scan_end; }

run_steps step_boot step_form step_typed step_relay step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd standin rig-servers secrets add grant relay; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
