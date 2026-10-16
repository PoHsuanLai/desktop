#!/usr/bin/env bash
# Scenario `accounts-consent` (design 31 §7.1 item on consent): an app asks to use the person's AI key, sill draws the
# consent sheet (captured), and each answer gives the right permit, or none; a second request after Always asks nothing.
# Since porter's accounts split (Phase B) the question is inferd's (org.quire.Inference1.Keys.RequestKey, the rig's
# `ai-keys request`), not accountd's: the grants and the relays left accountd with the mail and file kinds. Real accountd,
# inferd, sill on casement, the rig's LLM API fake and Secret Service. Each case is its own app id
# (porter-rig-client --app-id), so one answer cannot stand in for another. The permits are read from inferd's settings
# module (`accounts.<id>.grant.<grant>` and its `.scope` row), as Settings reads them.
#
#   boot      casement, recorded bus, the rig, accountd, inferd (cloud models allowed for the class asked), sill; an OpenAI
#             key added through the sheet (sheet_add_openai)
#   always    Always Allow: granted, the permit is `always`; the same app asks again: granted at once, no sheet drawn
#   once      Allow Once: granted, the permit is `once`; the app uses it (opens a session on the key with one prompt); a used
#             once-permit is spent ("for one use"), so the permit is gone afterwards and the next request must ask again
#   deny      Don't Allow: refused, and the answer is remembered as a refusal: the next request is refused, no sheet
#   escape    Escape: refused, nothing is stored, the next request asks again (the sheet is drawn again)
#   scan      the secret scan (harness/lib/secret-scan.py)
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
OUT_DIR=$(scenario_out accounts-consent)

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

# ask APP LOG: an ai-keys request as APP, in the background, its output in LOG.
ask() { ai_request_start "$1" "$2"; ASKED=$ACC_LAST; }
# answered LOG: waits for the client's one result line; prints it.
answered() { acc_wait 20 grep -q '"result"' "$OUT_DIR/$1.log" || { echo "no answer in $1.log: $(cat "$OUT_DIR/$1.log")" >&2; return 1; }; head -n 1 "$OUT_DIR/$1.log"; }
grant_field() { ai_grant_field "$1" "$2"; }
# asked_nothing LOG WHAT: the request was answered, or at least did not draw a sheet, within 8 s; a sheet that was drawn is
# closed (Escape) so the next step starts clean, and the step fails with WHAT.
asked_nothing() {
  acc_wait 8 eval 'grep -q "\"result\"" "$OUT_DIR/$1.log" || sheet_shown' || true
  if sheet_shown; then sheet_stray_escape; echo "$2" >&2; return 1; fi
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
  # The once-permit's use is a real session on the key: cloud models are allowed for the class the apps ask for, and the
  # person has picked the fast text model on that key (nothing is picked by default, so an unpicked tier is refused unread).
  inferd_write_config <<'TOML'
[ai]
local_only = "off"
[ai.floor]
files = "anywhere"
[ai.model.text]
fast = "openai-openai/fake-model"
TOML
  inferd_start || return 1
  sill_start || return 1
  sheet_add_openai || return 1
}

step_always() {
  local app=org.quire.Always out
  ask $app always1
  sheet_await || return 1; sleep 1; sheet_shot 1-consent
  sheet_key Tab; sheet_key Enter
  out=$(answered always1) || return 1
  case "$out" in *'"result":"granted"'*) ;; *) echo "not granted: $out" >&2; return 1 ;; esac
  sheet_gone || return 1
  [ "$(grant_field $app scope)" = always ] || { echo "the permit is $(grant_field $app scope), not always" >&2; return 1; }
  ask $app always2
  asked_nothing always2 "the second request after Always Allow drew the consent sheet again: inferd's RequestKey (porter-service choose.rs: ask_for builds a sheet from the fitting accounts and never reads the grants) asks every time" || return 1
  out=$(answered always2) || return 1
  case "$out" in *'"result":"granted"'*) ;; *) echo "the second request was not answered from the permit: $out" >&2; return 1 ;; esac
  sheet_hidden || { echo "a sheet was drawn for the second request" >&2; return 1; }
}

