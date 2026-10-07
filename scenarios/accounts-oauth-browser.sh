#!/usr/bin/env bash
# Scenario `accounts-oauth-browser` (design 31 §7.1): a Microsoft-shaped account is added through the browser
# sign-in against the rig's fake OAuth issuer, the token is stored, and Graph (the rig's fake drive, which takes only
# the access tokens the issuer minted) is reached through accountd's relay.
#
# The browser is the scenario's own `xdg-open` first on sill's PATH (harness/lib/accounts.sh sill_start): sill opens
# the page the sheet shows (BrowserWait), the opener records the address and follows it with curl, redirects
# included, so the issuer's authorize page answers with a redirect to accountd's loopback listener, which takes the
# code. The person's consent is the issuer's default (grant); the Microsoft client and its endpoints are the
# person's clients.toml, Graph is the shipped microsoft.toml with its host pointed at the fake.
#
#   boot      casement, recorded bus, issuer + Graph, fake Secret Service, accountd, sill
#   sign-in   AddAccount, "Micro" filters, Return picks Microsoft: the sheet shows the browser wait (capture); sill
#             opens the issuer's authorize URL (PKCE S256 and the loopback redirect); the sign-in finishes on its own
#             and the review step shows (capture); Return is Done; Response is 0
#   stored    the account is `ok` in accountd's settings module, signed_in is in the audit file, the account is in
#             the registry (and, by the scan below, no token is in any file)
#   graph     an app asks for Storage (the consent sheet, Always Allow) and opens a relay to Graph: GET /v1.0/me/drive
#             answers 200 through the relay, which added the issuer's access token; the app never held one
#   scan      the secret scan
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
OUT_DIR=$(scenario_out accounts-oauth-browser)

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

step_boot() {
  start_compositor || return 1
  scratch_new; acc_dirs
  build || return 1
  scan_begin
  rig_start --graph || return 1
  graph_front_start || return 1
  secrets_start || return 1
  acc_config; acc_clients_for_issuer; acc_provider_microsoft_on_rig
  accountd_start || return 1
  sill_start || return 1
}

step_sign_in() {
  acc_add_start org.quire.Mail
  sheet_await || return 1; sleep 1
  sheet_settled; sheet_type Micro; sleep 0.5; sheet_key Enter
  acc_wait 20 test -s "$RIG_DIR/opened.log" || { echo "sill never opened the browser: $(cat "$OUT_DIR/add.log")" >&2; return 1; }
  sheet_shot 1-browser-wait
  grep -q "^$(rigj oauth.authorize)" "$RIG_DIR/opened.log" || { echo "sill opened $(cat "$RIG_DIR/opened.log"), not the issuer's authorize page" >&2; return 1; }
  grep -q 'code_challenge_method=S256' "$RIG_DIR/opened.log" || { echo "the authorize URL has no PKCE S256" >&2; return 1; }
  # The browser followed the redirect to accountd's loopback listener: the review step comes up on its own.
  sleep 3; sheet_shot 2-review
  rigctl GET /graph/hits >"$OUT_DIR/graph-hits.json"
  sheet_key Enter
  local response
  response=$(acc_add_response 30) || { echo "AddAccount never answered: $(cat "$OUT_DIR/add.log")" >&2; return 1; }
  case "$response" in '{"response": 0'*) ;; *) echo "AddAccount answered $response" >&2; return 1 ;; esac
  ACCOUNT=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["results"]["account"])' "$response")
  sheet_gone || return 1
  echo "added $ACCOUNT" >&2
}

step_stored() {
  [ "$(settings_get "accounts.$ACCOUNT.state")" = ok ] || { echo "state is $(settings_get "accounts.$ACCOUNT.state")" >&2; return 1; }
  grep -q '"kind":"signed_in"' "$STATE/quire/accountd/audit.jsonl" || { echo "no signed_in in the audit file" >&2; return 1; }
  # The refresh token went to the Secret Service (the scan lists that call as the one place it may go) and into no
  # file: the registry holds the account, never a credential.
  grep -q "$ACCOUNT" "$STATE/porter/registry.json" || { echo "the account is not in the registry" >&2; return 1; }
}

step_graph() {
  rigc_bg "$OUT_DIR/grant.log" org.quire.Files request-grant storage --class files
  sheet_await || { cat "$OUT_DIR/grant.log" >&2; return 1; }
  sleep 1; sheet_shot 3-consent
  sheet_key Tab; sheet_key Enter
  acc_wait 20 grep -q '"result"' "$OUT_DIR/grant.log" || { echo "request-grant never answered" >&2; return 1; }
  grep -q '"result":"granted"' "$OUT_DIR/grant.log" || { cat "$OUT_DIR/grant.log" >&2; return 1; }
  sheet_gone || return 1
  rigc org.quire.Files open-authenticated storage --class files --family graph --path /v1.0/me/drive >"$OUT_DIR/graph.log" 2>&1 \
    || { cat "$OUT_DIR/graph.log" >&2; return 1; }
  grep -q '"status":200' "$OUT_DIR/graph.log" || { echo "Graph did not answer 200: $(cat "$OUT_DIR/graph.log")" >&2; return 1; }
  rigctl GET /graph/hits | grep -q '"bearer":true' || { echo "Graph saw no bearer" >&2; return 1; }
  echo "graph: $(cat "$OUT_DIR/graph.log")" >&2
}

step_scan() { scan_end; }

run_steps step_boot step_sign_in step_stored step_graph step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd daemon rig-servers secrets add; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
  [ -f "$RIG_DIR/browser.log" ] && { echo "--- browser.log" >&2; tail -10 "$RIG_DIR/browser.log" >&2; }
fi
exit "$STATUS"
