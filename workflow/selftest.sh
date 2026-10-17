#!/usr/bin/env bash
# The workflow helper's self-test: runs lib/timing.py on fixtures, with no session, no journal and no GPU.
#
#   workflow/selftest.sh
#
# Checks the line parsing, the pairing of a launch with its window, the stage arithmetic, the
# p50/p95/max numbers, the slower-than-last-time flag, the GPU lookup (a fixture /proc and a fixture
# lspci answer) and the app lookup with a fake distribution. Touches only a scratch folder.
#
# Exit: 0 every check holds, 1 a check failed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$HERE/fixtures"
PY=(python3 -I "$HERE/lib/timing.py")
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fails=0

ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; [ -z "${2:-}" ] || printf '     %s\n' "$2"; fails=$((fails + 1)); }
tab() { printf '%b' "${1//\\t/\\t}"; }
has() { # NAME TEXT NEEDLE (NEEDLE may hold \t)
  if grep -qF -- "$(tab "$3")" <<<"$2"; then ok "$1"; else bad "$1" "missing [$3] in: $(head -c 600 <<<"$2")"; fi
}
lacks() { if grep -qF -- "$(tab "$3")" <<<"$2"; then bad "$1" "unexpected [$3]"; else ok "$1"; fi; }
squeeze() { tr -s ' ' <<<"$1"; }

launch=$("${PY[@]}" pick launch <"$FIX/journal.txt")
has "parse: the launch line is found, the decoy 'launch failed' line is not" "$launch" "launch desktop_id=firefox unit=app-firefox-1.scope requested_at=100000000000"
[ "$("${PY[@]}" field "$launch" unit pid)" = "$(tab 'app-firefox-1.scope\t5001')" ] && ok "field: unit and pid" || bad "field: unit and pid"

ready=$("${PY[@]}" wait --log-file "$FIX/journal.txt" --app-ids firefox --pid 5001 --after-connected 100000000000 --timeout 0)
has "pairing: skips the older firefox window and the foot window" "$ready" "connected_at=100400000000 first_commit_at=100700000000"
if "${PY[@]}" wait --log-file "$FIX/journal.txt" --app-ids nothere --after-connected 100000000000 --timeout 0 >/dev/null; then
  bad "pairing: an app with no window times out"; else ok "pairing: an app with no window times out"; fi
ansi=$("${PY[@]}" wait --log-file "$FIX/journal.txt" --app-ids firefox --after-connected 100440000000 --timeout 0)
has "parse: a line with colours and a timestamp is read" "$ansi" "connected_at=100450000000"

rows=$("${PY[@]}" rows --kind launch --launch "$launch" --ready "$ready" --app firefox --phase cold --round 0)
has "stages: request to process"   "$rows" "request_to_spawned\t30.0"
has "stages: process to connected" "$rows" "spawned_to_connected\t370.0"
has "stages: connected to commit"  "$rows" "connected_to_first_commit\t300.0"
has "stages: commit to frame"      "$rows" "first_commit_to_first_frame\t16.0"
has "stages: frame to settled"     "$rows" "first_frame_to_settled\t200.0"
has "stages: total to frame"       "$rows" "total_to_first_frame\t716.0"
has "stages: total to settled"     "$rows" "total_to_settled\t916.0"
dialog=$("${PY[@]}" rows --kind dialog --request-at 100650000000 --ready "$ready" --app dialog --phase cold --round 0)
has "dialog: request to first picture" "$dialog" "request_to_first_commit\t50.0"
has "dialog: total request to frame"   "$dialog" "request_to_first_frame\t66.0"

summary=$("${PY[@]}" summarize --raw "$FIX/raw-new.tsv")
has "stats: cold, p50, p95, max and count of five warm launches" "$(squeeze "$summary")" "firefox on screen -> settled 400 120 200 200 5"
has "stats: p95 of five values with one outlier is the outlier" "$(squeeze "$summary")" "firefox connected -> first picture 90 30 39 39 5"
has "summary: the GPU line" "$summary" "firefox   Intel [i915, 0000:00:02.0]"
has "where the time went: the biggest stage first" "$summary" "1. login: the shell drawing the bar and dock takes about 650 ms"
has "where the time went: the second" "$summary" "2. firefox: the app starting up until it reaches the desktop takes about 500 ms"

trend=$("${PY[@]}" summarize --raw "$FIX/raw-new.tsv" --previous "$FIX/raw-old.tsv")
has "trend: p95 doubled is flagged" "$(squeeze "$trend")" "SLOWER firefox on screen -> settled p95 100 -> 200 ms (+100 ms, +100%)"
has "trend: +43% and +30 ms is flagged" "$(squeeze "$trend")" "SLOWER foot first picture -> on screen p95 70 -> 100 ms (+30 ms, +43%)"
lacks "trend: +30% but only +9 ms is not flagged" "$(squeeze "$trend")" "SLOWER firefox connected"
lacks "trend: +10% and +50 ms is not flagged" "$(squeeze "$trend")" "SLOWER firefox started"
[ "$(grep -c '^SLOWER' <<<"$trend")" = 2 ] && ok "trend: exactly two stages flagged" || bad "trend: exactly two stages flagged"
has "trend: with a previous run the section is there" "$trend" "== Compared with the previous run"
lacks "trend: no previous run, no section" "$summary" "== Compared with the previous run"

