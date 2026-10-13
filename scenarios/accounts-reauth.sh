# Scenario `accounts-reauth` (design 31 §7.1): the issuer stops honouring the refresh token, the account needs the person,
# and signing it in again through the sheet makes it work again. Since porter's accounts split (Phase B) the tokens are held
# by whoever uses them, so the refusal is met by syncd (it signs in for itself, "Continue as" the identity) and syncd's own
# account is the one that needs the person; accountd, which holds the identity only, issues no token and has nothing to
# refuse. Real accountd and syncd, sill (the sheet host) on casement, the rig's issuer and Graph (harness/lib/accounts.sh).
#
#   boot      as accounts-oauth-browser: a Microsoft-shaped identity added through the browser sign-in; syncd continues as it
#             (accounts.sync.add, as Settings presses it) and mirrors the drive
#   refusal   the issuer refuses refreshes (rig lever /issuer/refuse-refreshes, what a revoked refresh token is to syncd:
#             invalid_grant; the rig's tokens last 4 s); at its next cycle syncd is refused and its account is
#             `needs_reauth` in syncd's settings module
#   sign-in   Settings' Sign in again (accounts.<id>.reauth): the sheet shows the browser wait, sill opens the issuer's
#             authorize page, the sign-in finishes by itself (no review step on a sign-in again, for any family; Done): the
#             sheet goes and the account is `ok` again
#   scan      the secret scan
#
# The sill notice ("<address> needs you to sign in", a banner) this scenario used to check is not here: sill hears NeedsReauth
# from accountd only, and accountd has no token to be refused. The app that holds the token tells the person (mailo's own
# "sign-in needed" question; syncd's account shows "Needs sign-in" in Settings).
#
# budget: 420
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
SYNC_ACCOUNT=

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

# request_responses: the Request.Response signals on the bus so far (the answer to each sheet request).
request_responses() {
  python3 -I -c '
import json, sys
for l in open(sys.argv[1]):
    try: m = json.loads(l)
    except ValueError: continue
    if m.get("member") == "Response" and "Request" in str(m.get("interface")): print(m["payload"]["data"])' "$OUT_DIR/bus.jsonl" | tail -n 2 | tr '\n' ' '
}
sync_account() { # the id of syncd's first account, or nothing
  sync_describe 2>/dev/null | python3 -I -c '
import json, sys
for k in json.load(sys.stdin)["key"]:
    p = k["path"]
    if p.startswith("accounts.") and p.endswith(".state"): print(p[len("accounts."):-len(".state")]); break'
}
sync_has_account_now() { [ -n "$(sync_account)" ]; }
sync_state() { sync_get "accounts.$SYNC_ACCOUNT.state"; }
account_ok() { [ "$(sync_state)" = ok ]; }
account_needs_reauth() { [ "$(sync_state)" = needs_reauth ]; }

step_boot() {
  start_compositor || return 1
  scratch_new; acc_dirs
  build || return 1
  scan_begin
  rig_start --graph --token-lifetime-s 4 || return 1
  secrets_start || return 1
  acc_config; acc_clients_for_issuer; acc_provider_microsoft_on_rig
  accountd_start || return 1
  sill_start || return 1
  syncd_start || return 1
  sheet_add_microsoft || return 1
  : >"$RIG_DIR/opened.log"
  sync_press accounts.sync.add
  sheet_await || { echo "syncd's Continue as drew no sheet: $(tail -5 "$OUT_DIR/syncd.log")" >&2; return 1; }
  sleep 1; sheet_settled
  sheet_key Enter                                  # Continue, the first identity is picked
  acc_wait 30 test -s "$RIG_DIR/opened.log" || { echo "syncd's sign-in opened no browser: $(tail -5 "$OUT_DIR/syncd.log")" >&2; return 1; }
  sheet_enter_until 90 sync_has_account_now || { echo "syncd holds no account after its sign-in: $(tail -5 "$OUT_DIR/syncd.log")" >&2; return 1; }
  SYNC_ACCOUNT=$(sync_account)
  sheet_enter_until 30 sheet_hidden || return 1
  account_ok || { echo "syncd's account is $(sync_state), not ok" >&2; return 1; }
}

step_refusal() {
  rigctl POST "/issuer/refuse-refreshes?n=1000" >/dev/null
  # syncd's next cycle (the poll is 60 s, with jitter) finds its access token spent and the refresh refused.
  acc_wait 180 account_needs_reauth || {
    echo "the issuer refuses refreshes but syncd's account is still '$(sync_state)'; syncd said:" >&2; tail -10 "$OUT_DIR/syncd.log" >&2
    return 1
  }
}

step_sign_in() {
  # The sign-in gets a fresh refresh token the issuer honours (the old one was the one it refused); the refusal lever
  # would also refuse the first refresh of the new one.
  rigctl POST "/issuer/refuse-refreshes?n=0" >"$OUT_DIR/lever.log" 2>&1
  : >"$RIG_DIR/opened.log"
  sync_press "accounts.$SYNC_ACCOUNT.reauth"
  acc_wait 20 test -s "$RIG_DIR/opened.log" || {
    rigctl GET /graph/hits >"$OUT_DIR/graph-hits.json" 2>&1
    echo "pressing Sign in again opened no browser; the sheet answered: $(request_responses); syncd said: $(tail -3 "$OUT_DIR/syncd.log")" >&2
    return 1
  }
  sheet_shot 3-browser-wait
  acc_wait 30 account_ok || {
    rigctl GET /graph/hits >"$OUT_DIR/graph-hits.json" 2>&1
    echo "the account is still $(sync_state); the sheet answered: $(request_responses); Graph saw: $(cat "$OUT_DIR/graph-hits.json")" >&2
    return 1
  }
  sheet_gone || { sheet_shot 4-review-again; acc_shot 4-review-again-output; echo "the sheet did not go by itself after the sign-in again (a review step shows?)" >&2; return 1; }
  acc_shot 5-end
}

step_scan() { scan_end; }

run_steps step_boot step_refusal step_sign_in step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd syncd daemon rig-servers secrets add; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
