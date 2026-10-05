#!/usr/bin/env bash
# Scenario `appearance-reaches-apps` (plan §4.14): an appearance change through ds-settings reaches
# every running app, live, on a headless casement in the jail.
#
# The apps are the sill daemon's surfaces (bar, dock, OSD): each is a quire ds root that follows
# `quire/appearance.toml` through ds-settings' watch. The change is made the way a settings app
# makes it, by writing the file in the scratch XDG_CONFIG_HOME (never a real one); the proof is each
# surface's own capture (`sill debug capture`), compared by pixels. Quire apps outside sill need
# a screenshot of casement (P1-C1): that is the scenario `appearance-reaches-quire-apps`.
#
#   baseline  theme = "light": every surface captured
#   dark      theme = "dark" is written: every surface changes (>= 0.4% of its pixels) with no restart
#   light     the file returns to light: every surface returns to its baseline (< 0.2% differ)
#   alive     the same daemon pid answers `ping` throughout
#
# Each wait is on the capture, polled up to 30 s, never a fixed sleep.
# budget: 120
# Exit: 0 pass | 1 a step failed | 2 outside the jail | 3 artefacts missing (harness/scenario-build.sh).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/scenario.sh"
require_jail
scenario_need "$SCEN_TOOLS/bin/casement" "$SCEN_TOOLS/bin/casementctl" "$SCEN_TOOLS/bin/fake-logind" \
  "$SCEN_BUILD/sill-target/debug/sill"

export SILL_COMPOSITOR=casement SILL_PREBUILT=1 SILL_PROFILE=debug
export CARGO_TARGET_DIR="$SCEN_BUILD/sill-target" CASEMENT_REPO="$SCEN_SIB/casement" CASEMENT_TOOLS="$SCEN_TOOLS"
# shellcheck source=/dev/null
source "$SCEN_SRC/sill/dev/lib/all.sh"
OUT_DIR=$(scenario_out appearance-reaches-apps)
CHANGED=0.004 SETTLED=0.002
SURFACES=() DAEMON_PID=

cleanup() {
  stop_daemon
  stop_compositor
  scratch_drop
}
trap cleanup EXIT

# The appearance file, as the settings app writes it.
write_theme() {
  mkdir -p "$CONFIG/quire"
  printf '[appearance]\ntheme = "%s"\n' "$1" >"$CONFIG/quire/appearance.toml"
}

# Waits up to 30 s for surface $1 to differ from its $2 capture by $CHANGED (or, with $3 = same, to
# be within $SETTLED of it); captures into $OUT_DIR/$4-$1.png. Prints the fraction.
wait_look() {
  local surface=$1 reference=$2 want=$3 tag=$4 fraction=1
  for _ in $(seq 100); do
    # A capture that does not answer yet (a loaded host) is a poll that saw nothing, not a failure.
    capture "$surface" "$OUT_DIR/$tag-$surface.png" || { sleep 0.2; continue; }
    fraction=$(changed_fraction "$OUT_DIR/$tag-$surface.png" "$OUT_DIR/$reference-$surface.png")
    if [ "$want" = same ]; then at_least "$SETTLED" "$fraction" && { echo "$fraction"; return 0; }
    else at_least "$fraction" "$CHANGED" && { echo "$fraction"; return 0; }; fi
    sleep 0.2
  done
  echo "$fraction"
  return 1
}

expect_all() {
  local reference=$1 want=$2 tag=$3 surface fraction
  for surface in "${SURFACES[@]}"; do
    fraction=$(wait_look "$surface" "$reference" "$want" "$tag") || {
      echo "$surface: $tag is not $want as $reference (changed fraction $fraction)" >&2; return 1; }
    echo "$surface: $tag vs $reference changed fraction $fraction ($want)" >&2
  done
  kill -0 "$DAEMON_PID" 2>/dev/null && sill ping >/dev/null 2>&1 || { echo "the daemon ($DAEMON_PID) is gone" >&2; return 1; }
}

step_baseline() {
  local name surface
  start_compositor || return 1
  scratch_new
  build || return 1
  write_theme light
  # The OSD is held up for the whole run so it is a surface to capture.
  mkdir -p "$CONFIG/sill"
  printf '[osd]\nhold_ms = 60000\n' >"$CONFIG/sill/settings.toml"
  launch_daemon || return 1
  DAEMON_PID=$DAEMON
  name=$(output_name) || return 1
  SURFACES=("sill-bar-$name" "sill-dock-$name" "sill-osd-$name")
  sill debug osd volume 60 >"$OUT_DIR/osd.log" 2>&1 || return 1
  wait_surface "sill-osd-$name" 100 || { echo "the OSD never mapped" >&2; return 1; }
  # Settled: the OSD and the bar finish their first animations before the baseline is taken.
  for surface in "${SURFACES[@]}"; do await_frames_settled "$surface" 20 || { echo "$surface never settled" >&2; return 1; }; done
  for surface in "${SURFACES[@]}"; do capture "$surface" "$OUT_DIR/base-$surface.png" || return 1; done
}

step_dark() { write_theme dark; expect_all base different dark; }
step_light() { write_theme light; expect_all base same light; }

run_steps step_baseline step_dark step_light
if [ "$STATUS" != 0 ]; then
  echo "--- daemon.log (tail)" >&2; tail -20 "$OUT_DIR/daemon.log" >&2
  echo "--- captures in the scratch dir: $OUT_DIR" >&2
fi
exit "$STATUS"
