#!/usr/bin/env bash
# Hunt 2: providers (accounts-hunt brief item 2): every provider file's route is reachable from the list, search
# narrows it, "Other..." leads somewhere, Google without a client id says what is missing, an agent login with no launcher
# says so, and the Microsoft browser wait offers Open again and Copy link.
#
#   boot      accountd with the shipped provider files only (no clients file: Google and Microsoft have no client)
#   routes    each listed provider picked by search and Return: the next screen is captured, then Escape
#   narrow    a search that matches nothing, one that matches two, Backspace restoring the list
#   other     "Other..." (generic-imap): the address form
#   browser   Microsoft with a client (rig issuer) whose browser never answers: the wait, Open again, Copy link
#
# budget: 600
# Exit: 0 pass | 1 a step failed | 2 outside the jail | 3 artefacts missing (harness/scenario-build.sh --accounts).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/scenario.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/accounts.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/hunt.sh"
require_jail
acc_need
acc_env
# shellcheck source=/dev/null
source "$SCEN_BUILD/pin/sill/dev/lib/all.sh"
OUT_DIR=$(scenario_out hunt-2)

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

step_boot() {
  start_compositor || return 1
  scratch_new; acc_dirs
  build || return 1
  scan_begin
  rig_start --graph || return 1
  secrets_start || return 1
  acc_config
  accountd_start || return 1
  sill_start || return 1
}

# route SEARCH SHOT: opens the sheet, picks SEARCH with Return, captures what comes next.
route() {
  local a
  acc_add_start org.quire.Mail
  sheet_await || return 1; sheet_settled; sleep 1
  sheet_type "$1"; sleep 0.5; sheet_key Enter; sleep 2.5
  sheet_shot "$2"
  a=$(add_answer 1); obs "$1: add answer=$a sheet=$(sheet_state)"
  sheet_key Escape; sleep 1
  if sheet_shown; then sheet_key Escape; sleep 1; fi
  if sheet_shown; then bug "the sheet will not close after $1 (Escape twice)"; return 1; fi
  kill "$ADD_PID" 2>/dev/null; true
}

step_routes() {
  route Anthropic r-anthropic
  route "Claude Code" r-claude-code
  route Codex r-codex
  route Fastmail r-fastmail
  route Gemini r-gemini-cli
  route GMX r-gmx
  route "Google (" r-google-ai
  route Google r-google
  route iCloud r-icloud
  route Microsoft r-microsoft
  route Moonshot r-moonshot
  route Nextcloud r-nextcloud
  route OpenAI r-openai
  route OpenRouter r-openrouter
  route Yahoo r-yahoo
  route "Other ACP" r-acp
}

step_narrow() {
  acc_add_start org.quire.Mail
  sheet_await || return 1; sheet_settled; sleep 1
  sheet_type zzzz; sleep 0.8; sheet_shot n1-nothing
  sheet_key Enter; sleep 1; obs "Return on an empty result: sheet=$(sheet_state) answer=$(add_answer 1)"; sheet_shot n1b-return-on-nothing
  for _ in 1 2 3 4; do sheet_key Backspace; done; sleep 0.5
  sheet_type goo; sleep 0.8; sheet_shot n2-goo
  sheet_key ArrowDown; sleep 0.3; sheet_shot n3-arrow
  for _ in 1 2 3; do sheet_key Backspace; done; sleep 0.8; sheet_shot n4-restored
  sheet_key ArrowDown; sheet_key ArrowDown; sleep 0.3; sheet_shot n5-two-down
  sheet_key Escape; sleep 1
  if sheet_shown; then sheet_key Escape; sleep 1; fi
  kill "$ADD_PID" 2>/dev/null; true
}

step_other() { route Other r-other; }

step_browser() {
  acc_clients_for_issuer; acc_provider_microsoft_on_rig
  accountd_stop; accountd_start || return 1
  # a browser that only records the address
  printf '#!/usr/bin/env bash\necho "$1" >>"%s/opened.log"\n' "$RIG_DIR" >"$BIN_DIR/xdg-open"; chmod +x "$BIN_DIR/xdg-open"
  : >"$RIG_DIR/opened.log"
  acc_add_start org.quire.Mail
  sheet_await || return 1; sheet_settled; sleep 1
  sheet_type Micro; sleep 0.5; sheet_key Enter; sleep 3
  sheet_shot b1-wait
  obs "browser opened: $(wc -l <"$RIG_DIR/opened.log") times"
  cp "$RIG_DIR/opened.log" "$OUT_DIR/opened-1.log"
  sheet_key Tab; sleep 0.3; sheet_shot b2-tab1
  sheet_key Tab; sleep 0.3; sheet_shot b3-tab2
  sheet_key Tab; sleep 0.3; sheet_shot b4-tab3
  sheet_key Escape; sleep 1
  obs "Escape on the browser wait: answer=$(add_answer 3) sheet=$(sheet_state)"
}

step_google() {
  local a
  acc_add_start org.quire.Mail
  sheet_await || return 1; sheet_settled; sleep 1
  sheet_type Google; sleep 0.5; sheet_key ArrowDown; sleep 0.3; sheet_shot g1-second-row
  sheet_key Enter; sleep 3; sheet_shot g2-google
  a=$(add_answer 1); obs "Google row: add answer=$a sheet=$(sheet_state)"
  sheet_key Enter; sleep 1; sheet_shot g3-after-return
  sheet_key Escape; sleep 1
  if sheet_shown; then sheet_key Escape; sleep 1; fi
  kill "$ADD_PID" 2>/dev/null; true
}

step_agent() {
  local a
  acc_add_start org.quire.Mail
  sheet_await || return 1; sheet_settled; sleep 1
  sheet_type "Claude Code"; sleep 0.5; sheet_key Enter; sleep 2; sheet_shot a1-review
  sheet_key Enter; sleep 3; sheet_shot a2-after-done
  a=$(add_answer 3); obs "Claude Code Done with no launcher: add answer=$a sheet=$(sheet_state)"
  if sheet_shown; then sleep 5; sheet_shot a3-later; sheet_key Escape; sleep 1; fi
  obs "accounts: $(accounts_now)"
  for acc in $(accounts_now); do obs "state of $acc: $(settings_get "accounts.$acc.state") label: $(settings_get "accounts.$acc.label")"; done
  true
}

step_browser_buttons() {
  : >"$RIG_DIR/opened.log"
  acc_add_start org.quire.Mail
  sheet_await || return 1; sheet_settled; sleep 1
  sheet_type Micro; sleep 0.5; sheet_key Enter; sleep 3
  sheet_key Enter; sleep 1.5
  obs "Return on the browser wait (Open Again): opened $(wc -l <"$RIG_DIR/opened.log") times"
  sheet_key Tab; sheet_key Enter; sleep 1; sheet_shot bb1-after-copy
  obs "Copy Link pressed: sheet=$(sheet_state)"
  sheet_key Escape; sleep 1
  kill "$ADD_PID" 2>/dev/null; true
}

step_scan() { scan_end; }

run_steps step_boot step_routes step_narrow step_other step_browser step_google step_agent step_browser_buttons step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd daemon rig-servers secrets add; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
