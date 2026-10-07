#!/usr/bin/env bash
# Scenario `accounts-reauth` (design 31 §7.1): the issuer stops honouring the refresh token, the account needs the
# person, sill tells them, its button signs the account in again through the sheet, and the notice goes.
# Real accountd and sill on casement, the rig's issuer and Graph (harness/lib/accounts.sh).
#
#   boot      as accounts-oauth-browser: a Microsoft-shaped account added through the browser sign-in, an app
#             (org.quire.Files) granted Storage on it
#   refusal   the issuer refuses refreshes (rig lever /issuer/refuse-refreshes, what a revoked refresh token is to
#             accountd: invalid_grant); the app opens a relay to Graph and is refused NeedsReauth, and the account is
#             `needs_reauth` in accountd (state, and the NeedsReauth signal sill listens for)
#   notice    sill posts "<address> needs you to sign in" (capture of its banner); hovering shows "Sign in again"
#   sign-in   pressing it asks accountd to Reauthenticate: the sheet shows the browser wait, sill opens the issuer's
#             authorize page, the sign-in finishes by itself (no review step on a sign-in again, for any family; Done): the sheet
#             goes, the account is `ok` again and the notice is withdrawn
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
OUT_DIR=$(scenario_out accounts-reauth)
BANNERS=

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

# request_responses: the Request.Response signals on the bus so far (accountd's answer to each sheet request).
request_responses() {
  python3 -I -c '
import json, sys
for l in open(sys.argv[1]):
    try: m = json.loads(l)
    except ValueError: continue
    if m.get("member") == "Response" and "Request" in str(m.get("interface")): print(m["payload"]["data"])' "$OUT_DIR/bus.jsonl" | tail -n 2 | tr '\n' ' '
}
account_ok() { [ "$(settings_get "accounts.$ACCOUNT.state")" = ok ]; }
banner_shown() { sill debug capture "$BANNERS" "$OUT_DIR/.banner.png" >/dev/null 2>&1 && [ "$(opaque_pixels "$OUT_DIR/.banner.png")" -gt 1000 ]; }

step_boot() {
  start_compositor || return 1
  scratch_new; acc_dirs
  build || return 1
  scan_begin
  rig_start --graph || return 1
  secrets_start || return 1
  acc_config; acc_clients_for_issuer; acc_provider_microsoft_on_rig
  accountd_start || return 1
  sill_start || return 1
  BANNERS="sill-banners-$NAME"
  sheet_add_microsoft || return 1
  sheet_grant org.quire.Files storage files grant || return 1
  [ "$(settings_get "accounts.$ACCOUNT.state")" = ok ] || return 1
}

step_refusal() {
  rigctl POST "/issuer/refuse-refreshes?n=1000" >/dev/null
  rigc org.quire.Files open-authenticated storage --class files --family graph --path /v1.0/me/drive >"$OUT_DIR/refused.log" 2>&1
  grep -q '"refusal":"NeedsReauth"' "$OUT_DIR/refused.log" || { echo "the app was not refused NeedsReauth: $(cat "$OUT_DIR/refused.log")" >&2; return 1; }
  sleep 1
  local state; state=$(settings_get "accounts.$ACCOUNT.state")
  [ "$state" = needs_reauth ] || { echo "the app was refused NeedsReauth but the account is still '$state': no NeedsReauth signal, so nobody is told" >&2; return 1; }
}

step_notice() {
  acc_wait 20 banner_shown || { echo "sill never showed the notice" >&2; sill notifications status >&2; return 1; }
  sleep 1; sill debug capture "$BANNERS" "$OUT_DIR/1-notice.png" >>"$OUT_DIR/capture.log" 2>&1
  sill debug pointer "$BANNERS" 220 72 >>"$OUT_DIR/keys.log" 2>&1; sleep 1
  sill debug capture "$BANNERS" "$OUT_DIR/2-notice-hover.png" >>"$OUT_DIR/capture.log" 2>&1
}

step_sign_in() {
  # The sign-in gets a fresh refresh token the issuer honours (the old one was the one it refused); the refusal lever
  # would also refuse the first refresh of the new one.
  rigctl POST "/issuer/refuse-refreshes?n=0" >"$OUT_DIR/lever.log" 2>&1
  : >"$RIG_DIR/opened.log"
  sill debug click "$BANNERS" 127 105 >>"$OUT_DIR/keys.log" 2>&1 || return 1
  acc_wait 20 test -s "$RIG_DIR/opened.log" || {
    rigctl GET /graph/hits >"$OUT_DIR/graph-hits.json" 2>&1
    echo "pressing Sign in again opened no browser; accountd answered the Reauthenticate it was asked with: $(request_responses)" >&2
    return 1
  }
  sheet_shot 3-browser-wait
  acc_wait 30 account_ok || {
    rigctl GET /graph/hits >"$OUT_DIR/graph-hits.json" 2>&1
    echo "the account is still $(settings_get "accounts.$ACCOUNT.state"); the sheet answered: $(request_responses); Graph saw: $(cat "$OUT_DIR/graph-hits.json")" >&2
    return 1
  }
  sheet_gone || { sheet_shot 4-review-again; acc_shot 4-review-again-output; echo "the sheet did not go by itself after the sign-in again (a review step shows?)" >&2; return 1; }
  acc_wait 20 eval '! banner_shown' || { echo "the notice is still shown" >&2; return 1; }
  acc_shot 5-end
}

step_scan() { scan_end; }

run_steps step_boot step_refusal step_notice step_sign_in step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd daemon rig-servers secrets add; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
