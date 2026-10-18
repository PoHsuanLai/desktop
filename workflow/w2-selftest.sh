#!/usr/bin/env bash
# The W2 rig's self-test: checks the parts of scenarios/w2-excalidraw.sh and workflow/w2-excalidraw.sh that need no
# session, no jail, no model and no browser.
#
#   workflow/w2-selftest.sh
#
# Checks the options and refusals, the build list, the opt-in mark the gate honours, the browser profile's download
# settings, the file server's mounts, the drawing checks on canned drawings (a good one, one with too few shapes, wrong
# proportions, no sizes, a file that is not a drawing), the sheets read from a canned bus record (the brief's words
# must come back), the guard's words and the report built from a canned run. Touches only a scratch folder.
#
# Exit: 0 every check holds, 1 a check failed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FIX="$HERE/fixtures/w1"
SCEN=("$ROOT/scenarios/w2-excalidraw.sh")
LAUNCH=("$HERE/w2-excalidraw.sh")
PY=(python3 -I "$HERE/lib/w2.py")
PY1=(python3 -I "$HERE/lib/w1.py")
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fails=0

ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -z "${2:-}" ] || printf '     %s\n' "$2"; fails=$((fails + 1)); }
has() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "missing [$3] in: $(head -c 500 <<<"$2")"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then bad "$1" "unexpected [$3]"; else ok "$1"; fi; }
code() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "exit $3, wanted $2"; fi; }

# ---- the scenario's options (it stops before it needs the jail)
out=$("${SCEN[@]}" --help 2>&1); code "scenario help: exit 0" 0 $?
has "scenario help: names the screen model variable" "$out" "W2_SCREEN_SOCK"
has "scenario help: names the opt-in line" "$out" "opt-in"
out=$("${SCEN[@]}" --nonsense 2>&1); code "scenario options: an unknown option is refused" 64 $?
out=$("${SCEN[@]}" --timeout abc 2>&1); code "scenario options: a timeout that is no number is refused" 64 $?
out=$("${SCEN[@]}" --print-build 2>&1); code "print-build: exit 0" 0 $?
has "print-build: the one-line way" "$out" "harness/scenario-build.sh --w2"
has "print-build: casement's test build" "$out" "dev/bootstrap.sh --build-only"
has "print-build: sill with its test features" "$out" "-p sill --features debug"
has "print-build: the screen helper with the fixture callers" "$out" "-p cuad --features docket-dbus/fixture-callers"
has "print-build: the assistant's services as test builds" "$out" "-p docket-accept --bins"
has "print-build: the drawing app" "$out" "build-excalidraw.sh"
lacks "print-build: not W1's plain casement build" "$out" "-p casementctl"
lacks "print-build: not W1's folders" "$out" "/mnt/data/cargo/w1"
if [ -z "$(bash -c "source '$ROOT/harness/lib/jail.sh'; jail_violations")" ]; then
  echo "skip: this is the jail; the outside-the-jail checks are not run"
else
  out=$(env W2_PLANNER_SOCK=/x W2_SCREEN_SOCK=/y "${SCEN[@]}" 2>&1); code "scenario outside the jail: refused, exit 2" 2 $?
fi

# ---- the launcher's refusals
out=$("${LAUNCH[@]}" --help 2>&1); code "launcher help: exit 0" 0 $?
has "launcher help: no default model" "$out" "There is no default model"
out=$("${LAUNCH[@]}" --nonsense 2>&1); code "launcher options: unknown option refused" 2 $?
out=$("${LAUNCH[@]}" --print-build 2>&1); code "launcher print-build: exit 0" 0 $?
has "launcher print-build: same list" "$out" "-p cuad --features docket-dbus/fixture-callers"
out=$(env -u W2_PLANNER_SOCK -u W2_PLANNER_URL -u W2_SCREEN_SOCK -u W2_SCREEN_URL "${LAUNCH[@]}" --run-dir "$scratch/r1" 2>&1); code "no model: refused, exit 2" 2 $?
has "no model: names the assistant model" "$out" "W2_PLANNER_SOCK"
has "no model: names the screen model" "$out" "W2_SCREEN_SOCK"
has "no model: says there is no default" "$out" "There is no default"
out=$(env -u W2_SCREEN_SOCK -u W2_SCREEN_URL W2_PLANNER_SOCK=/nowhere "${LAUNCH[@]}" --run-dir "$scratch/r2" 2>&1); code "one model missing: refused" 2 $?
has "one model missing: names the screen model" "$out" "W2_SCREEN_SOCK"
lacks "one model missing: does not blame the assistant model" "$out" "No assistant model"
out=$(env W2_PLANNER_SOCK="$scratch/none.sock" W2_SCREEN_SOCK="$scratch/none2.sock" "${LAUNCH[@]}" --run-dir "$scratch/r3" 2>&1); code "a socket that is not there: refused" 2 $?
has "a socket that is not there: says start the bridge" "$out" "start the bridge"
[ ! -e "$scratch/r3" ] && ok "refusals make no run folder" || bad "refusals make no run folder"

