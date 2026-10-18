#!/usr/bin/env bash
# Workflow W2: a person browses the lamp page, asks the assistant for the specs and a dimensioned front view drawn in a
# drawing app with a few helpers, and the drawing is saved. Unlike W1 this runs in the test jail, on the desktop's
# headless test build, because a nested window on your real login cannot trust a dev-built shell. Nobody presses buttons:
# the confirmation sheets are answered for you and each one is written in the report. On demand only: not the gate.
#
#   workflow/w2-excalidraw.sh [--run-dir DIR] [--timeout SECONDS] [--no-shots]
#   workflow/w2-excalidraw.sh --print-build
#
#   --run-dir      where this run keeps everything (default ~/.cache/w2-runs/<date-time>); the saved drawing goes in
#                  <run dir>/scenario/w2-excalidraw/out and the report is <run dir>/report.md
#   --timeout      give up waiting for the drawing after this many seconds (default 3600)
#   --no-shots     take no pictures of the desktop while it runs
#   --print-build  print the test builds this needs and stop
#
# There is no default model. Set both, or the script says which is missing and stops. The test jail has no network, so a
# model is reached through a Unix socket on this computer (a bridge you start; for the model on fatcat, open the tunnel
# first and bridge its port, only when you are ready, and stop both after):
#   W2_PLANNER_SOCK  the assistant's own model, e.g. a socket from: socat UNIX-LISTEN:$HOME/w2-planner.sock,fork,mode=600 TCP:127.0.0.1:8090
#   W2_SCREEN_SOCK   the model that looks at the screen, the same way
# (W2_PLANNER_URL=unix:/path and W2_SCREEN_URL=unix:/path mean the same.) Optional: see the header of
# scenarios/w2-excalidraw.sh (W2_BROWSER, W2_DRAW_DIR, W2_PLANNER_MODEL, W2_SCREEN_MODEL, W2_SHOT_EVERY ...).
#
# Needs the test builds (--print-build), the offline drawing app (workflow/fixtures/w2/build-excalidraw.sh), Zen, and the
# test jail's own needs (bubblewrap, /dev/udmabuf). It never installs anything and never starts a model.
#
# Exit: 0 every checked criterion passed, 1 the run did not finish or a criterion failed (see report.md),
# 2 bad usage, a missing model, or run from inside the jail, 3 a build or program is missing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCENARIO="$ROOT/scenarios/w2-excalidraw.sh"

RUN="" TIMEOUT=3600 SHOTS=yes
usage() { sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "w2-excalidraw.sh: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir) RUN=${2:?}; shift ;;
    --timeout) TIMEOUT=${2:?}; shift ;;
    --no-shots) SHOTS=no ;;
    --print-build) exec "$SCENARIO" --print-build ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout wants a whole number of seconds" ;; esac
[ -z "${JAIL_SCRATCH:-}" ] || die "this starts the test jail itself; run it on your real login, not inside the jail"

planner=${W2_PLANNER_SOCK:-${W2_PLANNER_URL:-}} screen=${W2_SCREEN_SOCK:-${W2_SCREEN_URL:-}}
missing=0
if [ -z "$planner" ]; then
  echo "No assistant model is chosen. Set W2_PLANNER_SOCK to a Unix socket on this computer that reaches the local model"
  echo "and run again. There is no default."; missing=1
fi
if [ -z "$screen" ]; then
  echo "No screen model is chosen. Set W2_SCREEN_SOCK to a Unix socket on this computer that reaches the model that looks at"
  echo "the screen (for the one on fatcat: open the tunnel, then bridge its port to a socket) and run again. There is no default."; missing=1
fi
[ "$missing" = 0 ] || exit 2
for s in "${W2_PLANNER_SOCK:-}" "${W2_SCREEN_SOCK:-}"; do
  [ -z "$s" ] || [ -S "$s" ] || die "$s is not a socket: start the bridge first"
done

[ -n "$RUN" ] || RUN="${XDG_CACHE_HOME:-$HOME/.cache}/w2-runs/$(date +%Y%m%d-%H%M%S)"
case "$RUN" in /*) ;; *) RUN="$PWD/$RUN" ;; esac
[ ! -e "$RUN/scenario" ] || die "$RUN already holds a run; pick another folder"
mkdir -p "$RUN" || die "cannot make $RUN"

# The jail clears its environment: hand it the W2_ variables, with the host's own paths for Zen and the drawing app.
envs=(--env "W2_BROWSER=${W2_BROWSER:-$HOME/.local/opt/zen/zen}"
      --env "W2_DRAW_DIR=${W2_DRAW_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/quire-workflow/excalidraw-0.18.0}")
for name in $(compgen -e | grep '^W2_' | grep -vx 'W2_BROWSER\|W2_DRAW_DIR'); do
  envs+=(--env "$name=${!name}")
done
args=(--timeout "$TIMEOUT")
[ "$SHOTS" = yes ] || args+=(--no-shots)

echo "This run keeps everything in $RUN"
"$ROOT/harness/jail.sh" --fabricate-gpus 2 --scratch "$RUN" "${envs[@]}" -- "$SCENARIO" "${args[@]}"
rc=$?
report=$RUN/scenario/w2-excalidraw/report.md
if [ -f "$report" ]; then ln -sfn "scenario/w2-excalidraw/report.md" "$RUN/report.md"; echo "The report is $RUN/report.md"; fi
exit "$rc"