switch=$("${PY[@]}" switch --log-file "$FIX/journal.txt" --from 200000000000 --until 210000000000 2>"$scratch/switch.err")
has "switch: keyboard input to focused"   "$switch" "keyboard\trun\t0\tinput_to_focused\t5.0"
has "switch: keyboard focused to shown"   "$switch" "keyboard\trun\t1\tfocused_to_presented\t28.0"
has "switch: pointer total"               "$switch" "pointer\trun\t0\tinput_to_presented\t18.0"
[ "$(wc -l <<<"$switch")" = 9 ] && ok "switch: the change with no input time and the one outside the window are left out" || bad "switch: row count" "$switch"
has "switch: counts reported" "$(cat "$scratch/switch.err")" "2 keyboard changes seen, 2 with an input time"

has "login: shell connected" "$("${PY[@]}" login --log-file "$FIX/journal.txt")" "login\tboot\t0\tstart_to_shell_connected\t450.0"
has "login: bar and dock"    "$("${PY[@]}" login --log-file "$FIX/journal.txt")" "start_to_shell_ready\t1100.0"
has "xwayland: request to ready" "$("${PY[@]}" xwayland --log-file "$FIX/journal.txt" --after 399000000000 --app x11)" "xwayland_request_to_ready\t250.0"

gpu=$("${PY[@]}" gpu --pid 4242 --proc-root "$FIX/proc" --sys-root "$scratch/none" --lspci-file "$FIX/lspci.txt")
has "gpu: the process's own GPU, named by lspci" "$gpu" "Intel Corporation Raptor Lake-S GT1 [UHD Graphics 770] [i915, 0000:00:02.0]"
has "gpu: a child process's GPU is included"     "$gpu" "[AMD/ATI] Navi 48 [Radeon RX 9070 XT] [amdgpu, 0000:03:00.0]"
lacks "gpu: an unrelated process is not"          "$gpu" "0000:09:00.0"
mkdir -p "$scratch/proc/700/fd" "$scratch/sys/class/drm/renderD128" "$scratch/sys/devices/0000:01:00.0" "$scratch/sys/bus/drivers/nvidia"
printf '700 (blender) S 1 700 700 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 1 1 1\n' >"$scratch/proc/700/stat"
ln -s /dev/dri/renderD128 "$scratch/proc/700/fd/9"
ln -s ../../../devices/0000:01:00.0 "$scratch/sys/class/drm/renderD128/device"
ln -s ../../bus/drivers/nvidia "$scratch/sys/devices/0000:01:00.0/driver"
printf '0000:01:00.0 VGA compatible controller: NVIDIA Corporation GB203 [GeForce RTX 5070 Ti] (rev a1)\n' >"$scratch/lspci.txt"
has "gpu: a render node fd (NVIDIA prints no fdinfo) maps to its card" \
  "$("${PY[@]}" gpu --pid 700 --proc-root "$scratch/proc" --sys-root "$scratch/sys" --lspci-file "$scratch/lspci.txt")" "NVIDIA Corporation GB203 [GeForce RTX 5070 Ti] [nvidia, 0000:01:00.0]"
has "gpu: no GPU opened says so" "$("${PY[@]}" gpu --pid 9999 --proc-root "$scratch/proc" --sys-root "$scratch/sys" --lspci-file "$scratch/lspci.txt")" "none (no GPU opened"

mkdir -p "$scratch/share/applications" "$scratch/bin"
for id in foot org.kde.kcalc; do : >"$scratch/share/applications/$id.desktop"; done
printf 'StartupWMClass=KCalc\n' >>"$scratch/share/applications/org.kde.kcalc.desktop"
for b in foot kcalc xeyes; do printf '#!/bin/sh\n' >"$scratch/bin/$b"; chmod +x "$scratch/bin/$b"; done
printf 'ID=fedora\n' >"$scratch/os-release"
apps=$("${PY[@]}" apps --file "$HERE/apps.toml" --share-dirs "$scratch/share" --path "$scratch/bin" --os-release "$scratch/os-release")
has "apps: foot is installed" "$apps" "foot\tok\twayland\tfoot\tfoot\t60\tfoot\tfoot\t-"
has "apps: the fallback is used and its window class counts" "$apps" "qt6\tok\twayland\torg.kde.kcalc\tkcalc,org.kde.kcalc"
has "apps: Firefox missing gets the Fedora hint" "$apps" "firefox\tmissing"
has "apps: the hint names the package manager" "$apps" "sudo dnf install firefox"
has "apps: xeyes has no desktop entry" "$apps" "x11\tnodesktop"
has "apps: Blender gets the longer timeout" "$apps" "blender\tmissing\twayland\t-\t-\t120"
printf 'ID=ubuntu\nID_LIKE=debian\n' >"$scratch/os-release"
has "apps: Ubuntu hint" "$("${PY[@]}" apps --file "$HERE/apps.toml" --only gtk4 --share-dirs "$scratch/share" --path "$scratch/bin" --os-release "$scratch/os-release")" "sudo apt install gnome-text-editor   or   sudo apt install gtk-4-examples"

if [ "$fails" = 0 ]; then echo "workflow selftest: all checks pass"; else echo "workflow selftest: $fails failed"; exit 1; fi
