#!/usr/bin/env bash
# Scenario `accounts-regress-sheet`: the add-account sheet and the consent window, as accounts-hunt found them
# wrong (probes 1, 2, 3 and 6) and sill 245cc25 fixed them. Each step fails when its bug comes back. Real accountd,
# sill drawing the sheets, the rig's fake mail and Graph; no probe of sill's surfaces exists (see harness/lib/regress.sh),
# so a check reads the bus record (what accountd shows the sheet, what the keys made it send) or compares captures.
#
#   boot      casement, recorded bus, rig, accountd with 6 filler providers (24 rows) and an alias of Fake Mail, sill
#   S4        24 provider rows: the card stays inside the surface, and a click at Cancel's place (relative to the card)
#             sends Dismiss and closes the sheet [pixels + bus]
#   S2        "Google" + Return picks `google`, not `google-ai` [bus: Input pick]
#   S1        "Other..." picks `generic-imap` and shows its form, not the calendar and contacts one [bus: Input, Update]
#   S5        the step title follows the provider's label, never its id: two providers with one label and two ids draw
#             the same title, one with another label draws another [capture of the card's title band]
#   S6        Microsoft with no client id (the client goes between the list and the pick: porter 1c9a8e8 leaves a clientless provider off the list): the failure is `needs_client_id`; Return (Done, the default) dismisses; Tab
#             twice then Return still dismisses, so there is no Try Again between Back and Done [bus: Input]
#   add       one Fake Mail account added through the sheet, for the consent window
#   S5        an agent's app id is shown as written: `org.example.Agent.Zq-Bx` and its lowercase twin draw different
#             headings [captures of the consent window]
#   S3        a long app id: two ids that agree on their first 28 characters draw the same window (cut with an
#             ellipsis), and the heading's text stays inside the card with a margin on both edges [captures]
#   S7        the Microsoft browser wait: two sign-ins with different 300+ character addresses draw the same card, so
#             no part of the address is printed [captures]
#   scan      the secret scan
#
# Not asserted, screenshot only (kept in the run's output): S3's address on the review card. The rig's mail login is fixed
# at ada@rig.test (porter-rig MAIL_USER), so no account has an address longer than the 48-character cut; the consent
# window's app name goes through the same `clipped` (sill-overlays accounts_sheet/words.rs) and is asserted instead.
#
# budget: 200
# Exit: 0 pass | 1 a step failed | 2 outside the jail | 3 artefacts missing (harness/scenario-build.sh --accounts).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/scenario.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/accounts.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/regress.sh"
require_jail
acc_need
acc_env
# shellcheck source=/dev/null
source "$SCEN_BUILD/pin/sill/dev/lib/all.sh"
OUT_DIR=$(scenario_out accounts-regress-sheet)

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

step_boot() {
  local n
  regress_boot || return 1
  provider_copy alias-mail "Fake Mail" fake-mail
  for n in 1 2 3 4 5 6; do provider_copy "filler-$n" "Filler $n" fake-mail; done
  accountd_start || return 1
  sill_start || return 1
}

# S4: Cancel's place in a card of any height: 55 px from its right edge, 35 from its bottom (the form's and the list's alike).
step_s4_cancel_stays() {
  local n x0 y0 x1 y1 w h rows
  n=$(bus_count)
  open_sheet || return 1
  rows=$(bus_since "$n" | head -n 1 | grep -o '"mark"' | wc -l)
  sheet_shot s4-many-rows
  read -r x0 y0 x1 y1 w h < <(sheet_card s4-many-rows) || { echo "no card in the capture" >&2; return 1; }
  must "S4 the list has 20 rows or more ($rows)" [ "$rows" -ge 20 ]
  must "S4 the card is inside the surface (y $y0..$y1 of $h)" [ "$y0" -ge 4 ] && [ "$y1" -le $(( h - 4 )) ]
  sheet_click $(( x1 - 55 )) $(( y1 - 35 ))
  sleep 1
  must "S4 a click where Cancel is sends Dismiss" bus_saw "$n" 'input {"kind":"dismiss"}'
  must "S4 and the sheet closes" sheet_gone 5
  close_sheet
  reg_verdict
}

