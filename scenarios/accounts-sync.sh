#!/usr/bin/env bash
# Scenario `accounts-sync` (design 31 §6, porter 5fdeafa Sync1.Resolve): syncd mirrors a OneDrive app folder from the
# rig's fake Graph through accountd's relay, a two-sided edit makes a Conflict signal with its number, and the owning
# app settles it with Sync1.Resolve keep_remote: the next cycle takes the remote.
# Real accountd and syncd (syncd runs Storage over Graph), the rig's issuer and Graph, sill as sheet host for the sign-in.
# No network.
#
#   boot      as accounts-oauth-browser: a Microsoft-shaped account added through the browser sign-in
#   grant     Settings makes syncd's Files grant: detent starts, Accounts > Manage on the account, and the Sync group's
#             "Keep this account's files on this computer" switch is clicked in the real window (coordinates, as
#             accounts-settings; detent exposes no tree the harness can query); accountd's `sync.files` row says "on"
#             (capture 6-sync-on). The grant is for the app accountd names syncd (callers.toml: org.quire.Sync,
#             unit syncd.service)
#   mirror    syncd starts with SYNCD_RESCAN_S=2 (it reads grants again that often; the default is 600 s); the dataset
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
# Where the controls are, relative to detent's window frame: the sidebar's Accounts, the list's Manage, the account
# screen's Sync group switch for files.
ACCOUNTS_ITEM="77 284"; MANAGE="666 90"; SYNC_FILES_SWITCH="662 399"

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

# Syncd names an account by its object-path segment (underscores) in a dataset name and on disk.
segment() { echo "${ACCOUNT//[-.]/_}"; }
folder() { echo "$DATA/porter/storage/$(segment)"; }
local_is() { [ "$(cat "$(folder)/$1" 2>/dev/null)" = "$2" ]; }
remote_is() { [ "$(rigctl GET "/graph/file?path=$1")" = "$2" ]; }
detent_mapped() { [ -n "$(detent_frame 2>/dev/null)" ]; }
sync_files() { settings_get "accounts.$ACCOUNT.sync.files"; }
sync_on() { [ "$(sync_files)" = on ]; }
dataset_listed() { rigc $OWNER datasets 2>/dev/null | grep -q "$(segment)/storage_app_folder"; }

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
  sheet_add_microsoft || return 1
}

step_grant() {
  detent_start
  acc_wait 30 detent_mapped || { echo "detent never mapped" >&2; tail -5 "$OUT_DIR/detent.log" >&2; return 1; }
  sleep 4
  detent_focus
  detent_click $ACCOUNTS_ITEM; sleep 1; acc_shot 1-accounts-list
  detent_click $MANAGE; sleep 1; acc_shot 2-account
  [ "$(sync_files)" = off ] || echo "before the click accounts.$ACCOUNT.sync.files is '$(sync_files)'" >&2
  detent_click $SYNC_FILES_SWITCH; sleep 1
  acc_wait 15 sync_on || { acc_shot 5-sync-not-on; echo "the switch did not make the grant: accounts.$ACCOUNT.sync.files is '$(sync_files)'" >&2; return 1; }
  acc_shot 6-sync-on
}

step_mirror() {
  rigctl POST "/graph/put?path=a.txt" "remote one" >/dev/null
  syncd_start || return 1
  acc_wait 40 dataset_listed || { echo "syncd does not list $(segment)/storage_app_folder to $OWNER: $(rigc $OWNER datasets)" >&2; tail -10 "$OUT_DIR/syncd.log" >&2; return 1; }
  acc_wait 90 local_is a.txt "remote one" || { echo "a.txt never reached $(folder): $(ls -la "$(folder)" 2>&1)" >&2; tail -10 "$OUT_DIR/syncd.log" >&2; return 1; }
}

step_conflict() {
  # The owner's watch joins syncd's roster first (a signal goes only to a connection syncd has heard from), then both
  # sides change the file within a moment, and the next cycle (poll 60 s, with jitter) finds the two edits.
  rigc_bg "$OUT_DIR/watch.log" $OWNER watch-conflicts --count 1 --timeout-s 200
  acc_wait 20 grep -q '"event":"watching"' "$OUT_DIR/watch.log" || { echo "the watch never started: $(cat "$OUT_DIR/watch.log")" >&2; return 1; }
  rigctl POST "/graph/put?path=a.txt" "remote two" >/dev/null
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
  rigc $OWNER sync-resolve "$DATASET" "$NUMBER" keep_remote >"$OUT_DIR/resolve.log" 2>&1 || { echo "Resolve failed: $(cat "$OUT_DIR/resolve.log")" >&2; return 1; }
  acc_wait 90 local_is a.txt "remote two" || { echo "after keep_remote the local file is '$(cat "$(folder)/a.txt")', not 'remote two'" >&2; return 1; }
  remote_is a.txt "remote two" || { echo "the drive no longer holds 'remote two': $(rigctl GET "/graph/file?path=a.txt")" >&2; return 1; }
}

step_scan() { scan_end; }

run_steps step_boot step_grant step_mirror step_conflict step_resolve step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd syncd rig-servers secrets add watch resolve; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
