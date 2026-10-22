#!/usr/bin/env bash
# The W1 rig's self-test: checks the parts of w1-blender.sh that need no session, no model and no Blender.
#
#   workflow/w1-selftest.sh
#
# Checks the option handling, the refusal when a model is not chosen, the refusal without a Wayland desktop, the
# build list, the page's sizes, the model-file rewrite, the sentence, the install hints, the comparison of a saved
# file's size with the page, the guard's words and the report built from a canned run. Touches only a scratch folder.
#
# Exit: 0 every check holds, 1 a check failed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$HERE/fixtures/w1"
W1=("$HERE/w1-blender.sh")
PY=(python3 -I "$HERE/lib/w1.py")
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fails=0

ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -z "${2:-}" ] || printf '     %s\n' "$2"; fails=$((fails + 1)); }
has() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "missing [$3] in: $(head -c 500 <<<"$2")"; fi; }
lacks() { if grep -qF -- "$3" <<<"$2"; then bad "$1" "unexpected [$3]"; else ok "$1"; fi; }
code() { # NAME WANT ACTUAL
  if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "exit $3, wanted $2"; fi
}

# ---- the script's own options and refusals (no session needed: it stops before it starts anything)
out=$("${W1[@]}" --help 2>&1); code "help: exit 0" 0 $?
has "help: names both model variables" "$out" "W1_PLANNER_URL"
out=$("${W1[@]}" --nonsense 2>&1); code "options: an unknown option is refused" 2 $?
out=$("${W1[@]}" --timeout abc 2>&1); code "options: a timeout that is no number is refused" 2 $?
out=$("${W1[@]}" --print-build 2>&1); code "print-build: exit 0" 0 $?
for p in "-p casement -p casementctl" "--bin fake-logind" "-p sill --features debug" "-p cuad --features fixture-callers" "-p docket-accept --bins"; do
  has "print-build: $p" "$out" "$p"
