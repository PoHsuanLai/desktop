#!/usr/bin/env bash
# Scenario `accounts-local-runtime` (design 31 §3.3, PLAN acceptance 6): a runtime on this computer is an account.
# The rig's fake Ollama listens on 127.0.0.1; inferd (real, `[probe] ollama` set to the fake's port, a look a second)
# finds it and tells accountd (Peer.ReportLocal); the account `ollama` appears, its place is this computer, detent's
# Intelligence page lists it; when the fake stops, inferd reports it offline: the account is `offline` and the page
# greys it. Real accountd, inferd and detent on casement; no sill (no sheet is needed).
#
#   boot       casement, recorded bus, the fake Ollama, Secret Service, accountd, inferd, detent (org.quire.Settings)
#   appears    the account `ollama` is in accountd's settings module and `ok`. FAILS today: accountd answers inferd's
#              ReportLocal InvalidArgs(UnknownProvider) because the daemon's catalogue holds only the providers a family
#              serves (accountd/src/main.rs `served`: "no family serves provider `ollama` yet"), and
#              porter-service local.rs `report_local` looks the provider up in that catalogue
#   seed       WORKAROUND while `appears` fails: accountd is stopped, an `ollama` account (local_runtime, ok) is put in
#              its registry file and accountd is started again, so the rest can be proven
#   place      `accounts.ollama.place` is this_computer
#   listed     detent's Intelligence page, under On this computer, lists it (capture)
#   offline    the fake is stopped (rig lever /ollama/stop); inferd's next look reports it offline. FAILS today for the
#              same reason (the report is refused, the account stays `ok`)
#   greyed     WORKAROUND: the registry says offline (accountd restarted), and detent's page changes (capture): the
#              runtime is greyed
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
INTELLIGENCE_ITEM="77 308"

cleanup() { acc_stop_all; stop_compositor; scratch_drop; }
trap cleanup EXIT

has_ollama() { settings_describe 2>/dev/null | python3 -I -c 'import json,sys; sys.exit(0 if any(k["path"].startswith("accounts.ollama.") for k in json.load(sys.stdin)["key"]) else 1)'; }
ollama_offline() { [ "$(settings_get accounts.ollama.state 2>/dev/null)" = offline ]; }
detent_mapped() { [ -n "$(detent_frame 2>/dev/null)" ]; }

# set_ollama STATE: accountd stopped, the registry's `ollama` account put in STATE (added when absent), accountd started.
set_ollama() {
  accountd_stop
  python3 -I - "$STATE/porter/registry.json" "$1" <<'PY' || return 1
import json, os, sys
path, state = sys.argv[1], sys.argv[2]
d = json.load(open(path)) if os.path.exists(path) else {"vocab": 4, "accounts": [], "grants": [], "toggles": []}
for a in d["accounts"]:
    if a["id"] == "ollama":
        a["state"] = state
        break
else:
    d["accounts"].append({
        "id": "ollama", "provider": "ollama", "label": "Ollama", "state": state, "auth": "local_runtime",
        "capabilities": [{"subject": {"kind": "model", "v": "llama3.2-3b"}, "provenance": "discovered",
                          "offer": {"kind": "present", "v": {"kind": "llm", "v": {
                              "features": ["chat"], "context": 8192, "max_output": 2048, "wire": "ollama_native"}}}}],
        "restriction": {"verification": {"kind": "not_needed"}, "token_lifetime": "standard", "consent": "user", "limits": []},
        "endpoints": []})
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump(d, open(path, "w"))
PY
  accountd_start
}

# scroll_to_runtimes: the wheel over detent's page until "On this computer" is in view (the page is longer than the window).
scroll_to_runtimes() {
  local x y w h i
  read -r x y w h < <(detent_frame)
  casementctl debug inject "move $((x + 500)) $((y + 300))" >/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do casementctl debug inject "axis vertical -90" >/dev/null; sleep 0.2; done   # to the top
  for i in 1 2 3 4 5 6; do casementctl debug inject "axis vertical 60" >/dev/null; sleep 0.3; done
  sleep 1
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

step_seed() {
  has_ollama && return 0
  set_ollama ok || return 1
  has_ollama || return 1
  echo "seeded: the registry holds an ollama account (inferd's report was refused)" >&2
}

step_place() {
  [ "$(settings_get accounts.ollama.place)" = this_computer ] || { echo "place is $(settings_get accounts.ollama.place)" >&2; return 1; }
}

step_listed() {
  detent_start
  acc_wait 30 detent_mapped || { echo "detent never mapped" >&2; return 1; }
  sleep 4; detent_focus
  detent_click $INTELLIGENCE_ITEM; sleep 2
  scroll_to_runtimes; acc_shot 1-intelligence-online
  [ -s "$OUT_DIR/1-intelligence-online.png" ]
}

step_offline() {
  rigctl POST /ollama/stop >/dev/null
  acc_wait 20 ollama_offline || { echo "the fake Ollama stopped, inferd looks every second, but the account is $(settings_get accounts.ollama.state), not offline; accountd answered ReportLocal:" >&2; reports >&2; return 1; }
}

step_greyed() {
  ollama_offline || set_ollama offline || return 1
  # accountd restarted: detent follows the name and reads the rows again.
  sleep 6; scroll_to_runtimes; acc_shot 2-intelligence-offline
  python3 -I - "$OUT_DIR/1-intelligence-online.png" "$OUT_DIR/2-intelligence-offline.png" <<'PY'
import sys
from PIL import Image, ImageChops
box = (772, 612, 1388, 652)   # the runtime's row, with the page scrolled the same way both times
a = Image.open(sys.argv[1]).convert("RGB").crop(box)
b = Image.open(sys.argv[2]).convert("RGB").crop(box)
diff = ImageChops.difference(a, b).convert("L").point(lambda v: 255 if v > 12 else 0)
share = sum(1 for v in diff.tobytes() if v) / (box[2] - box[0]) / (box[3] - box[1])
print("the runtime's row changes by %.2f%% when it goes offline" % (share * 100), file=sys.stderr)
sys.exit(0 if share > 0.005 else 1)
PY
}

step_scan() { scan_end; }

run_steps step_boot step_appears step_seed step_place step_listed step_offline step_greyed step_scan
if [ "$STATUS" != 0 ]; then
  for f in accountd inferd detent rig-servers secrets; do
    [ -f "$OUT_DIR/$f.log" ] && { echo "--- $f.log (tail)" >&2; tail -15 "$OUT_DIR/$f.log" >&2; }
  done
fi
exit "$STATUS"
