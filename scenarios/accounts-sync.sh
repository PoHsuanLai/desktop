#!/usr/bin/env bash
# Scenario `accounts-sync` (design 31 §6, porter 5fdeafa Sync1.Resolve): syncd mirrors a OneDrive app folder from the
# rig's fake Graph, a two-sided edit makes a Conflict signal with its number, and the owning app settles it with
# Sync1.Resolve keep_remote: the next cycle takes the remote. syncd (ferry's) has no accounts of
# its own: it uses the accountd account the person signed in with, through porter-client over org.quire.Grants1, and keeps
# only its own sync switches and mirrors. Real accountd and syncd (syncd runs Storage over Graph), ferry's rig (issuer and
# Graph), sill as sheet host, detent for the Sync row. No network.
#
#   boot      as accounts-oauth-browser: a Microsoft-shaped identity added through the browser sign-in; syncd runs before
#             detent opens (detent never starts a daemon)
#   grant     Settings makes syncd's Files grant: detent starts, Accounts; the account (accountd's) is listed in syncd's rows with
#             its files switch off and no Add Account button (syncd signs nobody in); the account's own switch "Keep this
#             account's files on this computer" is turned on in the real window: accountd's consent sheet shows once, for that
#             one account, no chooser (capture 2-consent, Return); `accounts.<id>.sync.files` is "on" in syncd's settings module
#             (capture 6-sync-on); the switch is then turned off and on again: off takes the permit back, on makes it again
#             without a second sheet
#   mirror    syncd reads grants again every 2 s (SYNCD_RESCAN_S=2; the default is 600 s); the dataset
#             `<account segment>/storage_app_folder` is listed to its owner (org.quire.Files); a file the rig puts on the drive
#             (the remote edit lever /graph/put) shows in $XDG_DATA_HOME/porter/storage/<account>/
#   conflict  the owner's watch joins syncd, then both sides edit the file within a moment; the next cycle (the poll is
#             60 s: a local change is found at the next one) finds the two edits: the watch sees a Conflict signal
#             carrying a number
#   resolve   Sync1.Resolve(dataset, number, keep_remote) from the owner: the local file becomes the remote's text and
#             the drive keeps it
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
OUT_DIR=$(scenario_out accounts-sync)
OWNER=org.quire.Files
SYNC_FILES_LABEL="Keep this account's files on this computer"

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

# Syncd names an account by its object-path segment (underscores) in a dataset name and on disk. The account is accountd's
# (ACCOUNT, set by sheet_add_microsoft); syncd has none of its own.
SYNC_ACCOUNT=
segment() { echo "${SYNC_ACCOUNT//[-.]/_}"; }
folder() { echo "$DATA/porter/storage/$(segment)"; }
local_is() { [ "$(cat "$(folder)/$1" 2>/dev/null)" = "$2" ]; }
remote_is() { [ "$(frigctl GET "/graph/file?path=$1")" = "$2" ]; }
detent_mapped() { [ -n "$(detent_frame 2>/dev/null)" ]; }
sync_files() { sync_get "accounts.$SYNC_ACCOUNT.sync.files"; }
sync_label() { sync_get "accounts.$SYNC_ACCOUNT.label"; }
sync_on() { [ "$(sync_files)" = on ]; }
sync_off() { [ "$(sync_files)" = off ]; }
dataset_listed() { frigc $OWNER datasets 2>/dev/null | grep -q "$(segment)/storage_app_folder"; }

step_boot() {
  start_compositor || return 1
  scratch_new; acc_dirs
  build || return 1
  scan_begin
  ferry_rig_start || return 1
  secrets_start || return 1
  acc_config; acc_clients_for_issuer; acc_provider_microsoft_on_rig
  accountd_start || return 1
  sill_start || return 1
  syncd_start || return 1
  sheet_add_microsoft || return 1
  SYNC_ACCOUNT=$ACCOUNT
}

# The Sync group's Add Account button (accountd's add sheet) must still be on the page: detent reads syncd's
# `accounts.sync.add` row. The grant step then turns on the files switch of the account accountd already holds.
step_row() {
  frigctl POST "/graph/put?path=a.txt" "remote one" >/dev/null
  detent_start
  acc_wait 30 detent_mapped || { echo "detent never mapped" >&2; tail -5 "$OUT_DIR/detent.log" >&2; return 1; }
  sleep 4
  detent_focus
  detent_press option Accounts; sleep 1; acc_shot 1-accounts-list
  detent_centre button "Add Account" >/dev/null || { echo "the Sync row has no Add Account button (syncd serves accounts.sync.add; it shows:)" >&2; detent_listing >&2; return 1; }
}

