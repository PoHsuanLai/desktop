#!/usr/bin/env bash
# Scenario `w2-excalidraw` (designer workflow W2): a person browses the lamp page, asks the assistant for the lamp's
# specs and a dimensioned front view drawn in a drawing app with a few helpers, and the drawing is saved.
#
# The drawing app is Excalidraw, built offline (workflow/fixtures/w2/build-excalidraw.sh): no GPU, no account, no
# network. It runs here, in the test jail on the headless test build of casement, because a dev-built shell is not
# trusted on a real login; in the jail the dev caller rows make sill and cuad trusted. Nobody presses a button: this
# script answers the confirmation sheets through sill's debug keys, and records every one in the report.
#
#   what runs:  casement (headless) + sill + the assistant's services + the screen helper (cuad) + Zen with two tabs
#               (the lamp page at /lamp/, the drawing app at /draw/, both served on loopback inside the jail)
#   the screen: the assistant drives the drawing app only through the screen (cuad). Nothing here calls the drawing app;
#               the saved file is read once, afterwards, to check it.
#
# Not part of the gate: it needs a screen model (the opt-in line below). Run it with workflow/w2-excalidraw.sh, which
# checks the models and builds, starts the jail with a run folder of its own and prints the report. Run directly it
# must already be inside the jail with the run folder as the jail's scratch dir:
#   harness/jail.sh --fabricate-gpus 2 --scratch RUN --env W2_PLANNER_SOCK=... --env W2_SCREEN_SOCK=... -- scenarios/w2-excalidraw.sh
#
# Models (there is no default; either one missing is refused plainly). The jail has no network, so a model is reached
# through a Unix socket on this computer that the jail bridges to a loopback port inside it:
#   W2_PLANNER_SOCK  (or W2_PLANNER_URL=unix:/path)   the assistant's own model
#   W2_SCREEN_SOCK   (or W2_SCREEN_URL=unix:/path)    the model that looks at the screen
# Optional: W2_PLANNER_MODEL (default qwen3-4b-instruct-2507-fp8), W2_SCREEN_MODEL (default holo4-35b-a3b-fp8),
# W2_PLANNER_SERVED / W2_SCREEN_SERVED, W2_BROWSER (default $JAIL_REAL_HOME/.local/opt/zen/zen), W2_BROWSER_APP
# (the window id, default app.zen_browser.zen), W2_DRAW_DIR (the offline build, default
# $JAIL_REAL_HOME/.cache/quire-workflow/excalidraw-0.18.0), W2_STOKER_CATALOG, W2_PROVIDERS, W2_SHOT_EVERY (seconds,
# default 120), W2_CUA_STEPS (default 300), W2_CUA_ACTIVE_S (default 1800), W2_AFTER_SAVE_S (how long to keep waiting for
# the turn to end after the drawing is saved, default 300).
#
#   scenarios/w2-excalidraw.sh [--timeout SECONDS] [--no-shots] [--print-build]
#
# opt-in: on demand only; desktop/gate/desktop-gate.sh does not run scenarios that carry this line
# budget: 3600
# Exit: 0 every checked criterion passed | 1 the run did not finish or a criterion failed (see report.md) |
#       2 outside the jail | 3 a model, a build or a program is missing | 64 bad usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../harness/lib/all.sh"
source "$HERE/../harness/lib/scenario.sh"
WF="$SCEN_ROOT/workflow"
PY1=(python3 -I "$WF/lib/w1.py")
PY2=(python3 -I "$WF/lib/w2.py")
TIMING=(python3 -I "$WF/lib/timing.py")
EXPECTED="$WF/fixtures/w1/expected.json"
LAMP_DIR="$WF/fixtures/w1"

TIMEOUT=3600 SHOTS=yes PRINT_BUILD=no
SHOT_EVERY=${W2_SHOT_EVERY:-120}
AFTER_SAVE_S=${W2_AFTER_SAVE_S:-300}
PLANNER_MODEL=${W2_PLANNER_MODEL:-qwen3-4b-instruct-2507-fp8}
SCREEN_MODEL=${W2_SCREEN_MODEL:-holo4-35b-a3b-fp8}
BROWSER_APP=${W2_BROWSER_APP:-app.zen_browser.zen}
PLANNER_PORT=18090 SCREEN_PORT=18091   # inside the jail's own network: nothing else listens there

usage() { sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "w2-excalidraw: $*" >&2; exit 3; }
say() { printf '\n== %s\n' "$*"; }
note() { printf '%s\n' "$*"; }