# Batch 7 (porter 1c9a8e8): the add list leaves out an OAuth provider whose issuer has no client for this build, so
# Google is listed (and "Google" + Return picks it, not google-ai) only once a Google client is registered. The
# shipped file is the jail's /usr/share overlay; the files are read again each time a sheet opens.
acc_clients_google() {
  mkdir -p /usr/share/porter
  printf '[[client]]\nissuer = "google"\nchannel = "stable"\nclient_id = "rig.apps.googleusercontent.com"\n' >/usr/share/porter/clients.toml
}

step_s2_google() {
  local n
  acc_clients_google
  open_sheet || return 1
  n=$(bus_count)
  sheet_type Google; sleep 0.5; sheet_key Enter; sleep 1
  must "S2 Google + Return picks google (picked: $(last_pick "$n"))" [ "$(last_pick "$n")" = google ]
  close_sheet
  reg_verdict
}

step_s1_other() {
  local n
  open_sheet || return 1
  n=$(bus_count)
  sheet_type Other; sleep 0.5; sheet_key ArrowDown; sheet_key ArrowDown; sheet_key Enter; sleep 1.5
  sheet_shot s1-other-form
  must "S1 Other... picks generic-imap (picked: $(last_pick "$n"))" [ "$(last_pick "$n")" = generic-imap ]
  must "S1 and shows its address form" bus_saw "$n" 'update {"kind":"sign_in","v":{"provider":"generic-imap"'
  close_sheet
  reg_verdict
}

step_s5_titles() {
  local n a b
  open_sheet || return 1
  n=$(bus_count); sheet_type "Fake Mail"; sleep 0.5; sheet_key Enter; sleep 1.5; sheet_shot s5-title-a; a=$(last_pick "$n")
  close_sheet
  open_sheet || return 1
  n=$(bus_count); sheet_type "Fake Mail"; sleep 0.5; sheet_key ArrowDown; sheet_key ArrowDown; sheet_key Enter; sleep 1.5; sheet_shot s5-title-b; b=$(last_pick "$n")
  close_sheet
  open_sheet || return 1
  sheet_type "Filler 1"; sleep 0.5; sheet_key Enter; sleep 1.5; sheet_shot s5-title-other
  close_sheet
  must "S5 the two providers differ only in their id ($a, $b)" [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]
  must "S5 their titles are the same: the label is shown, not the id" same_shot s5-title-a s5-title-b "$(card_top s5-title-a)"
  must "S5 (control) another label draws another title" not same_shot s5-title-a s5-title-other "$(card_top s5-title-a)"
  reg_verdict
}

# S6 reaches the failed card with a client that is there when the list is drawn and gone when the sign-in starts
# (Microsoft with no client is no longer listed at all, so it cannot be picked; porter reads the files at each sign-in).
s6_pick_microsoft_without_client() {
  acc_clients_for_issuer
  open_sheet || return 1
  sheet_type Micro; sleep 0.5
  rm -f /usr/share/porter/clients.toml
  sheet_key Enter; sleep 2.5
}

step_s6_no_client() {
  local n
  n=$(bus_count); s6_pick_microsoft_without_client || return 1; sheet_shot s6-no-client
  must "S6 Microsoft with no client id fails as needs_client_id" bus_saw "$n" '"kind":"failed","v":{"provider":"microsoft"'
  must "S6 the fault is needs_client_id" bus_saw "$n" '"fault":"needs_client_id"'
  sheet_key Enter; sleep 1
  must "S6 Return on it is Dismiss (Done is the default)" bus_saw "$n" 'input {"kind":"dismiss"}'
  must "S6 and it never retried or went back" not bus_saw "$n" 'input {"kind":"retry"}'
  close_sheet
  n=$(bus_count); s6_pick_microsoft_without_client || return 1
  sheet_key Tab; sheet_key Tab; sheet_key Enter; sleep 1
  must "S6 Tab, Tab, Return is Dismiss: no Try Again between Back and Done" bus_saw "$n" 'input {"kind":"dismiss"}'
  must "S6 and no Retry was sent" not bus_saw "$n" 'input {"kind":"retry"}'
  close_sheet
  reg_verdict
}

