#!/usr/bin/env bash
# Scenario `accounts-local-runtime` (design 31 §3.3, PLAN acceptance 6): a runtime on this computer is an account.
# The rig's fake Ollama listens on 127.0.0.1; inferd (real, `[probe] ollama` set to the fake's port, a look a second)
# finds it and tells accountd (Peer.ReportLocal); the account `ollama` appears, its place is this computer, detent's
# Intelligence page lists it; when the fake stops, inferd reports it offline: the account is `offline` and the page
# greys it. Real accountd, inferd and detent on casement; no sill (no sheet is needed).
#
#   boot       casement, recorded bus, the fake Ollama, Secret Service, accountd, inferd, detent (org.quire.Settings)
#   appears    the account `ollama` is in accountd's settings module and `ok` (inferd's Peer.ReportLocal is taken)
#   place      `accounts.ollama.place` is this_computer
#   listed     detent's Intelligence page, under On this computer, lists it as Running (capture)
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

has_ollama() { settings_describe 2>/dev/null | python3 -I -c 'import json,sys; sys.exit(0 if any(k["path"].startswith("accounts.ollama.") for k in json.load(sys.stdin)["key"]) else 1)'; }
ollama_offline() { [ "$(settings_get accounts.ollama.state 2>/dev/null)" = offline ]; }
detent_mapped() { [ -n "$(detent_frame 2>/dev/null)" ]; }

# green_row SHOT: the y of the first row of green pixels in the runtime's status dot (the row's trailing edge, x 1230 to 1290 of the output, left of its state and Manage), or nothing.
green_row() {
  python3 -I - "$1" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
for y in range(250, 860):
    for x in range(1230, 1290):
        r, g, b = im.getpixel((x, y))
        if g > r + 25 and g > b + 25:
            print(y); sys.exit(0)
PY
}

# scroll_to_runtimes: the wheel over detent's page, a detent at a time, until the "On this computer" row's status dot is in
# view (the page is longer than the window and a wheel's distance depends on the toolkit, so the way is found, not counted);
# sets RUNTIME_STEPS (how far it went) and RUNTIME_Y.
RUNTIME_STEPS= RUNTIME_Y=
scroll_to_runtimes() {
  local x y w h i steps=${RUNTIME_STEPS:-}
  read -r x y w h < <(detent_frame)
  casementctl debug inject "move $((x + 500)) $((y + 300))" >/dev/null
  for i in $(seq 40); do casementctl debug inject "axis vertical -150" >/dev/null; sleep 0.1; done   # to the top
  sleep 0.5
  for i in $(seq 80); do
    casementctl debug inject "axis vertical 15" >/dev/null; sleep 0.25
    if [ -n "$steps" ]; then [ "$i" -lt "$steps" ] && continue; else
      acc_shot .scroll; RUNTIME_Y=$(green_row "$OUT_DIR/.scroll.png"); [ -z "$RUNTIME_Y" ] && continue
    fi
    RUNTIME_STEPS=$i; sleep 1.5; acc_shot .scroll; RUNTIME_Y=$(green_row "$OUT_DIR/.scroll.png"); [ -n "$RUNTIME_Y" ] && return 0
    echo "the status dot was in view and then was not" >&2; return 1
  done
  echo "the On this computer row never came into view" >&2
  return 1
}

# reports: what accountd answered inferd's ReportLocal calls, from the bus record.
reports() {
  python3 -I -c '
import json, sys
msgs = []
for l in open(sys.argv[1]):
    try: msgs.append(json.loads(l))
    except ValueError: pass
for i, m in enumerate(msgs):
    if m.get("member") == "ReportLocal":
        for r in msgs[i:]:
            if r.get("reply_cookie") == m.get("cookie") and r.get("destination") == m.get("sender"):
                print(r["type"], r.get("error_name", ""), r["payload"]["data"]); break' "$OUT_DIR/bus.jsonl" | sort | uniq -c
}

step_boot() {
  start_compositor || return 1
  scratch_new; acc_dirs
  scan_begin
  rig_start --ollama || return 1
  secrets_start || return 1
  acc_config
  accountd_start || return 1
  cat >"$CONFIG/quire/inferd.toml" <<EOF
[probe]
ollama = [$(rigj ollama.port)]
llama_cpp = []
lm_studio = []
every_s = 1
longest_s = 2

[callers]
settings = ["org.quire.Settings"]
EOF
  inferd_start || return 1
}

step_appears() {
  acc_wait 30 has_ollama || {
    echo "no ollama account 30 s after inferd found the fake; accountd answered its ReportLocal calls:" >&2
    reports >&2
    return 1
  }
  [ "$(settings_get accounts.ollama.state)" = ok ] || { echo "the ollama account is $(settings_get accounts.ollama.state)" >&2; return 1; }
}

step_place() {
  [ "$(settings_get accounts.ollama.place)" = this_computer ] || { echo "place is $(settings_get accounts.ollama.place)" >&2; return 1; }
}

step_listed() {
  detent_start
  acc_wait 30 detent_mapped || { echo "detent never mapped" >&2; return 1; }
  sleep 4; detent_focus
  detent_press option Intelligence; sleep 2
  scroll_to_runtimes; acc_shot 1-intelligence-online
  [ -s "$OUT_DIR/1-intelligence-online.png" ]
}

step_offline() {
  rigctl POST /ollama/stop >/dev/null
  acc_wait 20 ollama_offline || { echo "the fake Ollama stopped, inferd looks every second, but the account is $(settings_get accounts.ollama.state), not offline; accountd answered ReportLocal:" >&2; reports >&2; return 1; }
}

step_greyed() {
  sleep 4; scroll_to_runtimes; acc_shot 2-intelligence-offline
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