# print_build: the builds this scenario needs. They are the test builds the other scenarios use (scenario-build.sh),
# not the plain builds of the W1 rig: casement with its test features, sill with --features debug, cuad with the
# fixture caller table, and the assistant's services as docket-accept builds (fixture identities from a fake /proc).
print_build() {
  cat <<EOF
# W2 runs in the test jail, so it needs the TEST builds. Run this outside the jail, from $SCEN_ROOT (it nices itself):
harness/scenario-build.sh --w2
# which builds, one at a time, into $SCEN_BUILD:
# 1. casement with its test features (headless output, the test control), casementctl and fake-logind
(cd $SCEN_SIB/casement && CARGO_TARGET_DIR=$SCEN_BUILD/casement-target CASEMENT_TOOLS=$SCEN_BUILD/tools nice dev/bootstrap.sh --build-only)
# 2. private checkouts of the shell and its host library (the scenarios run sill's scripts from there)
#    sill (scenario-build.sh: checkouts) at $SCEN_SRC/sill
# 3. the shell with its test features (the stand-in screen-brightness file)
(cd $SCEN_SRC/sill && CARGO_TARGET_DIR=$SCEN_BUILD/sill-target nice cargo build -p sill --features debug)
# 4. the screen helper with the fixture caller table (a plain build identifies nobody)
(cd $SCEN_SIB/cua && CARGO_TARGET_DIR=$SCEN_BUILD/cua-target nice cargo build -p cuad --features fixture-callers)
# 5. the assistant's services, the bring-up tool and the terminal command (docket-accept: test builds)
(cd $SCEN_SIB/docket && CARGO_TARGET_DIR=$SCEN_BUILD/docket-target nice cargo build -p docket-accept --bins)
# and, once, the offline drawing app (needs node and npm; changes nothing outside its folder):
$WF/fixtures/w2/build-excalidraw.sh
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT=${2:-}; shift ;;
    --no-shots) SHOTS=no ;;
    --print-build) PRINT_BUILD=yes ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
  shift
done
case "$TIMEOUT" in ''|*[!0-9]*) echo "--timeout wants a whole number of seconds" >&2; exit 64 ;; esac
case "$SHOT_EVERY$AFTER_SAVE_S" in *[!0-9]*|'') echo "W2_SHOT_EVERY and W2_AFTER_SAVE_S want whole numbers of seconds" >&2; exit 64 ;; esac
if [ "$PRINT_BUILD" = yes ]; then print_build; exit 0; fi

require_jail

# ---- before anything starts: the models, the builds, the programs