step_once() {
  local app=org.quire.Once out
  ask $app once1
  sheet_await || return 1; sleep 1
  sheet_key Enter                                  # Allow Once is first
  out=$(answered once1) || return 1
  case "$out" in *'"result":"granted"'*) ;; *) echo "not granted: $out" >&2; return 1 ;; esac
  sheet_gone || return 1
  [ "$(grant_field $app scope)" = once ] || { echo "the permit is $(grant_field $app scope), not once" >&2; return 1; }
  # The use: a session on the key with a prompt. inferd reads the key (spending the once-permit) before the turn goes out;
  # the turn itself then fails at the network in the jail, which is fine: the read already happened. A refusal for want
  # of a hosted model ("unavailable") comes before the read, so it means the catalog is missing and nothing was tested.
  rigc $app open llm --class files --prompt hello >"$OUT_DIR/once-use.log" 2>&1
  grep -q '"result":"opened"' "$OUT_DIR/once-use.log" || { echo "the once-permit did not open a session: $(cat "$OUT_DIR/once-use.log")" >&2; return 1; }
  if grep -q 'unavailable' "$OUT_DIR/once-use.log"; then
    echo "the use was refused before the key was read (no hosted model to route to; is the stoker catalog in place?): $(tail -n 3 "$OUT_DIR/once-use.log")" >&2
    return 1
  fi
  # Used once: spent, and a second use is not let through.
  [ "$(grant_field $app scope)" = none ] || { echo "a once-permit is still there after its key was read (scope $(grant_field $app scope)): it opens sessions again and again" >&2; return 1; }
  rigc $app open llm --class files --prompt again >"$OUT_DIR/once-again.log" 2>&1
  # A session may open, but its turn must be refused for want of a permit (the key is not read again).
  grep -q '"needs_grant"' "$OUT_DIR/once-again.log" || {
    echo "a turn after the once-permit was spent was not refused for want of a permit: $(cat "$OUT_DIR/once-again.log")" >&2; return 1
  }
}

step_deny() {
  local app=org.quire.Never out
  ask $app deny1
  sheet_await || return 1; sleep 1
  sheet_key Tab; sheet_key Tab; sheet_key Enter    # Don't Allow is third
  out=$(answered deny1) || return 1
  case "$out" in *'"result":"refused"'*) ;; *) echo "not refused: $out" >&2; return 1 ;; esac
  sheet_gone || return 1
  ask $app deny2
  asked_nothing deny2 "the request after Don't Allow drew the consent sheet again: RequestKey never reads the stored refusal" || return 1
  out=$(answered deny2) || return 1
  case "$out" in *'"result":"refused"'*) ;; *) echo "the second request after Don't Allow was: $out" >&2; return 1 ;; esac
  sheet_hidden || { echo "a sheet was drawn after Don't Allow" >&2; return 1; }
  [ "$(grant_field $app decision)" = deny ] || { echo "Don't Allow was not remembered as a refusal (decision: $(grant_field $app decision))" >&2; return 1; }
}

step_escape() {
  local app=org.quire.Esc out
  ask $app esc1
  sheet_await || return 1; sleep 1
  sheet_key Escape
  out=$(answered esc1) || return 1
  case "$out" in *'"result":"refused"'*) ;; *) echo "Escape was not a refusal: $out" >&2; return 1 ;; esac
  sheet_gone || return 1
  [ "$(grant_field $app decision)" = none ] || { echo "Escape stored $(grant_field $app decision)" >&2; return 1; }
  ask $app esc2
  sheet_await || { echo "the request after Escape did not ask again" >&2; return 1; }
  sheet_key Escape
  answered esc2 >/dev/null || return 1
  sheet_gone
}

step_scan() { scan_end; }

run_steps step_boot step_always step_once step_deny step_escape step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd inferd daemon rig-servers secrets add once-use; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