# ---- the gate leaves it out; the floor knows the screen helper
grep -q '^# opt-in:' "${SCEN[0]}" && ok "scenario: carries the opt-in line" || bad "scenario: carries the opt-in line"
grep -q "grep -q '^# opt-in:'" "$ROOT/gate/desktop-gate.sh" && ok "gate: skips opt-in scenarios" || bad "gate: skips opt-in scenarios"
grep -q 'cuad) echo screen keys windows' "$ROOT/harness/lib/casement-floor.sh" && ok "floor: cuad takes screen, keys, windows" || bad "floor: cuad takes screen, keys, windows"
grep -q -- '--w2' "$ROOT/harness/scenario-build.sh" && ok "scenario-build: has --w2" || bad "scenario-build: has --w2"

# ---- the request and the browser profile
[ "$("${PY[@]}" sentence)" = "Get the specs of the lamp on this page, then draw its front view with sizes in the drawing app with a few helpers, and save the drawing." ] \
  && ok "sentence: as the owner wrote it" || bad "sentence: as the owner wrote it"
prefs=$("${PY[@]}" browser-prefs --download-dir /run/out)
has "prefs: downloads go to the run's folder" "$prefs" 'user_pref("browser.download.dir", "/run/out");'
has "prefs: the folder, not the desktop" "$prefs" 'user_pref("browser.download.folderList", 2);'
has "prefs: the folder is used" "$prefs" 'user_pref("browser.download.useDownloadDir", true);'
has "prefs: nothing is asked" "$prefs" 'user_pref("browser.download.always_ask_before_handling_new_types", false);'
has "prefs: no first-run page" "$prefs" 'user_pref("browser.aboutwelcome.enabled", false);'
[ "$("${PY[@]}" w2-unknown 2>&1 | head -c 0; echo done)" = done ] && ok "unknown commands are w1's to refuse" || bad "unknown commands are w1's to refuse"
"${PY[@]}" loopback http://127.0.0.1:18090 >/dev/null; code "w1 commands still answer through w2.py" 0 $?

# ---- the file server's mounts (no socket: the handler's path mapping only)
python3 -I - "$HERE/lib/w1.py" "$scratch" <<'P' && ok "server: /lamp/ and /draw/ map to their own folders, /fonts/ to the fonts" || bad "server: mounts"
import importlib.util, sys, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("w1", sys.argv[1]); w1 = importlib.util.module_from_spec(spec); spec.loader.exec_module(w1)
root = Path(sys.argv[2])
for d in ("lamp", "draw", "fonts"):
    (root / d).mkdir(); (root / d / "index.html").write_text(d)
(root / "draw" / "main.js").write_text("x")
mounts = w1.parse_mounts([f"/lamp/={root}/lamp", f"/draw/={root}/draw", f"/fonts/={root}/fonts"])
H = w1.mounted_handler(None, mounts)
def where(p):
    h = H.__new__(H); h.directory = "/"
    return h.translate_path(p)
assert where("/lamp/") == f"{root}/lamp/", where("/lamp/")
assert where("/draw/main.js") == f"{root}/draw/main.js", where("/draw/main.js")
assert where("/fonts/a/b.woff2") == f"{root}/fonts/a/b.woff2", where("/fonts/a/b.woff2")
assert where("/draw/main.js?x=1") == f"{root}/draw/main.js"
assert not os.path.exists(where("/other/x"))
try:
    w1.parse_mounts(["lamp=/x"]); raise SystemExit("a bad mount was accepted")
