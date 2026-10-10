#!/usr/bin/env bash
# Scenario `appearance-reaches-quire-apps` (plan §4.14, the second half of appearance-reaches-apps; FD-08, P1):
# an appearance change written to `quire/appearance.toml` reaches a quire app that is not sill,
# running on the jailed headless casement.
#
# The app is detent (the Settings app, built at its manifest pin by harness/scenario-build.sh): a quire ds
# root that follows `quire/appearance.toml` through ds-settings' watch. The change is made the way a
# settings app makes it, by writing the file in the scratch XDG_CONFIG_HOME (never a real one). The proof is
# pixels: `casementctl shot --output` (P1-C1: the output's last frame through the debug bus), cropped to the
# window's frame from `casementctl debug windows`, its mean luminance compared. Nothing is read from the app.
#
#   boot      casement up (1920x1080, scale 1), devices plugged
#   baseline  theme = "light", detent started: it maps 900x640 and its window interior is light (mean luminance >= 150)
#   dark      theme = "dark" is written: the window interior turns dark (<= 100, at least 60 below the baseline), no restart
#   light     the file returns to light: the interior returns to the baseline (within 12)
#   alive     the same detent pid is running throughout and the window is still mapped at 900x640
#
# Each wait is on the window (`debug windows`) or on a fresh shot, polled up to 20 s, never a fixed sleep.
# Thresholds are on the window interior inset 24 px from its frame, so the frame, shadow and desktop are not measured.
# budget: 120
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
OUT_DIR=$(scenario_out appearance-quire)
DETENT_PID=
BASE_LUM=

cleanup() {
  [ -z "$DETENT_PID" ] || kill "$DETENT_PID" 2>/dev/null
  stop_compositor
  scratch_drop
}
trap cleanup EXIT

# The appearance file, as the settings app writes it.
write_theme() {
  mkdir -p "$SCRATCH/home/.config/quire"
  printf '[appearance]\ntheme = "%s"\n' "$1" >"$SCRATCH/home/.config/quire/appearance.toml"
}

windows() { casementctl debug windows; }
# frame: "X,Y,W,H" of the first window, nothing (exit 1) while there is none.
frame() { windows | python3 -c 'import json,sys; w=json.load(sys.stdin); print("%d,%d,%d,%d" % tuple(w[0]["frame"])) if w else sys.exit(1)'; }

# interior_lum PNG FRAME: the mean luminance (0-255) of the window's interior in a shot.
interior_lum() {
  python3 -I - "$1" "$2" <<'PY'
import sys
import numpy as np
from PIL import Image
x, y, w, h = (int(v) for v in sys.argv[2].split(","))
a = np.array(Image.open(sys.argv[1]).convert("RGB")).astype(float)
c = a[y + 24 : y + h - 24, x + 24 : x + w - 24]
if c.size == 0:
    sys.exit("the interior is empty: frame " + sys.argv[2] + " in a " + str(a.shape[1]) + "x" + str(a.shape[0]) + " shot")
print("%.1f" % (c[..., 0] * 0.2126 + c[..., 1] * 0.7152 + c[..., 2] * 0.0722).mean())
PY
}

# shot_lum NAME: shoots the output to OUT_DIR/NAME.png and prints the window interior's mean luminance.
shot_lum() {
  local fr; fr=$(frame) || return 1
  casementctl shot --output HEADLESS-1 "$OUT_DIR/$1.png" >"$OUT_DIR/shot.log" 2>&1 || { cat "$OUT_DIR/shot.log" >&2; return 1; }
  interior_lum "$OUT_DIR/$1.png" "$fr"
}

# wait_lum NAME TEST: up to 20 s of fresh shots until TEST (a python expression of lum) holds; sets LUM.
wait_lum() {
  local name=$1 test=$2 i
  for i in $(seq 40); do
    LUM=$(shot_lum "$name" 2>/dev/null) || LUM=
    if [ -n "$LUM" ] && python3 -I -c "import sys; lum=float(sys.argv[1]); sys.exit(0 if ($test) else 1)" "$LUM"; then return 0; fi
    sleep 0.5
  done
  echo "$name: the window's luminance is '${LUM:-unreadable}', not ($test)" >&2
  return 1
}

step_boot() {
  start_compositor 1920x1080 || return 1
  casementctl debug inject "device plug keyboard" "device plug pointer" >/dev/null || return 1
}

step_baseline() {
  scratch_new
  mkdir -p "$SCRATCH/home" "$SCRATCH/data"
  write_theme light
  nested env HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/home/.config" XDG_DATA_HOME="$SCRATCH/data" \
    XDG_DATA_DIRS="$SCRATCH/data" "$DETENT" >"$OUT_DIR/detent.log" 2>&1 &
  DETENT_PID=$!
  local i
  for i in $(seq 100); do [ "$(frame 2>/dev/null | cut -d, -f3,4)" = 900,640 ] && break; sleep 0.1; done
  [ "$(frame 2>/dev/null | cut -d, -f3,4)" = 900,640 ] || { echo "detent never mapped at 900x640" >&2; return 1; }
  casementctl debug wait settled --timeout 10000 >/dev/null
  wait_lum base 'lum >= 150' || return 1
  BASE_LUM=$LUM
  echo "light: interior luminance $BASE_LUM" >&2
}

step_dark() {
  write_theme dark
  wait_lum dark "lum <= 100 and $BASE_LUM - lum >= 60" || return 1
  echo "dark: interior luminance $LUM (was $BASE_LUM)" >&2
}

step_light() {
  write_theme light
  wait_lum back "abs(lum - $BASE_LUM) <= 12" || return 1
  echo "light again: interior luminance $LUM" >&2
}

step_alive() {
  kill -0 "$DETENT_PID" 2>/dev/null || { echo "detent exited during the run" >&2; return 1; }
  [ "$(frame | cut -d, -f3,4)" = 900,640 ] || { echo "the window is no longer 900x640" >&2; return 1; }
}

run_steps step_boot step_baseline step_dark step_light step_alive
if [ "$STATUS" != 0 ]; then
  echo "--- detent.log (tail)" >&2; tail -15 "$OUT_DIR/detent.log" >&2
  [ -z "${CASEMENT_ENV:-}" ] || { echo "--- casement.log (tail)" >&2; tail -20 "$(dirname "$CASEMENT_ENV")/casement.log" >&2; }
  echo "--- shots in the scratch dir: $OUT_DIR" >&2
fi
exit "$STATUS"
