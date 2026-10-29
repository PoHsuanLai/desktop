#!/usr/bin/env bash
# Scenario `accounts-regress-detent`: detent's Accounts pane, as accounts-hunt found it wrong (probes 4, 5 and 6) and
# detent 06f5829 fixed it. detent runs with ds-blitz's debug probe (QUIRE_DEBUG_PROBE), so its controls are read by role and
# name; what is only text (the line under a row) is measured in the capture. Real accountd, sill (the sheet host), detent at
# its pin, the rigs' fake mail and Graph (porter's and ferry's).
#
#   boot      a password account (Fake Mail) and a browser account (Microsoft) added through accountd's sheet, an OpenAI key
#             added through the same sheet, a permit for an app on the key (the permits and their Revoke are the AI keys', and
#             accountd's since porter's step 5c); the Accounts pane reads accountd, inferd (spend rows) and (if it runs) syncd
#   D1        the list's rows are named by their account, read apart ("<account>, <provider>"), and every detail button
#             names what it acts on: "Revoke <app> ...", "Sign in again <account>", "Remove account <account>", never the
#             bare word [probe listing]
#   D2        the sidebar search "acc" keeps Accounts and drops Dock [probe listing]
#   D3        Sign in again's line follows the account's `sign_in` row: the browser account's line is longer than the
#             password account's (the plain line was one for both before) [accountd's sign_in key, and the ink of the inline help line
#             in the row's label column, measured in the capture; the text itself is not read]
#   D4        the remove question's answer "Remove account" is legible: WCAG contrast of its text on its fill is at least
#             4.5, in the light theme and in the dark [pixels of the capture, the button's box from the probe]
#
# Not asserted, screenshot only: the exact words of D3's lines (the probe lists controls, and the line is not one; detent's
# own tests assert the words).
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
OUT_DIR=$(scenario_out accounts-regress-detent)

cleanup() { acc_stop_all; stop_daemon; stop_compositor; scratch_drop; }
trap cleanup EXIT

# buttons: the names of detent's buttons now, one per line.
buttons() { detent_listing | awk -F'\t' '$1 == "button" { print $7 }'; }
# options: the sidebar's rows now.
options() { detent_listing | awk -F'\t' '$1 == "option" { print $7 }'; }
# has_line NAME LINES: a line of LINES (a variable's text) is exactly NAME / starts with NAME.
lists() { grep -qxF -- "$2" <<<"$1"; }
starts_with() { grep -q -- "^$2" <<<"$1"; }
# box_of ROLE NAME [NTH]: "X0,Y0,X1,Y1" of the control in the output (the probe's box moved by the window's place).
box_of() {
  local x y w h fx fy fw fh
  read -r fx fy fw fh < <(detent_frame) || return 1
  read -r _ x y w h _ < <(awk -F'\t' -v r="$1" -v n="$2" '$1 == r && $7 == n' <<<"$(detent_listing)" | sed -n "${3:-1}p") || return 1
  python3 -I -c 'import sys; fx, fy, x, y, w, h = map(float, sys.argv[1:]); print(f"{round(fx+x)},{round(fy+y)},{round(fx+x+w)},{round(fy+y+h)}")' "$fx" "$fy" "$x" "$y" "$w" "$h"
}

step_boot() {
  regress_boot || return 1
  acc_clients_for_issuer; acc_provider_microsoft_on_rig
  accountd_start || return 1
  inferd_write_config </dev/null
  inferd_start || return 1
  sill_start || return 1
  sheet_add_fake_mail || return 1
  sheet_add_microsoft || return 1
  sheet_add_openai || return 1
  AI_ACCOUNT=$ACCOUNT
  sheet_grant org.quire.Companion grant || return 1
  detent_start
  acc_wait 30 detent_mapped || { echo "detent never mapped" >&2; tail -5 "$OUT_DIR/detent.log" >&2; return 1; }
  sleep 4
  detent_focus
  # accountd lists the AI key beside the identities; the sign-in rows below are the identities'.
  ACCOUNTS=($(accounts_now | tr ' ' '\n' | grep -vxF -- "$AI_ACCOUNT"))
  echo "accounts: ${ACCOUNTS[*]}" >&2
  [ "${#ACCOUNTS[@]}" = 2 ]
}

step_d2_search() {
  detent_press textbox Search; sleep 0.5
  dkey a; dkey c; dkey c; sleep 1
  acc_shot d2-search
  must "D2 the search \"acc\" keeps Accounts" lists "$(options)" Accounts
  must "D2 and drops Dock" not lists "$(options)" Dock
  dkey BackSpace; dkey BackSpace; dkey BackSpace; sleep 0.5
  reg_verdict
}