except ValueError:
    pass
P

# ---- canned drawings
python3 -I - "$scratch" <<'P'
import json, sys
from pathlib import Path
d = Path(sys.argv[1]) / "drawings"; d.mkdir()
def el(kind, x, y, w, h, **kw):
    return {"type": kind, "x": x, "y": y, "width": w, "height": h, "isDeleted": False, **kw}
def text(s, x, y): return el("text", x, y, 80, 20, text=s, originalText=s)
def doc(elements, kind="excalidraw"): return {"type": kind, "version": 2, "source": "canned", "elements": elements, "appState": {}, "files": {}}
S = 2.0  # drawing units per mm
lamp = [
    el("rectangle", 60, 576, 160 * S, 12 * S),             # base: 320 wide
    el("rectangle", 206, 196, 14 * S, 190 * S),            # lower arm
    el("ellipse", 194, 144, 26 * S, 26 * S),               # joint (top of the lamp: y = 144)
    el("rectangle", 220, 158, 150 * S, 14 * S),            # upper arm
    el("diamond", 450, 172, 110 * S, 72 * S),              # shade: 220 wide
    el("line", 60, 620, 285 * S, 0),                       # a dimension line (no thickness: not a body)
    el("arrow", 640, 144, 0, 228 * S),                     # another
    text("285 mm", 200, 625), text("Height: 228mm", 650, 300), text("Base 160 mm", 100, 560), text("Shade 11 cm", 450, 140),
]
(d / "good.excalidraw").write_text(json.dumps(doc(lamp)))
(d / "few.excalidraw").write_text(json.dumps(doc(lamp[:2] + lamp[7:])))
skew = [dict(e) for e in lamp]
skew[0]["width"] = 700   # a base far too wide
(d / "skew.excalidraw").write_text(json.dumps(doc(skew)))
(d / "nosizes.excalidraw").write_text(json.dumps(doc(lamp[:7] + [text("lamp", 5, 5), text("front", 5, 30)])))
(d / "partsizes.excalidraw").write_text(json.dumps(doc(lamp[:7] + [text("285 mm", 5, 5)])))
deleted = [dict(e) for e in lamp]
for e in deleted[:3]: e["isDeleted"] = True
(d / "deleted.excalidraw").write_text(json.dumps(doc(deleted)))
(d / "wrongtype.excalidraw").write_text(json.dumps(doc(lamp, kind="excalidraw/clipboard")))
(d / "notjson.excalidraw").write_text("{ not json")
# the same lamp drawn at another scale, with the base as an ellipse (a disc seen from the front)
half = [dict(e, x=e["x"] / 2, y=e["y"] / 2, width=e["width"] / 2, height=e["height"] / 2) for e in lamp]
half[0]["type"] = "ellipse"
(d / "half.excalidraw").write_text(json.dumps(doc(half)))
P
rows() { "${PY[@]}" check --run "$scratch/$1" --expected "$FIX/expected.json"; }
mkrun() { mkdir -p "$scratch/$1/out"; cp "$scratch/drawings/$2.excalidraw" "$scratch/$1/out/lamp.excalidraw"; }