# engine_socket NAME URL SOCK: the socket path for a model, from NAME_URL (unix:/path) or NAME_SOCK; refuses plainly.
engine_socket() {
  local what=$1 url=$2 sock=$3 var=$4
  if [ -z "$sock" ] && [ -n "$url" ]; then
    case "$url" in
      unix:/*) sock=${url#unix:} ;;
      *) note "The $what address ($url) cannot be reached from the test jail: the jail has no network."
         note "Bridge it to a socket on this computer first, for example:"
         note "  socat UNIX-LISTEN:\$HOME/w2-$var.sock,fork,mode=600 TCP:127.0.0.1:PORT &"
         note "and give unix:\$HOME/w2-$var.sock (or set the matching *_SOCK variable)."
         exit 3 ;;
    esac
  fi
  printf '%s' "$sock"
}

require_models() {
  local missing=0
  PLANNER_SOCK=$(engine_socket "assistant model" "${W2_PLANNER_URL:-}" "${W2_PLANNER_SOCK:-}" planner)
  SCREEN_SOCK=$(engine_socket "screen model" "${W2_SCREEN_URL:-}" "${W2_SCREEN_SOCK:-}" screen)
  if [ -z "$PLANNER_SOCK" ]; then
    note "No assistant model is chosen. Set W2_PLANNER_SOCK to a Unix socket on this computer that reaches the local model"
    note "(or W2_PLANNER_URL=unix:/path) and run again. There is no default."
    missing=1
  fi
  if [ -z "$SCREEN_SOCK" ]; then
    note "No screen model is chosen. Set W2_SCREEN_SOCK to a Unix socket on this computer that reaches the model that looks at"
    note "the screen (or W2_SCREEN_URL=unix:/path) and run again. There is no default."
    missing=1
  fi
  [ "$missing" = 0 ] || exit 3
  [ -S "$PLANNER_SOCK" ] || die "the assistant model's socket $PLANNER_SOCK does not exist (start the bridge to the local model first)"
  [ -S "$SCREEN_SOCK" ] || die "the screen model's socket $SCREEN_SOCK does not exist (open the tunnel and start the bridge first)"
}

DK="$SCEN_BUILD/docket-target/debug"
CUAD="$SCEN_BUILD/cua-target/debug/cuad"
BRINGUP="$DK/docket-bringup"
QUIREDO="$DK/accept-quire-do"
REAL_HOME=${JAIL_REAL_HOME:-$HOME}
BROWSER=${W2_BROWSER:-$REAL_HOME/.local/opt/zen/zen}
DRAW_DIR=${W2_DRAW_DIR:-$REAL_HOME/.cache/quire-workflow/excalidraw-0.18.0}

require_models
scenario_need "$SCEN_TOOLS/bin/casement" "$SCEN_TOOLS/bin/casementctl" "$SCEN_TOOLS/bin/fake-logind" \
  "$SCEN_BUILD/sill-target/debug/sill" "$CUAD" "$BRINGUP" "$QUIREDO" "$DK/accept-intentd" "$DK/accept-companiond" "$DK/accept-readerd"
[ -x "$BROWSER" ] || die "the browser $BROWSER is not there (set W2_BROWSER to Zen's program)"
[ -s "$DRAW_DIR/main.js" ] || die "the drawing app is not built at $DRAW_DIR: run $WF/fixtures/w2/build-excalidraw.sh outside the jail"
for tool in socat curl python3 busctl gdbus; do command -v "$tool" >/dev/null || die "$tool is missing"; done

export SILL_COMPOSITOR=casement SILL_PREBUILT=1 SILL_PROFILE=debug
export CARGO_TARGET_DIR="$SCEN_BUILD/sill-target" CASEMENT_TOOLS="$SCEN_TOOLS"
# casement asks before a program watches the screen, types or lists windows, and nobody answers inside a scenario, so
# the floor allows exactly the programs this run starts that take those powers: cuad and casementctl (the pictures).
floor_shim w2-excalidraw sill cuad casementctl || die "could not write the permission floor"
# shellcheck source=/dev/null
source "$SCEN_SRC/sill/dev/lib/all.sh"
OUT_DIR=$(scenario_out w2-excalidraw)
RUN=$OUT_DIR
OUT=$RUN/out
AGENTS="" SILL_PID="" ASK_PID="" ANSWERER_PID="" MONITOR_PID="" SHOT_N=0 SENTENCE=""
STARTED=()   # "name pid"

stamp() { printf '%s\t%s\t%s\n' "$1" "$("${TIMING[@]}" now)" "$(date +%s)" >>"$RUN/stamps.tsv"; }
record() { STARTED+=("$1 $2"); }

end_pid() { # PID: TERM, then KILL after 5 s
  local pid=$1 waited=0
  kill -0 "$pid" 2>/dev/null || return 0
  kill -TERM "$pid" 2>/dev/null
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  return 0
}

cleanup() {
  trap - EXIT INT TERM
  touch "$RUN/.stop" 2>/dev/null
  local i name pid
  [ -z "$ANSWERER_PID" ] || end_pid "$ANSWERER_PID"
  [ -z "$AGENTS" ] || "$BRINGUP" down --root "$AGENTS" >>"$RUN/bringup.log" 2>&1
  for ((i = ${#STARTED[@]} - 1; i >= 0; i--)); do
    read -r name pid <<<"${STARTED[$i]}"
    end_pid "$pid"
  done
  [ -z "$MONITOR_PID" ] || end_pid "$MONITOR_PID"
  stop_daemon
  stop_compositor
  scratch_drop
}
trap cleanup EXIT
trap 'echo; echo "Stopping."; exit 130' INT TERM

# wait_for TENTHS CMD...: up to TENTHS tenths of a second for CMD to succeed and print something; prints it.
wait_for() {
  local tenths=$1 out; shift
  for _ in $(seq "$tenths"); do
    out=$("$@" 2>/dev/null) && [ -n "$out" ] && { echo "$out"; return 0; }
    sleep 0.1
  done
  return 1
}

snap() { # NAME: a picture of the desktop, from casement's own capture
  [ "$SHOTS" = yes ] || return 0
  SHOT_N=$((SHOT_N + 1))
  shot "$RUN/shots/$(printf '%02d' "$SHOT_N")-$1.png" >/dev/null 2>&1 || true
}

# ---- the models, bridged into the jail

bridge() { # PORT SOCKET: a loopback port inside the jail that reaches a socket on this computer
  socat "TCP-LISTEN:$1,bind=127.0.0.1,reuseaddr,fork" "UNIX-CONNECT:$2" >>"$RUN/bridge.log" 2>&1 </dev/null &
  record bridge $!
}

# check_model WHAT PORT MODEL WANT VAR: the server answers, lists the model; sets VAR to the served name.
check_model() {
  local what=$1 port=$2 model=$3 want=$4 var=$5 answer names
  answer=""
  for _ in $(seq 40); do
    answer=$(curl -fsS --max-time 8 "http://127.0.0.1:$port/v1/models" 2>/dev/null) && break
    sleep 0.25
  done
  [ -n "$answer" ] || { note "The $what does not answer through its socket. Start it (and its tunnel or bridge), then run again."; return 3; }
  names=$("${PY1[@]}" served <<<"$answer") || { note "The $what lists no models."; return 3; }
  if [ -n "$want" ]; then
    grep -qxF -- "$want" <<<"$names" || { note "The $what does not list $want. It lists: $(tr '\n' ' ' <<<"$names")"; return 3; }
    printf -v "$var" '%s' "$want"
  elif grep -qxF -- "$model" <<<"$names"; then printf -v "$var" '%s' "$model"
  elif [ "$(wc -l <<<"$names")" = 1 ]; then printf -v "$var" '%s' "$names"
  else note "The $what lists several models and none is $model: $(tr '\n' ' ' <<<"$names"). Say which with W2_*_SERVED."; return 3; fi
}

PLANNER_SERVED="" SCREEN_SERVED=""
prepare_models() {
  local catalog=$RUN/catalog src=${W2_STOKER_CATALOG:-$SCEN_SIB/stoker/catalog}
  [ -d "$src" ] || { note "No model catalogue at $src (set W2_STOKER_CATALOG)."; return 3; }
  mkdir -p "$catalog" "$AGENTS/config/inferd"
  cp "$src"/*.toml "$catalog/"
  [ -f "$catalog/$PLANNER_MODEL.toml" ] || { note "The catalogue has no entry for $PLANNER_MODEL."; return 3; }
  [ -f "$catalog/$SCREEN_MODEL.toml" ] || { note "The catalogue has no entry for $SCREEN_MODEL."; return 3; }
  "${PY1[@]}" catalog --src "$src/$PLANNER_MODEL.toml" --out "$catalog/$PLANNER_MODEL.toml" --served "$PLANNER_SERVED" --tool-parser hermes || return 3
  "${PY1[@]}" catalog --src "$src/$SCREEN_MODEL.toml" --out "$catalog/$SCREEN_MODEL.toml" --served "$SCREEN_SERVED" \
    --tool-parser qwen3_coder --reasoning-parser qwen3 || return 3
  "${PY1[@]}" inferd-config --planner-id "$PLANNER_MODEL" --planner-url "http://127.0.0.1:$PLANNER_PORT" \
    --screen-id "$SCREEN_MODEL" --screen-url "http://127.0.0.1:$SCREEN_PORT" >"$AGENTS/config/inferd/inferd.toml" || return 3
  mkdir -p "$CONFIG/cua"
  # The browser is allowed outright: nobody is here to answer, and the jail is the boundary.
  "${PY1[@]}" cuad-settings --app "$BROWSER_APP=ask" --steps "${W2_CUA_STEPS:-300}" --active-s "${W2_CUA_ACTIVE_S:-1800}" \
    >"$CONFIG/cua/settings.toml"
}

# ---- the bus record and the sheets nobody is here to press

monitor_start() {
  busctl --address="$BUS" monitor --json=short >"$RUN/bus.jsonl" 2>"$RUN/bus-monitor.err" &
  MONITOR_PID=$!
}

# intents_field NAME: one field of `sill intents status` (showing: the id of the sheet on screen, empty when none).
intents_field() {
  sill intents status 2>/dev/null | python3 -I -c '
import json, sys
r = json.loads(sys.stdin.read())["v"]["v"]
v = r[sys.argv[1]]
print(" ".join(v) if isinstance(v, list) else ("" if v is None else v))' "$1"
}
sheet_key() { sill debug key "$SHEET" "$@" >>"$RUN/keys.log" 2>&1; }

# answer_sheets: in the background until $RUN/.stop. Every sheet that shows is answered "Allow once" (for the brief sheet,
# "Use this brief": the sheet sends the field's words back as its answer, which is what confirms it) once it is armed, and
# written to sheets.tsv: time, id, kind, what it asked, the answer, the keys sent, the result.
answer_sheets() {
  local last="" id info kind gesture app action keys answer result tries got
  while [ ! -e "$RUN/.stop" ]; do
    id=$(intents_field showing)
    if [ -z "$id" ] || [ "$id" = "$last" ]; then sleep 0.5; continue; fi
    info=""
    for _ in 1 2 3 4 5 6; do
      info=$("${PY2[@]}" sheet-info --bus "$RUN/bus.jsonl" --id "$id") && break
      info=""; sleep 0.5
    done
    [ -n "$info" ] || info=$(printf 'step\tpress\tunknown\tnot in the bus record')
    IFS=$'\t' read -r kind gesture app action <<<"$info"
    sleep 2   # a sheet that has just appeared answers nothing until it has been still for a moment (sill's own script waits 1 s)
    tries=0 keys="" got=""
    # Answered only when the bus carries the sheet's reply; keys are sent again, 3 s apart, until it does.
    while [ ! -e "$RUN/.stop" ]; do
      got=$("${PY2[@]}" sheet-answer --bus "$RUN/bus.jsonl" --id "$id") && break
      [ "$tries" -lt 6 ] || break
      case "$gesture" in
        hold_to_confirm)
          [ "$tries" -gt 0 ] || { sheet_key Tab; keys="Tab, "; }
          sheet_key Space --action press; sleep 1.7; sheet_key Space --action release
          keys="${keys%%Space*}Space held 1.7 s" ;;
        *) sheet_key Enter; keys="Enter" ;;
      esac
      tries=$((tries + 1)); sleep 3
    done
    if [ -n "$got" ]; then result="answered ($got, after $tries sending(s))"
      case "$kind" in brief) answer="Use this brief (Allow once)" ;; *) answer="Allow once" ;; esac
    else result="not answered (no reply on the bus after $tries tries)"; answer="none"; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$id" "$kind" "$app: $action" "$answer" "$keys" "$result" >>"$RUN/sheets.tsv"
    last=$id
  done
}

# ---- the steps

in_app_env() { # CMD...: in the desktop's environment, with the compositor's own runtime folder (cuad and the browser want it)
  in_env env XDG_RUNTIME_DIR="$(dirname "$WL")" "$@"
}

step_boot() {
  mkdir -p "$OUT" "$RUN/shots"
  : >"$RUN/stamps.tsv"
  stamp start
  touch "$RUN/.start"
  start_compositor || return 1
  scratch_new
  AGENTS=$SCRATCH/agents
  mkdir -p "$AGENTS"
  build || return 1
  monitor_start
  stamp casement_up
  # sill takes the floor's caller rows as the person's own (peephole's Proof::Dev) and, with them, the assistant's router.
  { cat "$FLOOR_DIR/desktop-callers.toml"
    printf '\n[[peer]]\napp = "org.quire.Intents"\nrole = "router"\nexe = ["%s"]\n' "$(readlink -f "$DK/accept-intentd")"
  } >"$RUN/dev-callers.toml"
  chmod 600 "$RUN/dev-callers.toml"
  DEV_CALLERS_FLAGS=(--dev-callers "$RUN/dev-callers.toml")
  launch_daemon || return 1
  SILL_PID=$DAEMON
  NAME=$(output_name) || return 1
  SHEET="sill-confirm-$NAME"
  note "The desktop and the shell are up."
}

step_models() {
  bridge "$PLANNER_PORT" "$PLANNER_SOCK"
  bridge "$SCREEN_PORT" "$SCREEN_SOCK"
  check_model "assistant model" "$PLANNER_PORT" "$PLANNER_MODEL" "${W2_PLANNER_SERVED:-}" PLANNER_SERVED || return 3
  check_model "screen model" "$SCREEN_PORT" "$SCREEN_MODEL" "${W2_SCREEN_SERVED:-}" SCREEN_SERVED || return 3
  prepare_models
}

step_stack() {
  local providers=${W2_PROVIDERS:-$SCEN_SIB/porter/providers} extra=()
  [ ! -d "$providers" ] || extra+=(--providers "$providers")
  # The screen helper's action, installed where the router reads apps' actions (as cua's installer does under
  # <prefix>/share/quire/intents): without it the assistant has no way to use an app on the screen.
  mkdir -p "$AGENTS/data/quire/intents"
  cp "$SCEN_SIB/cua/manifests/org.quire.Cua.toml" "$AGENTS/data/quire/intents/" || return 1
  env -u DBUS_SESSION_BUS_ADDRESS -u DBUS_SYSTEM_BUS_ADDRESS "$BRINGUP" up --bus "$BUS" --root "$AGENTS" \
    --shell-pid "$SILL_PID" --catalog "$RUN/catalog" "${extra[@]}" >"$RUN/bringup.log" 2>&1 \
    || { tail -8 "$RUN/bringup.log" >&2; return 1; }
  restart_companion_with_log || return 1
  start_reader || return 1
  start_screen_helper || return 1
  stamp stack_up
  note "The assistant's services and the screen helper are up."
  answer_sheets >>"$RUN/answerer.log" 2>&1 &
  ANSWERER_PID=$!
}

proc_token() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20; }

# The assistant is started again with its model log on (the log path is its only change). As in the W1 rig.
restart_companion_with_log() {
  local line pid envfile=$RUN/companiond.env exe waited=0 new
  line=$(awk '$1 == "companiond" {print}' "$AGENTS/procs") pid=$(awk '{print $2}' <<<"$line")
  [ -n "$pid" ] || { echo "the assistant's service is not running" >&2; return 1; }
  tr '\0' '\n' <"/proc/$pid/environ" | grep -v '^$' >"$envfile"
  exe=$(readlink "/proc/$pid/exe")
  kill "$pid"
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
  local -a E
  mapfile -t E <"$envfile"
  setsid env -i "${E[@]}" DOCKET_MODEL_TRACE="$RUN/trace.jsonl" /bin/bash -c '
    mkdir -p "$1/proc/$$" "$1/proc/units"
    printf "0::/user.slice/user-1000.slice/user@1000.service/app.slice/%s.service\n" "$2" > "$1/proc/$$/cgroup"
    echo $$ > "$1/proc/units/$2.service"
    shift 2; exec "$@"' _ "$AGENTS" companiond "$exe" >>"$AGENTS/logs/companiond.log" 2>&1 </dev/null &
  new=$!
  waited=0
  until bus_has_owner org.quire.Companion1; do
    kill -0 "$new" 2>/dev/null && [ "$waited" -lt 300 ] || { echo "the assistant did not come back with its log on" >&2; return 1; }
    sleep 0.1; waited=$((waited + 1))
  done
  { grep -v '^companiond ' "$AGENTS/procs"; echo "companiond $new $(proc_token "$new")"; } >"$AGENTS/procs.new" && mv "$AGENTS/procs.new" "$AGENTS/procs"
}

# The reader (it reads pages for the assistant) is not one of the bring-up's daemons: started here as its own unit in the fake
# /proc, with the companion's environment and its own two seam variables, and recorded in the procs file so `down` ends it.
start_reader() {
  local -a E
  local new waited=0
  mapfile -t E < <(grep -v '^COMPANIOND_' "$RUN/companiond.env")
  setsid env -i "${E[@]}" READERD_PROC_ROOT="$AGENTS/proc" READERD_SYSTEM_CALLERS="$AGENTS/system/readerd-callers.toml" /bin/bash -c '
    mkdir -p "$1/proc/$$" "$1/proc/units"
    printf "0::/user.slice/user-1000.slice/user@1000.service/app.slice/%s.service\n" "$2" > "$1/proc/$$/cgroup"
    echo $$ > "$1/proc/units/$2.service"
    shift 2; exec "$@"' _ "$AGENTS" readerd "$DK/accept-readerd" >>"$AGENTS/logs/readerd.log" 2>&1 </dev/null &
  new=$!
  until bus_has_owner org.quire.Reader1; do
    kill -0 "$new" 2>/dev/null && [ "$waited" -lt 300 ] || { tail -5 "$AGENTS/logs/readerd.log" >&2; echo "the reader did not start" >&2; return 1; }
    sleep 0.1; waited=$((waited + 1))
  done
  echo "readerd $new $(proc_token "$new")" >>"$AGENTS/procs"
}

bus_has_owner() {
  gdbus call --address "$BUS" --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.NameHasOwner "$1" 2>/dev/null | grep -q true
}

start_screen_helper() {
  cat >"$RUN/cuad-callers.toml" <<'EOF'
[[caller]]
app = "org.quire.Intents"
unit = "intentd.service"
role = "agent"

[[caller]]
app = "org.quire.Companion1"
unit = "companiond.service"
role = "agent"

[[caller]]
app = "org.quire.Shell"
unit = "sill.service"
role = "sheet_host"
EOF
  in_app_env bash -c 'mkdir -p "$1/proc/$$" "$1/proc/units"; printf "0::/user.slice/user-1000.slice/user@1000.service/app.slice/cuad.service\n" > "$1/proc/$$/cgroup"; echo $$ > "$1/proc/units/cuad.service"; exec env CUAD_TEST_PROC_ROOT="$1/proc" CUAD_TEST_SYSTEM_CALLERS="$2" "$3"' \
    _ "$AGENTS" "$RUN/cuad-callers.toml" "$CUAD" >"$RUN/cuad.log" 2>&1 </dev/null &
  local pid=$!
  record cuad "$pid"
  sleep 2
  # What the screen helper reads to tell who is calling: the fake /proc's processes and units, kept for the report.
  { find "$AGENTS/proc" -maxdepth 2 | sed "s|$AGENTS/||" | sort
    for u in "$AGENTS"/proc/units/*; do printf '%s %s\n' "${u##*/}" "$(cat "$u")"; done
    for c in "$AGENTS"/proc/[0-9]*/cgroup; do printf '%s %s\n' "$c" "$(cat "$c")"; done | sed "s|$AGENTS/||"
  } >"$RUN/proc-tree.txt" 2>&1
  kill -0 "$pid" 2>/dev/null || { tail -5 "$RUN/cuad.log" >&2; echo "the screen helper did not start (see $RUN/cuad.log)" >&2; return 1; }
}

