#!/usr/bin/env bash
# Scenario `detent-on-casement-at-1.5` (plan 20 §5.2, P0 exit): detent maps, resizes and is crisp at
# output scale 1.5 on a headless casement, in the jail.
#
# detent (the Settings app, built at its manifest pin by harness/scenario-build.sh) runs against casement's
# 2880x1620 headless output at scale 1.5 (1920x1080 logical). Steps, each waiting on what it needs:
#   boot     casement up at scale 1.5, devices plugged
#   map      detent maps at the 900x640 logical size it asks for (`debug windows`); the client's own
#            protocol log (WAYLAND_DEBUG) shows preferred_scale(180) before it drew, wp_viewport destination
#            900x640 and wl_shm buffers of 1350x960: the buffer is the physical size, round(logical x 1.5)
#   resize   a bottom-right drag (the first press only focuses: detent's grab zones take the second)
#            moves the corner by (+100, +40): the client gets a configure of 1000x680, the frame is 1000x680,
#            the viewport destination follows and new buffers of 1500x1020 are attached
#   crisp    `casementctl shot --output`: the capture is the output's 2880x1620 physical pixels and the
#            window's sidebar edge (a known element: a 240-logical-pixel sidebar, white against the
#            content grey, with its 1-logical-pixel rule) is on physical column 360 exactly, with no
#            smeared pixels around it, on every row of the sidebar. A tier-P byte golden is not used:
#            the page's text and icons move with every quire pin; the geometry is what scale 1.5 decides.
#
# budget: 180
# Exit: 0 pass | 1 a step failed | 2 outside the jail | 3 artefacts missing (harness/scenario-build.sh).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/scenario.sh"
require_jail
DETENT="$SCEN_BUILD/detent-target/debug/detent"
scenario_need "$SCEN_TOOLS/bin/casement" "$SCEN_TOOLS/bin/casementctl" "$SCEN_TOOLS/bin/fake-logind" "$DETENT"

export SILL_COMPOSITOR=casement SILL_PREBUILT=1 SILL_PROFILE=debug
export CARGO_TARGET_DIR="$SCEN_BUILD/sill-target" CASEMENT_REPO="$SCEN_SIB/casement" CASEMENT_TOOLS="$SCEN_TOOLS"
# shellcheck source=/dev/null
source "$SCEN_SRC/sill/dev/lib/all.sh"
OUT_DIR=$(scenario_out detent-1.5)
DETENT_PID=

cleanup() {
  [ -z "$DETENT_PID" ] || kill "$DETENT_PID" 2>/dev/null
  stop_compositor
  scratch_drop
}
trap cleanup EXIT

windows() { casementctl debug windows; }
window_size() { windows | python3 -c 'import json,sys; w=json.load(sys.stdin); print("%dx%d" % tuple(w[0]["frame"][2:])) if w else sys.exit(1)'; }
# wait_size WxH: up to 10 s for the first window's frame to be WxH.
wait_size() {
  for _ in $(seq 100); do [ "$(window_size 2>/dev/null)" = "$1" ] && return 0; sleep 0.1; done
  echo "the window is $(window_size 2>&1), not $1" >&2
  return 1
}
# wait_log REGEX: up to 10 s for a line of detent's protocol log.
wait_log() {
  for _ in $(seq 100); do grep -qE -e "$1" "$LOG" && return 0; sleep 0.1; done
  echo "detent's log never showed: $1" >&2
  return 1
}

step_boot() {
  start_compositor 2880x1620 || return 1
  set_scale 1.5 || return 1
  casementctl debug inject "device plug keyboard" "device plug pointer" >/dev/null || return 1
  [ "$(output_scale)" = 1.5 ] || { echo "the output's scale is $(output_scale)" >&2; return 1; }
}