mkrun r-good good; res=$(rows r-good); code "drawing: a good drawing passes" 0 $?
has "drawing: file found" "$res" "PASS	a drawing file (.excalidraw) was saved in the run folder	lamp.excalidraw"
has "drawing: shapes counted (arrows and text are not shapes)" "$res" "found 6 ("
has "drawing: sizes read in mm, cm and without a space" "$res" "all of 285, 160, 228 mm are written"
has "drawing: proportions measured" "$res" "PASS	base, height and shade stand in the page's proportions (within 15%)"
mkrun r-half half; res=$(rows r-half); code "drawing: the same lamp at half the scale passes" 0 $?
mkrun r-few few; res=$(rows r-few); code "drawing: too few shapes fails" 1 $?
has "drawing: says how many" "$res" "FAIL	at least 4 shapes	found 2"
mkrun r-skew skew; res=$(rows r-skew); code "drawing: wrong proportions fail" 1 $?
has "drawing: names the proportion check" "$res" "FAIL	base, height and shade stand in the page's proportions"
mkrun r-nosizes nosizes; res=$(rows r-nosizes); code "drawing: no sizes fails" 1 $?
has "drawing: says no size text" "$res" "no text with a size in mm was found"
mkrun r-part partsizes; res=$(rows r-part); code "drawing: some sizes missing fails" 1 $?
has "drawing: names what is missing" "$res" "missing 160, 228 mm"
mkrun r-del deleted; res=$(rows r-del); code "drawing: deleted shapes do not count" 1 $?
mkrun r-type wrongtype; res=$(rows r-type); code "drawing: a clipboard file is not a drawing" 1 $?
has "drawing: says the type" "$res" "not \"excalidraw\""
mkrun r-bad notjson; res=$(rows r-bad); code "drawing: a file that is not JSON fails" 1 $?
mkdir -p "$scratch/r-none/out"; res=$(rows r-none); code "drawing: no file fails" 1 $?
has "drawing: says none found" "$res" "none found"

# ---- the sheets, read from a canned bus record
python3 -I - "$scratch/bus.jsonl" <<'P'
import json, sys
brief = "Specs: base 160 mm, height 228 mm, shade 110 mm. Draw the front view with sizes."
def request(i, brief_text=None, gesture="press"):
    r = {"id": f"c-{i}", "app": "org.quire.Cua", "action": "Use an app on screen", "effect": "write", "gesture": gesture}
    if brief_text is not None:
        r.update(app="org.quire.Companion", action="Check what the helpers will work from", effect="read",
                 brief={"title": "Lamp", "text": brief_text, "flags": [], "pieces": ["base", "arms", "shade"]})
    return r
def call(r): return {"type": "method_call", "interface": "org.quire.Confirm1", "member": "Confirm", "payload": {"data": [json.dumps(r)]}}
def reply(written=None):
    v = {"scope": "once", "receipt": {"id": "x"}}
    if written is not None: v["written"] = written
    return {"type": "signal", "interface": "org.quire.Intents1.Request", "member": "Response",
            "payload": {"data": [0, json.dumps({"kind": "allowed", "v": v})]}}
lines = [call(request(1)), reply(), call(request(2, brief)), reply(brief), {"type": "signal", "interface": "x", "member": "y"}]
open(sys.argv[1], "w").write("\n".join(json.dumps(m) for m in lines) + "\nnot json\n")
json.dump({"brief": brief}, open(sys.argv[1] + ".brief", "w"))
P
sheets=$("${PY[@]}" sheets --bus "$scratch/bus.jsonl"); code "sheets: read from the bus record" 0 $?
[ "$(wc -l <<<"$sheets")" = 2 ] && ok "sheets: two confirmations seen" || bad "sheets: two confirmations seen" "$sheets"
has "sheets: a step sheet answered once" "$sheets" '"kind": "step"'
has "sheets: the brief's words came back unchanged" "$sheets" '"written": "unchanged"'
[ "$("${PY[@]}" sheet-info --bus "$scratch/bus.jsonl" --id c-2)" = "$(printf 'brief\tpress\torg.quire.Companion\tCheck what the helpers will work from')" ] \
  && ok "sheet-info: a brief sheet is known as one" || bad "sheet-info: a brief sheet is known as one"
[ "$("${PY[@]}" sheet-info --bus "$scratch/bus.jsonl" --id c-1 | cut -f1)" = step ] && ok "sheet-info: a step sheet" || bad "sheet-info: a step sheet"
"${PY[@]}" sheet-info --bus "$scratch/bus.jsonl" --id nope >/dev/null; code "sheet-info: an unknown sheet" 1 $?