step_d1_names() {
  local names
  detent_press option Accounts; sleep 1.5
  names=$(buttons)
  must "D1 the list's rows name the account (ada@rig.test, ...)" starts_with "$(options)" "ada@rig.test, "
  detent_press option "ada@rig.test …" 1; sleep 1.5
  acc_shot d1-account
  names=$(buttons)
  must "D1 Sign in again names the account" lists "$names" "Sign in again ada@rig.test"
  must "D1 Remove account names the account" lists "$names" "Remove account ada@rig.test"
  must "D1 no bare Sign in again" not lists "$names" "Sign in again"
  must "D1 no bare Remove account on the page" not lists "$names" "Remove account"
  # The AI key is in the list's Intelligence group: its permit's Revoke names the app.
  detent_press option "$(ai_get "accounts.$AI_ACCOUNT.label") …"; sleep 1.5
  acc_shot d1-ai-account
  names=$(buttons)
  must "D1 Revoke names the app" starts_with "$names" "Revoke $(app_title org.quire.Companion)"
  must "D1 no bare Revoke" not lists "$names" Revoke
  reg_verdict
}

# The line under Sign in again is inline help (quire's FieldRow shows its help under the label unless a page asks for an info
# button, and detent does not). The row is a probed group named by its label, so the help line is measured where it is
# drawn: the ink in the row's label column (the box of the row up to the Sign in again button, which is the same title for
# both accounts), in the capture of the account's page. Text is not read, only how much of it there is.
help_ink() { # NTH: the ink in the label column of the Sign in again row on the NTHth ada@rig.test account's detail
  local row button
  detent_press option "ada@rig.test …" "$1"; sleep 1.5
  acc_shot "d3-account-$1"
  row=$(box_of group "Sign in again") && button=$(box_of button "Sign in again ada@rig.test") || { echo 0; return; }
  python3 -I - "$OUT_DIR/d3-account-$1.png" "$row" "$button" <<'PY'
import sys
import numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
x0, y0, x1, y1 = (int(v) for v in sys.argv[2].split(","))
bx0 = int(sys.argv[3].split(",")[0])
c = a[y0:y1, x0:bx0 - 8]
flat = c.reshape(-1, 3)
vals, counts = np.unique(flat, axis=0, return_counts=True)
ground = vals[counts.argmax()]
print(int((abs(c - ground).sum(axis=2) > 60).sum()))
PY
}
step_d3_reauth() {
  local w1 w2 s1 s2
  s1=$(settings_get "accounts.${ACCOUNTS[0]}.sign_in"); s2=$(settings_get "accounts.${ACCOUNTS[1]}.sign_in")
  w1=$(help_ink 1); w2=$(help_ink 2)
  echo "sign_in rows: ${ACCOUNTS[0]}=$s1 ${ACCOUNTS[1]}=$s2; help line ink: $w1 $w2" >&2
  must "D3 one account signs in by password and the other by browser ($s1, $s2)" [ "$s1 $s2" = "password browser" ] || [ "$s1 $s2" = "browser password" ]
  must "D3 the help lines differ: the browser account's is the longer ($w1, $w2 ink pixels)" python3 -I -c '
import sys
w1, w2, s1 = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
browser, password = (w1, w2) if s1 == "browser" else (w2, w1)
sys.exit(0 if password > 0 and browser >= password * 1.15 else 1)' "$w1" "$w2" "$s1"
  reg_verdict
}

# The answer's text on its fill, in the open question (the page's own button is "Remove account <account>": the exact name is the answer's).
remove_contrast() { # SHOT
  acc_shot "$1"
  px contrast "$OUT_DIR/$1.png" --box "$(box_of button "Remove account")"
}
step_d4_remove_legible() {
  local light dark
  detent_press button "Remove account …"; sleep 1
  light=$(remove_contrast d4-question-light)
  printf '[appearance]\ntheme = "dark"\n' >"$CONFIG/quire/appearance.toml"; sleep 3
  dark=$(remove_contrast d4-question-dark)
  echo "contrast light: $light; dark: $dark" >&2
  must "D4 the question's answer is legible in the light theme ($light)" python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1].split()[0]) >= 4.5 else 1)' "$light"
  must "D4 and in the dark theme ($dark)" python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1].split()[0]) >= 4.5 else 1)' "$dark"
  must "D4 (control) the dark capture is a different theme" not same_shot d4-question-light d4-question-dark
  reg_verdict
}

step_scan() { scan_end; }

run_steps step_boot step_d2_search step_d1_names step_d3_reauth step_d4_remove_legible step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd inferd daemon detent rig-servers ferry-rig-servers secrets add; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