step_map() {
  scratch_new
  mkdir -p "$SCRATCH/home" "$SCRATCH/data"
  LOG="$OUT_DIR/detent.log"
  nested env HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/home/.config" XDG_DATA_HOME="$SCRATCH/data" \
    XDG_DATA_DIRS="$SCRATCH/data" WAYLAND_DEBUG=1 "$DETENT" >"$LOG" 2>&1 &
  DETENT_PID=$!
  wait_size 900x640 || { kill -0 "$DETENT_PID" 2>/dev/null || tail -20 "$LOG" >&2; return 1; }
  wait_log '-> wl_shm_pool#[0-9]+\.create_buffer\(.*, 1350, 960, ' || return 1
  grep -qE 'wp_fractional_scale_v1#[0-9]+\.preferred_scale\(180\)' "$LOG" || { echo "no preferred_scale(180)" >&2; return 1; }
  grep -qE 'wp_viewport#[0-9]+\.set_destination\(900, 640\)' "$LOG" || { echo "no viewport destination 900x640" >&2; return 1; }
  echo "mapped 900x640, scale 180, viewport 900x640, buffers 1350x960" >&2
}

window_active() { windows | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)[0]["active"] else 1)'; }

step_resize() {
  # The first press only focuses the window (detent's edge zones take the first mouse); the second, once
  # the window is active, grabs the corner: the client asks for the resize, then the drag moves it.
  casementctl debug inject "move 1000 500" "move 1405 855" "press left" "release left" >/dev/null || return 1
  for _ in $(seq 100); do window_active && break; sleep 0.1; done
  window_active || { echo "the window never took focus" >&2; return 1; }
  # The pointer leaves and comes back, so the client's hover is on the corner zone when the press lands.
  casementctl debug inject "move 1000 500" "move 1405 855" >/dev/null || return 1
  casementctl debug wait settled --timeout 10000 >/dev/null
  casementctl debug inject "press left" >/dev/null || return 1
  wait_log 'xdg_toplevel#[0-9]+\.resize\(' || return 1
  casementctl debug inject "move 1450 880" "move 1505 895" "release left" >/dev/null || return 1
  wait_size 1000x680 || return 1
  wait_log 'xdg_toplevel#[0-9]+\.configure\(1000, 680, ' || return 1
  wait_log 'wp_viewport#[0-9]+\.set_destination\(1000, 680\)' || return 1
  wait_log '-> wl_shm_pool#[0-9]+\.create_buffer\(.*, 1500, 1020, ' || return 1
  echo "resized to 1000x680: configure, viewport and 1500x1020 buffers" >&2
}

step_crisp() {
  local png="$OUT_DIR/output.png"
  casementctl debug wait settled --timeout 10000 >/dev/null
  sleep 1
  casementctl shot --output HEADLESS-1 "$png" >"$OUT_DIR/shot.log" 2>&1 || { cat "$OUT_DIR/shot.log" >&2; return 1; }
  python3 -I - "$png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
if im.size != (2880, 1620):
    sys.exit(f"the capture is {im.size[0]}x{im.size[1]}, not 2880x1620")
# The window's frame is (510, 220) logical: physical (765, 330). Its sidebar is 240 logical wide.
x0, y0, edge = 765, 330, 360
white, rule, soft, grey = (255, 255, 255), (217, 217, 217), (225, 226, 226), (233, 234, 235)
rows = range(150, 900, 25)
strips = {tuple(im.getpixel((x0 + x, y0 + y)) for x in range(edge - 8, edge + 8)) for y in rows}
if len(strips) != 1:
    sys.exit(f"the sidebar edge differs between rows: {len(strips)} variants")
strip = next(iter(strips))
want = (white,) * 8 + (rule, soft) + (grey,) * 6
if strip != want:
    sys.exit(f"the sidebar edge is not the crisp rule at column {edge}: {strip}")
# The window ends where it should: 1500x1020 physical, the desktop outside it.
inside, outside = im.getpixel((x0 + 1499, y0 + 500)), im.getpixel((x0 + 1500, y0 + 500))
if inside == outside:
    sys.exit("the window's right edge is not at physical column 1500")
print(f"sidebar edge exact at column {edge}, the rule and its one soft pixel, same on {len(rows)} rows; window ends at 1500", file=sys.stderr)
PY
}

run_steps step_boot step_map step_resize step_crisp
if [ "$STATUS" != 0 ]; then
  echo "--- detent.log (tail)" >&2; tail -15 "$OUT_DIR/detent.log" >&2
  [ -z "${CASEMENT_ENV:-}" ] || { echo "--- casement.log (tail)" >&2; tail -20 "$(dirname "$CASEMENT_ENV")/casement.log" >&2; }
fi
exit "$STATUS"