# ---- the report from a canned run
run="$scratch/run"
mkdir -p "$run/out" "$run/shots" "$run/agents/.local/state/quire/inferd"
cp "$FIX/trace.jsonl" "$run/"
cp "$FIX/audit.jsonl" "$run/agents/.local/state/quire/inferd/audit.jsonl"
printf 'start\t1000000000000\t1000\ncasement_up\t1005000000000\t1005\nstack_up\t1010000000000\t1010\npage_open\t1015000000000\t1015\nasked\t1020000000000\t1020\nfirst_turn\t1025000000000\t1025\nfirst_screen_step\t1030000000000\t1030\ndrawing_saved\t1100000000000\t1100\nsvg_saved\t1110000000000\t1110\nfinished\t1120000000000\t1120\n' >"$run/stamps.tsv"
cp "$scratch/drawings/good.excalidraw" "$run/out/lamp.excalidraw"
printf '<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0"/></svg>\n' >"$run/out/lamp.svg"
cp "$scratch/bus.jsonl" "$run/bus.jsonl"
printf '1030\tc-1\tstep\torg.quire.Cua: Use an app on screen\tAllow once\tEnter\tanswered\n1040\tc-2\tbrief\torg.quire.Companion: Check\tUse this brief (Allow once)\tEnter\tanswered\n' >"$run/sheets.tsv"
: >"$run/shots/01-pages-open.png"
printf 'out/lamp.excalidraw\nout/lamp.svg\n' >"$run/files-made.txt"
report=$("${PY[@]}" report --run "$run" --expected "$FIX/expected.json"); code "report: a good run exits 0" 0 $?
has "report: headline" "$report" "Workflow W2 (lamp page to a drawing): PASS"
has "report: drawing check" "$report" "a drawing file (.excalidraw) was saved"
has "report: brief check" "$report" "every brief sheet was answered with its words unchanged"
has "report: svg noted" "$report" "lamp.svg"
has "report: sheets answered" "$report" "Use this brief (Allow once)"
has "report: sheets on the bus" "$report" "As the bus carried them"
has "report: stage since start" "$(tr -s ' ' <<<"$report")" "| drawing file saved | 70.0 | 100.0 |"
has "report: screen looks counted" "$report" "3 looks at the screen by screen-model"
has "report: picture listed" "$report" "shots/01-pages-open.png"
[ -s "$run/report.md" ] && ok "report: report.md written" || bad "report: report.md written"
rm -f "$run/out/lamp.svg"
report=$("${PY[@]}" report --run "$run" --expected "$FIX/expected.json"); code "report: no svg does not fail the run" 0 $?
has "report: says no svg" "$report" "no .svg picture was saved (optional)"
cp "$scratch/drawings/skew.excalidraw" "$run/out/lamp.excalidraw"
report=$("${PY[@]}" report --run "$run" --expected "$FIX/expected.json"); code "report: a wrong drawing exits 1" 1 $?
has "report: headline FAIL" "$report" "FAIL"
cp "$scratch/drawings/good.excalidraw" "$run/out/lamp.excalidraw"; cp "$FIX/trace-guard.jsonl" "$run/trace.jsonl"
report=$("${PY[@]}" report --run "$run" --expected "$FIX/expected.json"); code "report: the guard's words fail the run" 1 $?
cp "$FIX/trace.jsonl" "$run/trace.jsonl"
sed 's/"written": "[^"]*"//; s/,\\"written\\":\\"[^\\]*\\"//' "$run/bus.jsonl" >"$run/bus-nowritten.jsonl"
python3 -I - "$run/bus.jsonl" <<'P'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.startswith("{")]
for m in rows:
    if m.get("member") == "Response":
        v = json.loads(m["payload"]["data"][1]); v["v"].pop("written", None); m["payload"]["data"][1] = json.dumps(v)
open(sys.argv[1], "w").write("\n".join(json.dumps(m) for m in rows) + "\n")
P
report=$("${PY[@]}" report --run "$run" --expected "$FIX/expected.json"); code "report: a brief answered without its words fails the run" 1 $?
has "report: names the brief check" "$report" "FAIL | every brief sheet was answered"

# ---- the W1 rig still stands (it shares w1.py)
"$HERE/w1-selftest.sh" >"$scratch/w1.out" 2>&1; code "w1 selftest still passes" 0 $?

if [ "$fails" = 0 ]; then echo "w2 selftest: all checks pass"; else echo "w2 selftest: $fails failed"; exit 1; fi