step_grant() {
  # The account's own switch, in the real window: it is the last row of the list (the Sync group comes last), named by the
  # account accountd holds. It starts off; turning it on is syncd's first use of the account.
  sync_has_account "$SYNC_ACCOUNT" || { echo "syncd lists no row for accountd's account $SYNC_ACCOUNT" >&2; return 1; }
  sync_off || { echo "accounts.$SYNC_ACCOUNT.sync.files is '$(sync_files)' before anything turned it on" >&2; return 1; }
  sleep 2; detent_press option "$(sync_label) …" -1; sleep 1; acc_shot 1-sync-account
  detent_press switch "$SYNC_FILES_LABEL"
  sheet_await || { echo "accountd's consent sheet for syncd never showed: $(tail -5 "$OUT_DIR/syncd.log")" >&2; return 1; }
  sheet_settled; sheet_shot 2-consent
  sync_consent_keys
  sheet_gone || { echo "the consent sheet did not go after the answer" >&2; return 1; }
  acc_wait 30 sync_on || { acc_shot 5-sync-not-on; echo "allowing syncd did not switch the files on: accounts.$SYNC_ACCOUNT.sync.files is '$(sync_files)'" >&2; return 1; }
  acc_shot 6-sync-on
  detent_press switch "$SYNC_FILES_LABEL"; sleep 1
  acc_wait 15 sync_off || { echo "the switch did not take the permit back: accounts.$SYNC_ACCOUNT.sync.files is '$(sync_files)'" >&2; return 1; }
  # The answer is kept: turning it on again asks nothing.
  detent_press switch "$SYNC_FILES_LABEL"; sleep 1
  acc_wait 15 sync_on || { echo "the switch did not make the permit: accounts.$SYNC_ACCOUNT.sync.files is '$(sync_files)'" >&2; return 1; }
  ! sheet_shown || { echo "a second consent sheet showed for the same account" >&2; return 1; }
}

step_mirror() {
  acc_wait 40 dataset_listed || { echo "syncd does not list $(segment)/storage_app_folder to $OWNER: $(frigc $OWNER datasets)" >&2; tail -10 "$OUT_DIR/syncd.log" >&2; return 1; }
  acc_wait 90 local_is a.txt "remote one" || { echo "a.txt never reached $(folder): $(ls -la "$(folder)" 2>&1)" >&2; tail -10 "$OUT_DIR/syncd.log" >&2; return 1; }
}

step_conflict() {
  # The owner's watch joins syncd's roster first (a signal goes only to a connection syncd has heard from), then both
  # sides change the file within a moment, and the next cycle (poll 60 s, with jitter) finds the two edits.
  frigc_bg "$OUT_DIR/watch.log" $OWNER watch-conflicts --count 1 --timeout-s 200
  acc_wait 20 grep -q '"event":"watching"' "$OUT_DIR/watch.log" || { echo "the watch never started: $(cat "$OUT_DIR/watch.log")" >&2; return 1; }
  frigctl POST "/graph/put?path=a.txt" "remote two" >/dev/null
  printf 'local two' >"$(folder)/a.txt"
  acc_wait 210 grep -q '"event":"conflict"' "$OUT_DIR/watch.log" || { echo "no Conflict signal: $(cat "$OUT_DIR/watch.log")" >&2; tail -10 "$OUT_DIR/syncd.log" >&2; return 1; }
  NUMBER=$(python3 -I -c '
import json, sys
for l in open(sys.argv[1]):
    m = json.loads(l)
    if m.get("event") == "conflict":
        print(m["conflict"]["number"]); break' "$OUT_DIR/watch.log")
  DATASET=$(python3 -I -c '
import json, sys
for l in open(sys.argv[1]):
    m = json.loads(l)
    if m.get("event") == "conflict":
        print(m["dataset"]); break' "$OUT_DIR/watch.log")
  [ -n "$NUMBER" ] && [ -n "$DATASET" ] || { echo "the Conflict signal has no number or dataset: $(cat "$OUT_DIR/watch.log")" >&2; return 1; }
  echo "conflict $NUMBER in $DATASET" >&2
}

step_resolve() {
  frigc $OWNER sync-resolve "$DATASET" "$NUMBER" keep_remote >"$OUT_DIR/resolve.log" 2>&1 || { echo "Resolve failed: $(cat "$OUT_DIR/resolve.log")" >&2; return 1; }
  acc_wait 90 local_is a.txt "remote two" || { echo "after keep_remote the local file is '$(cat "$(folder)/a.txt")', not 'remote two'" >&2; return 1; }
  remote_is a.txt "remote two" || { echo "the drive no longer holds 'remote two': $(frigctl GET "/graph/file?path=a.txt")" >&2; return 1; }
}

step_scan() { scan_end; }

run_steps step_boot step_row step_grant step_mirror step_conflict step_resolve step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd syncd detent rig-servers ferry-rig-servers secrets add watch resolve; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