LAMP_URL="" DRAW_URL=""
step_pages() {
  "${PY1[@]}" serve --mount "/lamp/=$LAMP_DIR" --mount "/draw/=$DRAW_DIR" --mount "/fonts/=$DRAW_DIR/fonts" \
    --port-file "$RUN/port" >/dev/null 2>&1 </dev/null &
  record pages $!
  for _ in $(seq 50); do [ -s "$RUN/port" ] && break; sleep 0.1; done
  [ -s "$RUN/port" ] || { echo "the pages could not be served" >&2; return 1; }
  LAMP_URL="http://127.0.0.1:$(cat "$RUN/port")/lamp/"
  DRAW_URL="http://127.0.0.1:$(cat "$RUN/port")/draw/"
  curl -fsS --max-time 5 -o /dev/null "$LAMP_URL" && curl -fsS --max-time 5 -o /dev/null "${DRAW_URL}main.js" \
    || { echo "the served pages do not answer" >&2; return 1; }
  local profile=$RUN/browser-profile before
  mkdir -p "$profile"
  "${PY2[@]}" browser-prefs --download-dir "$OUT" --homepage "$LAMP_URL|$DRAW_URL" >"$profile/user.js" || return 1
  before=$("${TIMING[@]}" now)
  # Zen needs MOZ_LEGACY_PROFILES (its launcher sets it). The browser's own content sandbox cannot nest inside the jail's
  # and the jail is the boundary here, so it is off; no GPU, so pictures are drawn by software.
  in_app_env env MOZ_LEGACY_PROFILES=1 MOZ_ENABLE_WAYLAND=1 MOZ_DISABLE_CONTENT_SANDBOX=1 MOZ_DISABLE_GMP_SANDBOX=1 \
    MOZ_DISABLE_RDD_SANDBOX=1 MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1 LIBGL_ALWAYS_SOFTWARE=1 \
    "$BROWSER" --profile "$profile" --no-remote --name "$BROWSER_APP" "$LAMP_URL" "$DRAW_URL" \
    >"$RUN/browser.log" 2>&1 </dev/null &
  record browser $!
  if "${TIMING[@]}" wait --log-file "$(dirname "$CASEMENT_ENV")/casement.log" \
       --app-ids "$BROWSER_APP,zen,zen-browser,app.zen_browser.zen" --after-connected "$before" --timeout 120 >/dev/null 2>&1; then
    stamp page_open
  else
    note "(The browser's window was not seen in the timing lines; carrying on.)"
  fi
  sleep 5
  # A person reading the page has clicked into it, which makes the browser the active app (casement keys a newly
  # mapped window only when its app is already active). The click lands in the page's right margin, clear of the
  # centred text, the browser's left sidebar and the notification column.
  casementctl debug inject "move $(( ${SIZE%x*} * 3 / 4 )) $(( ${SIZE#*x} / 2 ))" "sleep 60" "press left" "sleep 40" \
    "release left" >>"$RUN/input.log" 2>&1 || note "(The click into the page was refused; see input.log.)"
  sleep 1
  snap pages-open
}

