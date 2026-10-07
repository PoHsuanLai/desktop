#!/usr/bin/env bash
# Scenario `accounts-secret-scan` (accounts PLAN §8 "Secret scan"): the scan every accounts-* scenario ends with
# (harness/lib/secret-scan.py over a `busctl monitor --json` record of the private bus, the scenario's logs and the
# state, config and data trees) is proven here, and the API-key case, which the others do not reach, is added.
#
#   control   the scanner on synthetic records: a clean record passes; a planted password in a D-Bus call to a daemon,
#             a refresh token in a log, an API key in a state file and a password in the registry each fail it; the
#             flows the design allows (Secret Service, the sheet's Input, an access token in IssueToken's reply,
#             the test's typing) pass. A scan that cannot fail proves nothing.
#   boot      casement, recorded bus, the rig with its LLM API fake (a bearer key), Secret Service, accountd, sill
#   api-key   an AI company's account is added through the sheet with the planted API key (openai.toml pointed at the
#             fake): the key goes sheet -> accountd -> Secret Service and the fake accepted it (models list)
#   scan      the real record of this run is clean, and the scan SAW the key where the design lets it be (the sheet's
#             Input and the Secret Service), so it can see
#
# What the scan cannot see (reported, not hidden): (1) the legs of a relay that are TLS to a server (accountd to the IMAP,
# SMTP, POP3, Graph or LLM API fake): encrypted on the wire, and the rig's own record of what it received lives outside
# the jail's views of accountd; (2) a secret in a process's memory or in a core dump; (3) text drawn on a sheet (a
# password is dots; a capture is a picture, not scanned); (4) anything an app sends the fake over a socket it opened
# itself; (5) IssueToken's access token is allowed to reach the app by design and is scanned for only elsewhere.
# What it does see: every message on the private bus (both directions, unicast signals included, as the bus config lets
# a monitor eavesdrop), the app side of every relay as porter-rig-client prints it (a log in the scenario's out dir), all
# daemon and sill logs, the registry, the audit file, the config and data trees.
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
OUT_DIR=$(scenario_out accounts-secret-scan)
SCAN="$HARNESS_LIB/secret-scan.py"

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

# A bus message as busctl monitor --json=short writes it.
msg() { # TYPE SENDER DEST INTERFACE MEMBER COOKIE REPLY-COOKIE PAYLOAD-JSON
  printf '{"type":"%s","sender":"%s","destination":"%s","interface":"%s","member":"%s","cookie":%s,"reply_cookie":%s,"payload":{"type":"s","data":%s}}\n' "$@"
}
scan() { python3 -I "$SCAN" "$@" >"$OUT_DIR/control.out" 2>&1; }

step_control() {
  local d="$OUT_DIR/control" S='"RIG-SECRET-MAIL-PASSWORD-9d41c7"' R='"fake-refresh-7"' A='"fake-access-9"'
  mkdir -p "$d"
  local pw=RIG-SECRET-MAIL-PASSWORD-9d41c7 key=RIG-SECRET-API-KEY-f05d83
  # clean: ordinary traffic
  { msg method_call :1.2 org.quire.Accounts1 org.quire.Accounts1.Manager Query 1 null '["x"]'
    msg method_return org.quire.Accounts1 :1.2 "" "" 2 1 '["x"]'; } >"$d/clean.jsonl"
  scan --bus "$d/clean.jsonl" --secret "$pw" --pattern 'fake-refresh-[0-9]+' || { echo "a clean record failed the scan" >&2; return 1; }
  # a password in a call to a daemon other than the Secret Service: a hit
  msg method_call :1.5 org.quire.Accounts1 org.quire.Accounts1.Manager AddAccount 3 null "[\"$pw\"]" >"$d/leak-bus.jsonl"
  scan --bus "$d/leak-bus.jsonl" --secret "$pw" && { echo "a password in an accountd call passed the scan" >&2; return 1; }
  # the same in a call to the Secret Service, in the sheet's Input, in the test's typing: allowed
  { msg method_call :1.5 org.freedesktop.secrets org.freedesktop.Secret.Collection CreateItem 4 null "[\"$pw\"]"
    msg signal :1.9 :1.7 org.quire.AccountsSheet1 Input 5 null "[\"h\",\"$pw\"]"
    msg method_call :1.72 org.quire.Casement.Debug1 org.quire.Casement.Debug1 Inject 6 null "[\"type $pw\"]"; } >"$d/allowed.jsonl"
  scan --bus "$d/allowed.jsonl" --secret "$pw" || { echo "an allowed flow failed the scan: $(cat "$OUT_DIR/control.out")" >&2; return 1; }
  # an access token in IssueToken's reply: allowed; in anything else: a hit
  { msg method_call :1.5 org.quire.Accounts1 org.quire.Accounts1.Tokens IssueToken 7 null '["g"]'
    msg method_return org.quire.Accounts1 :1.5 "" "" 8 7 "[\"fake-access-9\"]"; } >"$d/issue.jsonl"
  scan --bus "$d/issue.jsonl" --access-pattern 'fake-access-[0-9]+' || { echo "an access token in IssueToken's reply failed the scan" >&2; return 1; }
  msg method_return :1.2 :1.5 "" "" 9 3 "[\"fake-access-9\"]" >"$d/access-leak.jsonl"
  scan --bus "$d/access-leak.jsonl" --access-pattern 'fake-access-[0-9]+' && { echo "an access token outside IssueToken passed the scan" >&2; return 1; }
  # a refresh token (minted pattern) in a log, an API key in a state file: hits
  echo "refreshed with fake-refresh-12" >"$d/daemon.log"
  scan --file "$d/daemon.log" --pattern 'fake-refresh-[0-9]+' && { echo "a refresh token in a log passed the scan" >&2; return 1; }
  mkdir -p "$d/state"; echo "{\"key\":\"$key\"}" >"$d/state/registry.json"
  scan --dir "$d/state" --secret "$key" && { echo "an API key in a state file passed the scan" >&2; return 1; }
  echo "control: clean passes; a password, a refresh token, an API key and an access token in the wrong place each fail it; the allowed flows pass" >&2
}

step_boot() {
  start_compositor || return 1
  scratch_new; acc_dirs
  build || return 1
  scan_begin
  rig_start --llm-api || return 1
  secrets_start || return 1
  acc_config; acc_provider_openai_on_rig
  accountd_start || return 1
  sill_start || return 1
}

step_api_key() {
  acc_add_start org.quire.Companion
  sheet_await || return 1; sheet_settled; sleep 1
  sheet_type OpenAI; sleep 0.5; sheet_key Enter; sleep 1
  sheet_shot 1-api-key-form
  sheet_type "$(rigj llm_api.api_key)"; sleep 0.5; sheet_shot 2-api-key-typed
  sheet_key Enter; sleep 3; sheet_shot 3-review
  sheet_key Enter
  local response
  response=$(acc_add_response 30) || { echo "AddAccount never answered: $(cat "$OUT_DIR/add.log")" >&2; return 1; }
  acc_added "$response" || { echo "AddAccount answered $response" >&2; return 1; }
  sheet_gone || return 1
}

step_scan() {
  scan_end || return 1
  grep -q 'the sheet host.s Input to accountd' "$OUT_DIR/secret-scan.txt" && grep -q 'Secret Service call' "$OUT_DIR/secret-scan.txt" \
    || { echo "the scan did not see the API key where the design lets it go (sheet Input, Secret Service): it cannot see" >&2; cat "$OUT_DIR/secret-scan.txt" >&2; return 1; }
}

run_steps step_control step_boot step_api_key step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd daemon rig-servers secrets add; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