done
has "print-build: casement is a plain build" "$out" "a plain build"
lacks "print-build: casement has no test feature" "$(grep 'casementctl' <<<"$out")" "debug-inject"
out=$(env -u W1_PLANNER_URL -u W1_SCREEN_URL WAYLAND_DISPLAY=wayland-0 "${W1[@]}" 2>&1); code "no model: refused, exit 2" 2 $?
has "no model: names the assistant model" "$out" "W1_PLANNER_URL"
has "no model: names the screen model" "$out" "W1_SCREEN_URL"
has "no model: says there is no default" "$out" "There is no default"
out=$(env -u W1_SCREEN_URL W1_PLANNER_URL=http://127.0.0.1:1 WAYLAND_DISPLAY=wayland-0 "${W1[@]}" 2>&1); code "one model missing: refused" 2 $?
has "one model missing: names the screen model" "$out" "W1_SCREEN_URL"
lacks "one model missing: does not blame the assistant model" "$out" "W1_PLANNER_URL"
out=$(env -u WAYLAND_DISPLAY W1_PLANNER_URL=http://127.0.0.1:1 W1_SCREEN_URL=http://127.0.0.1:2 "${W1[@]}" 2>&1); code "no Wayland desktop: refused, exit 2" 2 $?
has "no Wayland desktop: says so" "$out" "no Wayland desktop"

# ---- the page and what the file is compared with
page=$(cat "$FIX/index.html")
for t in "285 mm" "160 mm" "228 mm" "Base" "Lower arm" "Joint" "Upper arm" "Shade" "<svg"; do has "page: holds [$t]" "$page" "$t"; done
python3 -I - "$FIX/expected.json" <<'P' && ok "expected: sizes match the page" || bad "expected: sizes match the page"
import json, sys
e = json.load(open(sys.argv[1]))
assert sorted(e["bbox_mm"]) == [160, 228, 285] and e["min_objects"] == 5
P

# ---- the helper's pure parts
has "sentence: names the folder" "$("${PY[@]}" sentence --outdir /tmp/x)" "save it as a .glb file in /tmp/x"
[ "$("${PY[@]}" loopback http://127.0.0.1:8090)" = "127.0.0.1 8090" ] && ok "loopback: accepted" || bad "loopback: accepted"
"${PY[@]}" loopback http://fatcat:8000 >/dev/null && bad "loopback: another computer is refused" || ok "loopback: another computer is refused"
"${PY[@]}" loopback https://127.0.0.1:8 >/dev/null && bad "loopback: https is refused" || ok "loopback: https is refused"
[ "$("${PY[@]}" served <<<'{"data":[{"id":"m-a"},{"id":"m-b"}]}' | tr '\n' ' ')" = "m-a m-b " ] && ok "served: the names are listed" || bad "served: the names are listed"

cat >"$scratch/entry.toml" <<'T'
id = "demo-model"
label = "Demo"
serving = { kind = "launched" }

[text_out]
tools = "server_parsed"

[[engine]]
kind = "vllm"
args = ["--max-model-len", "16384", "--tool-call-parser", "qwen3_coder", "--reasoning-parser", "qwen3"]
weights = { kind = "hf_snapshot" }
T
"${PY[@]}" catalog --src "$scratch/entry.toml" --out "$scratch/out.toml" --served demo
entry=$(cat "$scratch/out.toml")
has "catalog: now attached, with the engine line's parsers" "$entry" 'serving = { kind = "attached", v = { engine = "vllm", served_name = "demo", tool_parser = "qwen3_coder", reasoning_parser = "qwen3" } }'
"${PY[@]}" catalog --src "$scratch/entry.toml" --out "$scratch/given.toml" --served demo --tool-parser hermes
has "catalog: a given parser wins" "$(cat "$scratch/given.toml")" 'tool_parser = "hermes" } }'
sed -i 's/, "--tool-call-parser", "qwen3_coder"//' "$scratch/entry.toml"
"${PY[@]}" catalog --src "$scratch/entry.toml" --out "$scratch/none.toml" --served demo 2>/dev/null \
  && bad "catalog: an entry naming no parser is refused" || ok "catalog: an entry naming no parser is refused"
lacks "catalog: the engine rows are gone" "$entry" "[[engine]]"
lacks "catalog: the old serving line is gone" "$entry" "launched"
has "catalog: the rest is kept" "$entry" '[text_out]'
python3 -I -c 'import tomllib,sys; tomllib.loads(open(sys.argv[1]).read())' "$scratch/out.toml" && ok "catalog: still valid" || bad "catalog: still valid"

cfg=$("${PY[@]}" inferd-config --planner-id plan --planner-url http://127.0.0.1:8090 --screen-id see --screen-url http://127.0.0.1:8091)
has "inferd settings: planner engine" "$cfg" '[engines.attached."plan"]'
has "inferd settings: planner address" "$cfg" 'url = "http://127.0.0.1:8090"'
has "inferd settings: screen slot" "$cfg" '[ai.model.computer_use]'
has "inferd settings: floors stay near" "$cfg" 'screen = "local_network"'
lacks "inferd settings: nothing may go anywhere" "$cfg" '"anywhere"'
python3 -I -c 'import tomllib,sys; tomllib.loads(sys.stdin.read())' <<<"$cfg" && ok "inferd settings: valid" || bad "inferd settings: valid"
cua=$("${PY[@]}" cuad-settings --app org.blender.Blender=ask --app app.zen_browser.zen=ask)
has "screen helper settings: on" "$cua" 'enabled = "on"'
has "screen helper settings: Blender listed" "$cua" 'app = "org.blender.Blender"'

printf 'ID=fedora\n' >"$scratch/os"; has "hint: Fedora" "$("${PY[@]}" hint blender --os-release "$scratch/os")" "sudo dnf install blender"
printf 'ID=ubuntu\nID_LIKE=debian\n' >"$scratch/os"; has "hint: Ubuntu" "$("${PY[@]}" hint firefox --os-release "$scratch/os")" "sudo apt install firefox"
printf 'ID=arch\n' >"$scratch/os"; has "hint: Arch" "$("${PY[@]}" hint blender --os-release "$scratch/os")" "sudo pacman -S blender"
has "hint: Zen" "$("${PY[@]}" hint zen)" "app.zen_browser.zen"

# ---- comparing the saved file with the page
res=$("${PY[@]}" glb-compare --file "$FIX/glb-reading-pass.txt" --expected "$FIX/expected.json"); code "file size: a right-sized file passes" 0 $?
has "file size: unit named" "$res" "1 unit = 1 m"
res=$("${PY[@]}" glb-compare --file "$FIX/glb-reading-small.txt" --expected "$FIX/expected.json"); code "file size: a small file fails" 1 $?
has "file size: too few shapes" "$res" "FAIL"
res=$("${PY[@]}" glb-compare --line "W1GLB meshes=5 objects=5 bbox=0.2600,0.1700,0.2400" --expected "$FIX/expected.json"); code "file size: a few percent off still passes" 0 $?
res=$("${PY[@]}" glb-compare --line "W1GLB meshes=5 objects=5 bbox=0.22,0.16,0.228" --expected "$FIX/expected.json"); code "file size: 20% off fails" 1 $?
res=$("${PY[@]}" glb-compare --line "W1GLB meshes=5 objects=5 bbox=285,160,228" --expected "$FIX/expected.json"); code "file size: millimetre units pass" 0 $?
res=$("${PY[@]}" glb-compare --line "W1GLB meshes=5 objects=5 bbox=160,285,228" --expected "$FIX/expected.json"); code "file size: turned axes pass" 0 $?
res=$("${PY[@]}" glb-compare --line "W1GLB error=bad-file" --expected "$FIX/expected.json"); code "file size: an unreadable file fails" 1 $?
res=$("${PY[@]}" glb-compare --line "nothing here" --expected "$FIX/expected.json"); code "file size: no reading fails" 1 $?

# ---- the guard's words
"${PY[@]}" guard --trace "$FIX/trace.jsonl" >/dev/null; code "guard: a normal end is clean" 0 $?
res=$("${PY[@]}" guard --trace "$FIX/trace-guard.jsonl"); code "guard: the guard's words are found" 1 $?
has "guard: which words" "$res" "I keep getting the same answer"
printf "Couldn't do that: no.\n" >"$scratch/turn.txt"
"${PY[@]}" guard --text-file "$scratch/turn.txt" >/dev/null; code "guard: found in the typed answer too" 1 $?

# ---- the report from a canned run
run="$scratch/run"
mkdir -p "$run/out" "$run/shots" "$run/agents/.local/state/quire/inferd"
cp "$FIX/stamps.tsv" "$FIX/trace.jsonl" "$run/"
cp "$FIX/audit.jsonl" "$run/agents/.local/state/quire/inferd/audit.jsonl"
cp "$FIX/glb-reading-pass.txt" "$run/glb-reading.txt"
: >"$run/out/lamp.glb"; : >"$run/shots/01-page.png"
printf 'out/lamp.glb\nhome/part-a.blend\nhome/part-b.blend\n' >"$run/files-made.txt"
report=$("${PY[@]}" report --run "$run" --expected "$FIX/expected.json"); code "report: a good run exits 0" 0 $?
has "report: headline" "$report" "PASS"
has "report: file check" "$report" "a .glb file was saved"
has "report: stage since start" "$(tr -s ' ' <<<"$report")" "| file saved | 78.0 | 100.0 |"
has "report: assistant turns" "$report" "the assistant of this desktop"
has "report: helper turns grouped apart" "$report" "Modeller, a helper that builds shapes"
has "report: screen looks counted" "$report" "3 looks at the screen by screen-model"
has "report: two part files" "$report" "at least two"
has "report: picture listed" "$report" "shots/01-page.png"
[ -s "$run/report.md" ] && ok "report: report.md written" || bad "report: report.md written"
cp "$FIX/glb-reading-small.txt" "$run/glb-reading.txt"
report=$("${PY[@]}" report --run "$run" --expected "$FIX/expected.json"); code "report: a wrong-sized file exits 1" 1 $?
has "report: headline FAIL" "$report" "FAIL"
cp "$FIX/glb-reading-pass.txt" "$run/glb-reading.txt"; cp "$FIX/trace-guard.jsonl" "$run/trace.jsonl"
report=$("${PY[@]}" report --run "$run" --expected "$FIX/expected.json"); code "report: the guard's words fail the run" 1 $?
rm -f "$run/out/lamp.glb"
report=$("${PY[@]}" report --run "$run" --expected "$FIX/expected.json"); code "report: no file fails the run" 1 $?
has "report: says none found" "$report" "none found"

if [ "$fails" = 0 ]; then echo "w1 selftest: all checks pass"; else echo "w1 selftest: $fails failed"; exit 1; fi