post_turn() {
  local fifo=$RUN/go pid
  mkfifo "$fifo"
  exec 9<>"$fifo"
  in_env env -u WAYLAND_DISPLAY sh -c 'read _; exec "$@" </dev/null' _ "$QUIREDO" ask "$SENTENCE" \
    <&9 >"$RUN/turn.txt" 2>"$RUN/turn.err" &
  ASK_PID=$!
  pid=$ASK_PID
  mkdir -p "$AGENTS/proc/$pid" "$AGENTS/proc/units"
  printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/vte-spawn-1.scope\n' >"$AGENTS/proc/$pid/cgroup"
  ln -sf /usr/bin/vte-spawn-1 "$AGENTS/proc/$pid/exe"
  echo >&9
  exec 9>&-
  record ask "$pid"
}

window_seen() { # IDS AFTER_NS
  "${TIMING[@]}" wait --log-file "$(dirname "$CASEMENT_ENV")/casement.log" --app-ids "$1" --after-connected "${2:-0}" --timeout 0 >/dev/null 2>&1
}

ASKED_NS=0 ASKED_EPOCH=0
step_ask_and_wait() {
  SENTENCE=$("${PY2[@]}" sentence)
  note "The assistant is asked: $SENTENCE"
  ASKED_NS=$("${TIMING[@]}" now) ASKED_EPOCH=$(date +%s)
  stamp asked
  post_turn
  local audit=$AGENTS/.local/state/quire/inferd/audit.jsonl
  local deadline=$((SECONDS + TIMEOUT)) next_shot=$((SECONDS + SHOT_EVERY)) saved_at="" rc
  local turn_seen=no screen_seen=no svg_seen=no drawing_seen=no ask_state=none last_sheets=0 f s size prev=-1 stable=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    f=$(ls -t "$OUT"/*.excalidraw 2>/dev/null | head -1)
    if [ -n "$f" ]; then
      size=$(stat -c %s "$f" 2>/dev/null || echo 0)
      if [ "$size" = "$prev" ] && [ "$size" -gt 0 ]; then stable=$((stable + 1)); else stable=0; fi
      prev=$size
      if [ "$drawing_seen" = no ] && [ "$stable" -ge 2 ]; then
        drawing_seen=yes; saved_at=$SECONDS; stamp drawing_saved; snap drawing-saved; note "A drawing is saved: $f"
      fi
    fi
    s=$(ls -t "$OUT"/*.svg 2>/dev/null | head -1)
    if [ "$svg_seen" = no ] && [ -n "$s" ] && [ -s "$s" ]; then svg_seen=yes; stamp svg_saved; note "A picture is saved: $s"; fi
    if [ "$turn_seen" = no ] && "${PY1[@]}" first-turn --audit "$audit" --since "$ASKED_EPOCH" >/dev/null; then
      turn_seen=yes; stamp first_turn; note "The assistant has started thinking."
    fi
    if [ "$screen_seen" = no ] && "${PY1[@]}" first-screen --audit "$audit" --since "$ASKED_EPOCH" >/dev/null; then
      screen_seen=yes; stamp first_screen_step; snap first-screen-step; note "The screen helper has started looking at the window."
    fi
    if [ -s "$RUN/sheets.tsv" ] && [ "$(wc -l <"$RUN/sheets.tsv")" -gt "$last_sheets" ]; then
      last_sheets=$(wc -l <"$RUN/sheets.tsv"); snap "sheet-$last_sheets"; note "A sheet was answered ($last_sheets so far)."
    fi
    if [ "$ask_state" = none ] && ! kill -0 "$ASK_PID" 2>/dev/null; then
      wait "$ASK_PID" 2>/dev/null; rc=$?
      ask_state=ended
      case "$rc" in
        0) note "The assistant has finished its turn." ;;
        8) note "The assistant is waiting for an answer that nobody here can give (code 8)." ;;
        *) note "The request ended (code $rc): $(tail -1 "$RUN/turn.err" 2>/dev/null)" ;;
      esac
      [ "$drawing_seen" = yes ] && break
      deadline=$((SECONDS + 60))
    fi
    # The turn is still going but the drawing has been saved for a while: stop waiting.
    if [ -n "$saved_at" ] && [ $((SECONDS - saved_at)) -ge "$AFTER_SAVE_S" ]; then note "The drawing has been saved for ${AFTER_SAVE_S} s; stopping."; break; fi
    [ "$SECONDS" -lt "$next_shot" ] || { snap progress; next_shot=$((SECONDS + SHOT_EVERY)); }
    sleep 2
  done
  [ -z "$f" ] || [ "$drawing_seen" = yes ] || { stamp drawing_saved; }
  [ "$drawing_seen" = yes ] || note "No drawing was saved within the time."
  return 0
}

step_report() {
  stamp finished
  snap end
  # The model log's audit and the services' logs, where the report looks for them.
  mkdir -p "$RUN/agents/.local/state/quire/inferd"
  cp "$AGENTS/.local/state/quire/inferd/audit.jsonl" "$RUN/agents/.local/state/quire/inferd/audit.jsonl" 2>/dev/null || true
  [ ! -d "$AGENTS/logs" ] || cp -r "$AGENTS/logs" "$RUN/agent-logs" 2>/dev/null || true
  (cd "$RUN" && find out "${HOME_DIR#"$RUN"/}" -type f -newer .start \( -name '*.excalidraw' -o -name '*.svg' -o -name '*.png' -o -name '*.json' \) \
     -not -path '*/.config/*' -not -path '*/.cache/*' 2>/dev/null | sort) >"$RUN/files-made.txt" 2>/dev/null || true
  say "Report"
  "${PY2[@]}" report --run "$RUN" --expected "$EXPECTED"
  local rc=$?
  note ""
  note "The report is $RUN/report.md"
  REPORT_RC=$rc
  return 0
}

REPORT_RC=1
HALT=0
guard() { # STEP: run it unless an earlier one stopped the run
  if [ "$HALT" != 0 ]; then return 2; fi
  "$1" || { HALT=$?; [ "$HALT" != 0 ] || HALT=1; return 1; }
}
s_boot() { guard step_boot; }
s_models() { guard step_models; }
s_stack() { guard step_stack; }
s_pages() { guard step_pages; }
s_ask() { guard step_ask_and_wait; }

run_steps s_boot s_models s_stack s_pages s_ask step_report
if [ "$HALT" != 0 ]; then
  echo "--- daemon.log (tail)" >&2; tail -20 "$RUN/daemon.log" >&2 2>/dev/null
  echo "--- casement-up.log (tail)" >&2; tail -20 "$RUN/casement-up.log" >&2 2>/dev/null
  [ "$HALT" = 3 ] && exit 3
  exit 1
fi
exit "$REPORT_RC"
