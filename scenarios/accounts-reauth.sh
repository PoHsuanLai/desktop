# Scenario `accounts-reauth` (design 31 §7.1): the issuer stops honouring the refresh token, the account needs the person,
# and signing it in again through the sheet makes it work again. Since porter's accounts split (Phase B) the tokens are held
# by whoever uses them, so the refusal is met by syncd (ferry's; it has no accounts of its own and uses accountd's through
# org.quire.Grants1), and the account it shows needs the person. Real accountd and syncd, sill (the sheet host) on casement,
# ferry's rig (the issuer and Graph) (harness/lib/accounts.sh). Internet Accounts (accountd) owns Sign in again: syncd's rows
# have no such row.
#
#   boot      as accounts-oauth-browser: a Microsoft-shaped identity added through the browser sign-in; the files switch of
#             that account in syncd's rows is turned on (accountd's consent sheet shows once, Always Allow) and syncd mirrors the drive
#   refusal   the issuer refuses refreshes (rig lever /issuer/refuse-refreshes, what a revoked refresh token is to syncd:
#             invalid_grant; the rig's tokens last 4 s); at its next cycle syncd's OpenAuthenticated makes accountd refresh, the issuer
#             refuses, and accountd marks the account `needs_reauth` (porter credential.rs refused_refresh); syncd's settings
#             module reads the state from accountd's account list, so it shows `needs_reauth` there
#   sign-in   syncd's rows have no Sign in again (checked); Settings' Sign in again on accountd's row (accounts.<id>.reauth): the sheet shows the browser wait, sill opens the issuer's
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
sync_state() { sync_get "accounts.$ACCOUNT.state"; }
account_ok() { [ "$(sync_state)" = ok ]; }
account_needs_reauth() { [ "$(sync_state)" = needs_reauth ]; }

step_boot() {
  start_compositor || return 1
  scratch_new; acc_dirs
  build || return 1
  scan_begin
  ferry_rig_start --token-lifetime-s 4 || return 1
  secrets_start || return 1
  acc_config; acc_clients_for_issuer; acc_provider_microsoft_on_rig
  accountd_start || return 1
  sill_start || return 1
  syncd_start || return 1
  sheet_add_microsoft || return 1
  acc_wait 30 sync_has_account "$ACCOUNT" || { echo "syncd lists no row for accountd's account $ACCOUNT: $(tail -5 "$OUT_DIR/syncd.log")" >&2; return 1; }
  sync_files_turn_on "$ACCOUNT"
  sheet_await || { echo "accountd's consent sheet for syncd never showed: $(tail -5 "$OUT_DIR/syncd.log")" >&2; return 1; }
  sync_consent_keys
  sheet_gone || return 1
  account_ok || { echo "the account is $(sync_state) in syncd's rows, not ok" >&2; return 1; }
}

# SyncNow on syncd's dataset, as Settings makes it (detent's "Sync now"): a cycle runs at once instead of at the next look
# (idle datasets are looked at less and less often). busctl's exit code and output go to sync-now.log, so a refusal is on
# record (an empty log with exit 0 is a SyncNow that was taken).
sync_now() {
  local code
  as_app org.quire.Settings busctl --address="$BUS" call org.quire.Sync1 /org/quire/Sync1 org.quire.Sync1 SyncNow s \
    "${ACCOUNT//[-.]/_}/storage_app_folder" >>"$OUT_DIR/sync-now.log" 2>&1
  code=$?
  echo "SyncNow exit $code at ${SECONDS}s" >>"$OUT_DIR/sync-now.log"
}
refused_after_sync_now() { sync_now; sleep 4; account_needs_reauth; }
sync_files_on() { [ "$(sync_get "accounts.$ACCOUNT.sync.files")" = on ]; }
dataset_listed() { frigc org.quire.Files datasets 2>/dev/null | grep -q "${ACCOUNT//[-.]/_}/storage_app_folder"; }

step_refusal() {
  # The dataset (and so a token use) exists only while the permit is held (step_boot turned it on, Always Allow: a once permit
  # is spent by the first relay, and the dataset would go with it).
  [ "$(acc_permit_scope "$ACCOUNT" $SYNC_APP)" = always ] || { echo "accountd's permit for $SYNC_APP on $ACCOUNT is '$(acc_permit_scope "$ACCOUNT" $SYNC_APP)', not always" >&2; return 1; }
  sync_files_on || { echo "the files switch is '$(sync_get "accounts.$ACCOUNT.sync.files")'" >&2; return 1; }
  acc_wait 40 dataset_listed || { echo "syncd lists no storage_app_folder dataset with the files switch on: $(frigc org.quire.Files datasets)" >&2; tail -5 "$OUT_DIR/syncd.log" >&2; return 1; }
  frigctl POST "/issuer/refuse-refreshes?n=1000" >/dev/null
  # The rig's access tokens last 4 s; a cycle after that finds the token spent and the refresh refused (invalid_grant), which
  # accountd turns into NeedsReauth when syncd's relay asks it for a token (porter-service-core credential.rs refused_refresh).
  sleep 6
  acc_wait 120 refused_after_sync_now || {
    echo "the issuer refuses refreshes but syncd's account is still '$(sync_state)' after SyncNow cycles on a listed dataset; sync-now.log: $(tail -3 "$OUT_DIR/sync-now.log" | tr '\n' ' '); Graph saw: $(frigctl GET /graph/hits | tail -c 400); syncd said:" >&2; tail -10 "$OUT_DIR/syncd.log" >&2
    return 1
  }
}

step_sign_in() {
  # The sign-in gets a fresh refresh token the issuer honours (the old one was the one it refused); the refusal lever
  # would also refuse the first refresh of the new one.
  frigctl POST "/issuer/refuse-refreshes?n=0" >"$OUT_DIR/lever.log" 2>&1
  : >"$RIG_DIR/opened.log"
  sync_describe | grep -q '\.reauth"' && { echo "syncd still serves a Sign in again row" >&2; return 1; }
  acc_press "accounts.$ACCOUNT.reauth"
  acc_wait 20 test -s "$RIG_DIR/opened.log" || {
    frigctl GET /graph/hits >"$OUT_DIR/graph-hits.json" 2>&1
    echo "pressing Sign in again opened no browser; the sheet answered: $(request_responses); syncd said: $(tail -3 "$OUT_DIR/syncd.log")" >&2
    return 1
  }
  sheet_shot 3-browser-wait
  acc_wait 30 account_ok || {
    frigctl GET /graph/hits >"$OUT_DIR/graph-hits.json" 2>&1
    echo "the account is still $(sync_state); the sheet answered: $(request_responses); Graph saw: $(cat "$OUT_DIR/graph-hits.json")" >&2
    return 1
  }
  sheet_gone || { sheet_shot 4-review-again; acc_shot 4-review-again-output; echo "the sheet did not go by itself after the sign-in again (a review step shows?)" >&2; return 1; }
  acc_shot 5-end
}

step_scan() { scan_end; }

run_steps step_boot step_refusal step_sign_in step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd syncd daemon rig-servers ferry-rig-servers secrets add; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
