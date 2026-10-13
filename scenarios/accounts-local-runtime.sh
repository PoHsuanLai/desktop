#!/usr/bin/env bash
# Scenario `accounts-local-runtime` (design 31 §3.3, PLAN acceptance 6): a runtime on this computer is an account.
# The rig's fake Ollama listens on 127.0.0.1; inferd (real, `[probe] ollama` set to the fake's port, a look a second)
# finds it and records it as its own account (since porter's accounts split, Phase B, the AI accounts are inferd's, no
# longer accountd's); the account `ollama` appears in inferd's settings module, its place is this computer, detent's
# Intelligence page lists it; when the fake stops, inferd reports it offline: the account is `offline` and the page
# greys it. Real accountd, inferd and detent on casement; no sill (no sheet is needed).
#
#   boot       casement, recorded bus, the fake Ollama, Secret Service, accountd, inferd, detent (org.quire.Settings);
#              detent never starts a daemon, so every daemon its Accounts and Intelligence pages read runs first
#   appears    the account `ollama` is in inferd's settings module and `ok`
#   place      `accounts.ollama.place` is this_computer
#   listed     detent's Intelligence page, under Models on this computer, lists it as Running (capture)
#   offline    the fake is stopped (rig lever /ollama/stop); inferd's next look reports it offline and the account is
#              `offline`
#   greyed     detent's page changes at the runtime's row: it reads Offline and is greyed (capture)
#   scan       the secret scan
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
OUT_DIR=$(scenario_out accounts-local-runtime)

cleanup() { acc_stop_all; stop_compositor; scratch_drop; }
trap cleanup EXIT

has_ollama() { ai_has_account ollama; }
ollama_offline() { [ "$(ai_get accounts.ollama.state 2>/dev/null)" = offline ]; }
detent_mapped() { [ -n "$(detent_frame 2>/dev/null)" ]; }

# scroll_to_runtimes: the wheel over detent's page, a detent at a time, until the runtime's Manage button (the only
# "Manage <name>" on the Intelligence page: the row of "Models on this computer") is inside the window (the page is longer
# than the window and a wheel's distance depends on the toolkit, so the way is found, not counted; the second time the
# same distance is gone). Sets RUNTIME_STEPS (how far it went) and RUNTIME_Y (the button's y in the output).
RUNTIME_STEPS= RUNTIME_Y=
runtime_button_y() { # prints the button's y in detent's window when it is inside the visible part
  local c cx cy; c=$(detent_centre button "Manage …") || return 1
  read -r cx cy <<<"$c"
  [ "$cy" -ge 70 ] && [ "$cy" -le $(( $1 - 40 )) ] && echo "$cy"
}
scroll_to_runtimes() {
  local x y w h i cy
  read -r x y w h < <(detent_frame)
  casementctl debug inject "move $((x + 500)) $((y + 300))" >/dev/null
  for i in $(seq 40); do casementctl debug inject "axis vertical -150" >/dev/null; sleep 0.1; done   # to the top
  sleep 0.5
  if [ -n "$RUNTIME_STEPS" ]; then
    for i in $(seq "$RUNTIME_STEPS"); do casementctl debug inject "axis vertical 15" >/dev/null; sleep 0.25; done
  else
    for i in $(seq 0 80); do
      if runtime_button_y "$h" >/dev/null; then RUNTIME_STEPS=$i; break; fi
      casementctl debug inject "axis vertical 15" >/dev/null; sleep 0.25
    done
    [ -n "$RUNTIME_STEPS" ] || { echo "the Models on this computer row never came into view; detent shows:" >&2; detent_listing >&2; return 1; }
  fi
  sleep 1.5
  cy=$(runtime_button_y "$h") || { echo "the Manage button is not in view where it was" >&2; return 1; }
  RUNTIME_Y=$((y + cy)); acc_shot .scroll
}

# reports: what inferd said of its looks, from its log (the probe's report is in process now, not on the bus).
reports() { tail -n 10 "$OUT_DIR/inferd.log"; }

step_boot() {
  start_compositor || return 1
  scratch_new; acc_dirs
  scan_begin
  rig_start --ollama || return 1
  secrets_start || return 1
  acc_config
  accountd_start || return 1
  inferd_write_config <<EOF
[probe]
ollama = [$(rigj ollama.port)]
llama_cpp = []
lm_studio = []
every_s = 1
longest_s = 2
EOF
  inferd_start || return 1
}

step_appears() {
  acc_wait 30 has_ollama || {
    echo "no ollama account in inferd 30 s after it should have found the fake; inferd said:" >&2
    reports >&2
    return 1
  }
  [ "$(ai_get accounts.ollama.state)" = ok ] || { echo "the ollama account is $(ai_get accounts.ollama.state)" >&2; return 1; }
}

step_place() {
  [ "$(ai_get accounts.ollama.place)" = this_computer ] || { echo "place is $(ai_get accounts.ollama.place)" >&2; return 1; }
}

step_listed() {
  # detent never starts a daemon: both modules its pages read must have an owner before it opens.
  bus_has_owner org.quire.Accounts1 && bus_has_owner org.quire.Inference1 || { echo "accountd or inferd is not on the bus" >&2; return 1; }
  detent_start
  acc_wait 30 detent_mapped || { echo "detent never mapped" >&2; return 1; }
  sleep 4; detent_focus
  detent_press option Intelligence; sleep 2
  scroll_to_runtimes; acc_shot 1-intelligence-online
  [ -s "$OUT_DIR/1-intelligence-online.png" ]
}

step_offline() {
  rigctl POST /ollama/stop >/dev/null
  acc_wait 20 ollama_offline || { echo "the fake Ollama stopped, inferd looks every second, but the account is $(ai_get accounts.ollama.state), not offline; inferd said:" >&2; reports >&2; return 1; }
}

# detent redraws the row when its next look at the accounts lands, which can be a few seconds after the
# account went offline; one capture at a fixed time caught the old row about one run in three, so it looks again.
step_greyed() {
  local i
  for i in 1 2 3 4 5 6; do
    sleep 3; scroll_to_runtimes; acc_shot 2-intelligence-offline
    row_changed && return 0
  done
  return 1
}

row_changed() {
  python3 -I - "$OUT_DIR/1-intelligence-online.png" "$OUT_DIR/2-intelligence-offline.png" "$RUNTIME_Y" <<'PY'
import sys
from PIL import Image, ImageChops
box = (772, int(sys.argv[3]) - 24, 1388, int(sys.argv[3]) + 24)   # the runtime's row, with the page scrolled the same way both times
a = Image.open(sys.argv[1]).convert("RGB").crop(box)
b = Image.open(sys.argv[2]).convert("RGB").crop(box)
diff = ImageChops.difference(a, b).convert("L").point(lambda v: 255 if v > 12 else 0)
share = sum(1 for v in diff.tobytes() if v) / (box[2] - box[0]) / (box[3] - box[1])
print("the runtime's row changes by %.2f%% when it goes offline" % (share * 100), file=sys.stderr)
sys.exit(0 if share > 0.005 else 1)
PY
}

step_scan() { scan_end; }

run_steps step_boot step_appears step_place step_listed step_offline step_greyed step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd inferd detent rig-servers secrets; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