step_add() { sheet_add_fake_mail; }

step_s5_agent_id() {
  ask org.example.Agent.Zq-Bx a1; sheet_await || return 1; sleep 1.5; sheet_shot s5-agent-id
  sheet_key Escape; sheet_gone 8
  ask org.example.agent.zq-bx a2; sheet_await || return 1; sleep 1.5; sheet_shot s5-agent-id-lower
  sheet_key Escape; sheet_gone 8
  must "S5 an agent id keeps its case: the heading of Agent.Zq-Bx is not the lowercase one's" not same_shot s5-agent-id s5-agent-id-lower
  reg_verdict
}

step_s3_long_id() {
  local x0 y0 x1 y1 i0 j0 i1 j1 head=Laaaaaaaaaaaaaaaaaaaaaaaaaaa
  ask "org.quire.${head}XXXXXXXXXXXXXXXXXXXX" l1; sheet_await || return 1; sleep 1.5; sheet_shot s3-long-x
  sheet_key Escape; sheet_gone 8
  ask "org.quire.${head}YYYYYYYYYYYYYYYYYYYYYYYYYYYY" l2; sheet_await || return 1; sleep 1.5; sheet_shot s3-long-y
  sheet_key Escape; sheet_gone 8
  must "S3 ids that agree on the first 28 characters draw the same window (cut, not run out)" same_shot s3-long-x s3-long-y
  read -r x0 y0 x1 y1 _ _ < <(sheet_card s3-long-x) || return 1
  read -r i0 j0 i1 j1 < <(px ink "$OUT_DIR/s3-long-x.png" --box "$x0,$y0,$x1,$y1") || { echo "no heading ink" >&2; return 1; }
  must "S3 the heading's text (x $i0..$i1) keeps 12 px from both edges of the card ($x0..$x1)" [ "$i0" -ge $(( x0 + 12 )) ] && [ "$i1" -le $(( x1 - 12 )) ]
  reg_verdict
}

# S7: a Microsoft sign-in whose address is 300+ characters; the wait card draws the same whatever the address says.
step_s7_browser_wait() {
  local i
  acc_clients_for_issuer; acc_provider_microsoft_on_rig
  accountd_stop; accountd_start || return 1
  printf '#!/usr/bin/env bash\necho "$1" >>"%s/opened.log"\n' "$RIG_DIR" >"$BIN_DIR/xdg-open"; chmod +x "$BIN_DIR/xdg-open"
  for i in 1 2; do
    : >"$RIG_DIR/opened.log"
    open_sheet || return 1
    sheet_type Micro; sleep 0.5; sheet_key Enter
    acc_wait 20 test -s "$RIG_DIR/opened.log" || { echo "sill never opened the browser" >&2; return 1; }
    sleep 2.5; sheet_shot s7-wait-$i
    cp "$RIG_DIR/opened.log" "$OUT_DIR/opened-$i.log"
    close_sheet
  done
  must "S7 the address the browser got is long ($(wc -c <"$OUT_DIR/opened-1.log") characters)" [ "$(wc -c <"$OUT_DIR/opened-1.log")" -ge 300 ]
  must "S7 and the two sign-ins' addresses differ" not cmp -s "$OUT_DIR/opened-1.log" "$OUT_DIR/opened-2.log"
  must "S7 yet the wait card draws the same: the address is not printed" same_shot s7-wait-1 s7-wait-2
  reg_verdict
}

step_scan() { scan_end; }

run_steps step_boot step_s4_cancel_stays step_s2_google step_s1_other step_s5_titles step_s6_no_client step_add \
  step_s5_agent_id step_s3_long_id step_s7_browser_wait step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd daemon rig-servers secrets add; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
