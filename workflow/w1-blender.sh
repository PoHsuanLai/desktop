#!/usr/bin/env bash
# Workflow W1: a person browses a product page, opens the launcher, asks the assistant for the specs of the
# thing on the page, and the assistant opens Blender, has several helpers model it, and saves a .glb.
# This is the rig: a window of our desktop inside yours, the assistant's services on a private bus of their own,
# a made-up product page on this computer, and a report of how it went. On demand only, on your real login:
# not the gate, not CI, not the jail.
#
#   workflow/w1-blender.sh [--drive] [--run-dir DIR] [--timeout SECONDS] [--no-shots] [--floor-dir DIR]
#   workflow/w1-blender.sh --print-build
#
#   --drive        say the request to the assistant ourselves (after you press Enter) instead of waiting for you to
#                  type it in the launcher
#   --run-dir      where this run keeps everything (default ~/.cache/w1-runs/<date-time>); the saved .glb goes in
#                  its out/ folder and the report is report.md
#   --timeout      give up waiting for the file after this many seconds (default 3600)
#   --no-shots     take no pictures of the window while it runs
#   --floor-dir    a permission folder that only the administrator can change (root-owned), handed to the desktop
#                  window so it asks fewer questions; without it the window asks you the first time each program
#                  connects. A proposed one is written to <run dir>/floor for you to copy
#   --print-build  print the build commands this rig needs and stop
#
# There is no default model. Set both, or the script says which is missing and stops:
#   W1_PLANNER_URL   the assistant's own model, as an address on this computer (http://127.0.0.1:8090)
#   W1_SCREEN_URL    the model that looks at the screen, the same way (a tunnel to the one on fatcat)
# The script never starts a model. Start the screen model on fatcat yourself, only when you are ready, and stop it after.
# Optional: W1_PLANNER_MODEL (default qwen3-4b-instruct-2507-fp8), W1_SCREEN_MODEL (default holo4-35b-a3b-fp8),
# W1_PLANNER_SERVED / W1_SCREEN_SERVED (the name the server lists), W1_TARGET_CASEMENT / _SILL / _CUA / _DOCKET
# (build folders, default /mnt/data/cargo/w1-*), W1_CASEMENT, W1_FAKE_LOGIND, W1_SILL, W1_CUAD, W1_BRINGUP,
# W1_QUIRE_DO (a program by path), W1_BROWSER_CMD, W1_SIB (the folder holding casement, sill, ...),
# W1_STOKER_CATALOG, W1_PROVIDERS, W1_SHOT_EVERY (seconds, default 120).
#
# Needs Blender, a browser (Zen, else Firefox), grim (optional, for pictures), python3 3.11+, curl, dbus-daemon and gdbus.
# It never installs anything: a missing program is named with the command that would install it. Everything it
# starts is stopped again, by process number, when it ends or you press Ctrl-C. See workflow/README.md.
#
# Exit: 0 every checked criterion passed, 1 the run did not finish or a criterion failed (see report.md),
# 2 bad usage, a missing program or model, or not a Wayland desktop.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY=(python3 -I "$HERE/lib/w1.py")
TIMING=(python3 -I "$HERE/lib/timing.py")
SIB=${W1_SIB:-$(cd "$HERE/../.." && pwd)}

DRIVE=no RUN="" TIMEOUT=3600 SHOTS=yes PRINT_BUILD=no FLOOR_DIR_GIVEN=""
SHOT_EVERY=${W1_SHOT_EVERY:-120}
PLANNER_MODEL=${W1_PLANNER_MODEL:-qwen3-4b-instruct-2507-fp8}
SCREEN_MODEL=${W1_SCREEN_MODEL:-holo4-35b-a3b-fp8}

T_CASEMENT=${W1_TARGET_CASEMENT:-/mnt/data/cargo/w1-casement}
T_TOOLS=${W1_TARGET_CASEMENT_TOOLS:-/mnt/data/cargo/w1-casement-tools}
T_SILL=${W1_TARGET_SILL:-/mnt/data/cargo/w1-sill}
T_CUA=${W1_TARGET_CUA:-/mnt/data/cargo/w1-cua}
T_DOCKET=${W1_TARGET_DOCKET:-/mnt/data/cargo/w1-docket}
CASEMENT=${W1_CASEMENT:-$T_CASEMENT/debug/casement}
FAKE_LOGIND=${W1_FAKE_LOGIND:-$T_TOOLS/debug/fake-logind}
SILL=${W1_SILL:-$T_SILL/debug/sill}
CUAD=${W1_CUAD:-$T_CUA/debug/cuad}
BRINGUP=${W1_BRINGUP:-$T_DOCKET/debug/docket-bringup}
QUIREDO=${W1_QUIRE_DO:-$T_DOCKET/debug/accept-quire-do}

STARTED=()           # "name pid start-token", in start order
BUS="" RT="" HOME_S="" AGENTS="" OUT="" DATA_DIRS="" PAGE_URL="" ASKED_NS=0 ASKED_EPOCH=0 ASK_PID="" WL_NAME="" TMP_RT=""
SILL_PID="" CASEMENT_PID="" PARENT_WL="" SENTENCE="" RESULT=0
INTERRUPTED=no
FINISHED=no

usage() { sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
DIED=no
die() { echo "w1-blender.sh: $*" >&2; DIED=yes; exit 2; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '%s\n' "$*"; }

print_build() {
  cat <<EOF
# Run these one at a time, nice, from the folder holding the checkouts ($SIB).
# 1. the desktop window (a plain build: a test build refuses to run outside the jail)
(cd $SIB/casement && CARGO_TARGET_DIR=$T_CASEMENT nice cargo build -p casement -p casementctl)
# 2. the stand-in for the system's login service, in a folder of its own so test features do not reach step 1
(cd $SIB/casement && CARGO_TARGET_DIR=$T_TOOLS nice cargo build -p casement-testkit --bin fake-logind)
# 3. the shell (bar, dock, launcher)
(cd $SIB/sill && CARGO_TARGET_DIR=$T_SILL nice cargo build -p sill --features debug)
# 4. the screen helper
(cd $SIB/cua && CARGO_TARGET_DIR=$T_CUA nice cargo build -p cuad --features docket-dbus/fixture-callers)
# 5. the assistant's services, the bring-up tool and the terminal command
(cd $SIB/docket && CARGO_TARGET_DIR=$T_DOCKET nice cargo build -p docket-accept --bins)
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --drive) DRIVE=yes ;;
      --run-dir) RUN=${2:?}; shift ;;
      --timeout) TIMEOUT=${2:?}; shift ;;
      --no-shots) SHOTS=no ;;
      --floor-dir) FLOOR_DIR_GIVEN=${2:?}; shift ;;
      --print-build) PRINT_BUILD=yes ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout wants a whole number of seconds" ;; esac
  case "$SHOT_EVERY" in ''|*[!0-9]*) die "W1_SHOT_EVERY wants a whole number of seconds" ;; esac
}

# ---- before anything starts

require_models() {
  local missing=0
  if [ -z "${W1_PLANNER_URL:-}" ]; then
    note "No assistant model is chosen. Set W1_PLANNER_URL to the address of the local model on this computer"
    note "(for example http://127.0.0.1:8090) and run again. There is no default."
    missing=1
  fi
  if [ -z "${W1_SCREEN_URL:-}" ]; then
    note "No screen model is chosen. Set W1_SCREEN_URL to the address of the model that looks at the screen, on this computer"
    note "(for fatcat, the end of a tunnel such as http://127.0.0.1:8091) and run again. There is no default."
    missing=1
  fi
  [ "$missing" = 0 ] || exit 2
}

require_session() {
  [ -z "${JAIL_SCRATCH:-}" ] || die "this is the test jail; run it on your real login"
  [ -n "${WAYLAND_DISPLAY:-}" ] || die "no Wayland desktop found: run it in a terminal on your own desktop, where windows can open"
  case "$WAYLAND_DISPLAY" in
    /*) PARENT_WL=$WAYLAND_DISPLAY ;;
    *) PARENT_WL="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$WAYLAND_DISPLAY" ;;
  esac
  [ -S "$PARENT_WL" ] || die "the desktop at $PARENT_WL does not answer"
}

require_tools() {
  local tool bad=0
  for tool in python3 curl dbus-daemon gdbus; do
    command -v "$tool" >/dev/null || { note "$tool is missing; install it with your package manager."; bad=1; }
  done
  python3 -c 'import tomllib' 2>/dev/null || { note "python3 is older than 3.11."; bad=1; }
  command -v blender >/dev/null || { note "Blender is not installed. To install: $("${PY[@]}" hint blender)"; bad=1; }
  pick_browser
  if [ -z "$BROWSER_KIND" ]; then
    note "No browser is installed (Zen or Firefox). To install: $("${PY[@]}" hint zen)   or   $("${PY[@]}" hint firefox)"; bad=1
  fi
  [ "$bad" = 0 ] || exit 2
}

BROWSER_KIND="" BROWSER_IDS="" BROWSER_APP=""
pick_browser() {
  if [ -n "${W1_BROWSER_CMD:-}" ]; then
    BROWSER_KIND=custom BROWSER_IDS="firefox,zen,org.mozilla.firefox,app.zen_browser.zen" BROWSER_APP=org.mozilla.firefox
  elif command -v zen >/dev/null || command -v zen-browser >/dev/null; then
    BROWSER_KIND=zen BROWSER_IDS="zen,zen-browser,app.zen_browser.zen" BROWSER_APP=app.zen_browser.zen
  elif command -v flatpak >/dev/null && flatpak info app.zen_browser.zen >/dev/null 2>&1; then
    BROWSER_KIND=zen-flatpak BROWSER_IDS="zen,zen-browser,app.zen_browser.zen" BROWSER_APP=app.zen_browser.zen
  elif command -v firefox >/dev/null; then
    BROWSER_KIND=firefox BROWSER_IDS="firefox,org.mozilla.firefox" BROWSER_APP=org.mozilla.firefox
  fi
}

require_built() {
  local missing=0 path
  for path in "$CASEMENT" "$FAKE_LOGIND" "$SILL" "$CUAD" "$BRINGUP" "$QUIREDO" \
              "$(dirname "$BRINGUP")/accept-intentd" "$(dirname "$BRINGUP")/accept-companiond"; do
    [ -x "$path" ] || { note "Not built yet: $path"; missing=1; }
  done
  if [ "$missing" = 1 ]; then
    note "Ask whoever builds for this rig to run the builds that --print-build lists, then run again."
    exit 2
  fi
}

# check_model NAME URL MODEL SERVED: the server answers, is on this computer, and lists the model; sets SERVED_NAME.
check_model() {
  local what=$1 url=$2 model=$3 want=$4 var=$5 hint=$6 answer names
  "${PY[@]}" loopback "$url" >/dev/null || {
    note "The $what address ($url) must be on this computer: http://127.0.0.1:PORT."
    note "For a model on another computer, open a tunnel first (for fatcat: ssh -N -L 8091:127.0.0.1:8000 fatcat) and give the tunnel's address."
    exit 2
  }
  if ! answer=$(curl -fsS --max-time 8 "${url%/}/v1/models" 2>/dev/null); then
    if [ "$what" = "screen model" ]; then note "The screen model does not answer at $url. Start the screen model on fatcat, then run again."
    else note "The assistant's model does not answer at $url. Start it (the local Qwen server), then run again."; fi
    exit 2
  fi
  names=$("${PY[@]}" served <<<"$answer") || { note "The $what at $url lists no models."; exit 2; }
  if [ -n "$want" ]; then
    grep -qxF -- "$want" <<<"$names" || { note "The $what at $url does not list $want. It lists: $(tr '\n' ' ' <<<"$names")"; exit 2; }
    printf -v "$var" '%s' "$want"
  elif grep -qxF -- "$model" <<<"$names"; then printf -v "$var" '%s' "$model"
  elif [ "$(wc -l <<<"$names")" = 1 ]; then printf -v "$var" '%s' "$names"
  else note "The $what at $url lists several models and none is $model: $(tr '\n' ' ' <<<"$names")"
       note "Say which with $hint."; exit 2; fi
}

# ---- processes we start

proc_token() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20; }
same_proc() { [ -n "$2" ] && [ "$(proc_token "$1")" = "$2" ]; }
record() { STARTED+=("$1 $2 $(proc_token "$2")"); }
now_ns() { "${TIMING[@]}" now; }
stamp() { printf '%s\t%s\t%s\n' "$1" "$(now_ns)" "$(date +%s)" >>"$RUN/stamps.tsv"; }

in_env() {
  env HOME="$HOME_S" XDG_RUNTIME_DIR="$RT" WAYLAND_DISPLAY="${WL_NAME:-}" DBUS_SESSION_BUS_ADDRESS="$BUS" \
    DBUS_SYSTEM_BUS_ADDRESS="$BUS" XDG_CONFIG_HOME="$HOME_S/.config" XDG_DATA_HOME="$HOME_S/.local/share" \
    XDG_STATE_HOME="$HOME_S/.local/state" XDG_CACHE_HOME="$HOME_S/.cache" XDG_DATA_DIRS="$DATA_DIRS" "$@"
}

end_one() { # NAME PID TOKEN
  local waited=0
  case "$1" in
    bringup) "$BRINGUP" down --root "$AGENTS" >>"$RUN/bringup.log" 2>&1 || true; return ;;
  esac
  same_proc "$2" "$3" || return 0
  kill -TERM "$2" 2>/dev/null
  while same_proc "$2" "$3" && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  if same_proc "$2" "$3"; then note "  $1 did not stop; ending it"; kill -KILL "$2" 2>/dev/null; fi
}

# Everything that runs with this run's own runtime folder in its environment (apps opened in the window).
record_window_clients() {
  local pid
  [ -n "${RT:-}" ] || return 0
  for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$' | sort -n); do
    [ "$pid" != "$$" ] || continue
    printf '%s\n' "${STARTED[@]}" | grep -q " $pid " && continue
    tr '\0' '\n' 2>/dev/null <"/proc/$pid/environ" | grep -qx "XDG_RUNTIME_DIR=$RT" || continue
    record client "$pid"
  done
}

teardown() {
  local i name pid token
  record_window_clients
  for ((i = ${#STARTED[@]} - 1; i >= 0; i--)); do
    read -r name pid token <<<"${STARTED[$i]}"
    end_one "$name" "$pid" "$token"
  done
  STARTED=()
  [ -z "${TMP_RT:-}" ] || rm -rf "$TMP_RT"
}

# ---- the scratch world

setup_world() {
  [ -n "$RUN" ] || RUN="$HOME/.cache/w1-runs/$(date +%Y%m%d-%H%M%S)"
  case "$RUN" in /*) ;; *) RUN="$PWD/$RUN" ;; esac
  [ ! -e "$RUN/stamps.tsv" ] || die "$RUN already holds a run; pick another folder"
  HOME_S=$RUN/home AGENTS=$RUN/agents OUT=$RUN/out
  mkdir -p "$HOME_S/.config" "$HOME_S/.local/share" "$HOME_S/.local/state" "$HOME_S/.cache" "$AGENTS" "$OUT" "$RUN/shots" \
    "$RUN/floor" "$RUN/browser-profile" || die "cannot make $RUN"
  RT=$RUN/runtime
  if [ ${#RT} -gt 60 ]; then TMP_RT=$(mktemp -d /tmp/w1rt.XXXXXX) RT=$TMP_RT; fi
  mkdir -p "$RT" && chmod 700 "$RT"
  DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:$HOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share"
  : >"$RUN/stamps.tsv"
  stamp start
  touch "$RUN/.start"
  note "This run keeps everything in $RUN"
}

start_bus() {
  cat >"$RUN/private-bus.conf" <<'EOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <keep_umask/>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
  local out pid
  out=$(dbus-daemon --config-file "$RUN/private-bus.conf" --fork --print-address=1 --print-pid=1 2>"$RUN/bus.log") \
    || die "the private message bus did not start: $(cat "$RUN/bus.log")"
  BUS=$(sed -n 1p <<<"$out") pid=$(sed -n 2p <<<"$out")
  [ -n "$BUS" ] && [ -n "$pid" ] || die "the private message bus printed no address"
  record bus "$pid"
  WL_NAME=""
  in_env "$FAKE_LOGIND" >"$RUN/fake-logind.log" 2>&1 </dev/null &
  record logind $!
}

write_floor() {
  # A proposal for an administrator-owned permission folder: the programs this run starts and what they may do.
  local f=$RUN/floor/privacy.toml prog power
  : >"$f"
  for prog in "$CUAD:screen" "$CUAD:keys" "$CUAD:windows"; do
    power=${prog##*:}; prog=${prog%:*}
    printf '\n[[rule]]\npower = "%s"\nsubject = { program = "%s" }\nanswer = "allow"\n' "$power" "$(readlink -f "$prog")" >>"$f"
  done
  command -v grim >/dev/null && printf '\n[[rule]]\npower = "screen"\nsubject = { program = "%s" }\nanswer = "allow"\n' \
    "$(readlink -f "$(command -v grim)")" >>"$f"
  note "A proposed permission folder is in $RUN/floor. To skip the questions, have the administrator copy it into a root-owned folder and run again with --floor-dir."
}

start_casement() {
  local args=(--backend winit --clock wall --config-home "$RUN/casement-config") waited=0 line
  [ -z "$FLOOR_DIR_GIVEN" ] || args+=(--system-dir "$FLOOR_DIR_GIVEN")
  mkdir -p "$RUN/casement-config"
  env HOME="$HOME_S" XDG_RUNTIME_DIR="$RT" WAYLAND_DISPLAY="$PARENT_WL" DBUS_SESSION_BUS_ADDRESS="$BUS" \
    DBUS_SYSTEM_BUS_ADDRESS="$BUS" XDG_CONFIG_HOME="$HOME_S/.config" XDG_DATA_HOME="$HOME_S/.local/share" \
    XDG_STATE_HOME="$HOME_S/.local/state" XDG_CACHE_HOME="$HOME_S/.cache" \
    "$CASEMENT" "${args[@]}" >"$RUN/casement.log" 2>&1 </dev/null &
  CASEMENT_PID=$!
  record casement "$CASEMENT_PID"
  while [ "$waited" -lt 300 ]; do
    kill -0 "$CASEMENT_PID" 2>/dev/null || { tail -5 "$RUN/casement.log" >&2; die "the desktop window closed at start (see $RUN/casement.log)"; }
    line=$(grep -ao 'listening on wayland-[0-9]*' "$RUN/casement.log" | head -1)
    WL_NAME=${line##* on }
    [ -n "$line" ] || WL_NAME=$(ls "$RT" 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -1)
    [ -z "$WL_NAME" ] || [ ! -S "$RT/$WL_NAME" ] || break
    WL_NAME=""
    sleep 0.1; waited=$((waited + 1))
  done
  [ -n "$WL_NAME" ] || die "the desktop window never opened a place for programs to join (see $RUN/casement.log)"
  stamp casement_up
  note "The desktop window is up."
}

start_sill() {
  local flags=()
  printf '{"displays":[]}\n' >"$HOME_S/.config/ddc.json"
  "$SILL" run --help 2>&1 | grep -q -- --fake-ddc && flags+=(--fake-ddc "$HOME_S/.config/ddc.json")
  if "$SILL" run --help 2>&1 | grep -q -- --dev-callers; then
    printf '[[peer]]\napp = "org.quire.Intents"\nrole = "router"\nexe = ["%s"]\n' \
      "$(readlink -f "$(dirname "$BRINGUP")/accept-intentd")" >"$RUN/dev-callers.toml"
    chmod 600 "$RUN/dev-callers.toml"
    flags+=(--dev-callers "$RUN/dev-callers.toml")
  fi
  in_env "$SILL" run "${flags[@]}" >"$RUN/sill.log" 2>&1 </dev/null &
  SILL_PID=$!
  record sill "$SILL_PID"
  local i
  for i in $(seq 200); do
    in_env "$SILL" ping >/dev/null 2>&1 && return 0
    kill -0 "$SILL_PID" 2>/dev/null || break
    sleep 0.1
  done
  tail -5 "$RUN/sill.log" >&2
  die "the shell did not start (see $RUN/sill.log)"
}

bus_has_owner() {
  gdbus call --address "$BUS" --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.NameHasOwner "$1" 2>/dev/null | grep -q true
}

prepare_models() {
  local catalog=$RUN/catalog src=${W1_STOKER_CATALOG:-$SIB/stoker/catalog}
  [ -d "$src" ] || die "no model catalogue at $src (set W1_STOKER_CATALOG)"
  mkdir -p "$catalog" "$AGENTS/config/inferd"
  cp "$src"/*.toml "$catalog/"
  [ -f "$catalog/$PLANNER_MODEL.toml" ] || die "the catalogue has no entry for $PLANNER_MODEL"
  [ -f "$catalog/$SCREEN_MODEL.toml" ] || die "the catalogue has no entry for $SCREEN_MODEL"
  "${PY[@]}" catalog --src "$src/$PLANNER_MODEL.toml" --out "$catalog/$PLANNER_MODEL.toml" --served "$PLANNER_SERVED" --tool-parser hermes || die "cannot prepare $PLANNER_MODEL"
  "${PY[@]}" catalog --src "$src/$SCREEN_MODEL.toml" --out "$catalog/$SCREEN_MODEL.toml" --served "$SCREEN_SERVED" \
    --tool-parser qwen3_coder --reasoning-parser qwen3 || die "cannot prepare $SCREEN_MODEL"
  "${PY[@]}" inferd-config --planner-id "$PLANNER_MODEL" --planner-url "${W1_PLANNER_URL%/}" \
    --screen-id "$SCREEN_MODEL" --screen-url "${W1_SCREEN_URL%/}" >"$AGENTS/config/inferd/inferd.toml"
  mkdir -p "$HOME_S/.config/cua"
  "${PY[@]}" cuad-settings --app "org.blender.Blender=${W1_BLENDER_ALLOW:-ask}" --app "$BROWSER_APP=ask" \
    --steps "${W1_CUA_STEPS:-400}" --active-s "${W1_CUA_ACTIVE_S:-3600}" >"$HOME_S/.config/cua/settings.toml"
}

start_assistant() {
  local providers=${W1_PROVIDERS:-$SIB/porter/providers} extra=()
  [ ! -d "$providers" ] || extra+=(--providers "$providers")
  env -u DBUS_SESSION_BUS_ADDRESS -u DBUS_SYSTEM_BUS_ADDRESS "$BRINGUP" up --bus "$BUS" --root "$AGENTS" \
    --shell-pid "$SILL_PID" --catalog "$RUN/catalog" "${extra[@]}" >"$RUN/bringup.log" 2>&1 \
    || { tail -8 "$RUN/bringup.log" >&2; "$BRINGUP" down --root "$AGENTS" >/dev/null 2>&1; die "the assistant's services did not start (see $RUN/bringup.log)"; }
  STARTED+=("bringup 0 -")
  restart_companion_with_log
  stamp stack_up
  note "The assistant's services are up."
}

# The assistant is started again with its model log on (the log path is its only change).
restart_companion_with_log() {
  local line pid envfile=$RUN/companiond.env exe waited=0
  line=$(awk '$1 == "companiond" {print}' "$AGENTS/procs") pid=$(awk '{print $2}' <<<"$line")
  [ -n "$pid" ] || die "the assistant's service is not running"
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
  local new=$!
  waited=0
  until bus_has_owner org.quire.Companion1; do
    kill -0 "$new" 2>/dev/null && [ "$waited" -lt 300 ] || die "the assistant did not come back with its log on"
    sleep 0.1; waited=$((waited + 1))
  done
  { grep -v '^companiond ' "$AGENTS/procs"; echo "companiond $new $(proc_token "$new")"; } >"$AGENTS/procs.new" && mv "$AGENTS/procs.new" "$AGENTS/procs"
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
  in_env bash -c 'mkdir -p "$1/proc/$$" "$1/proc/units"; printf "0::/user.slice/user-1000.slice/user@1000.service/app.slice/cuad.service\n" > "$1/proc/$$/cgroup"; echo $$ > "$1/proc/units/cuad.service"; exec env CUAD_TEST_PROC_ROOT="$1/proc" CUAD_TEST_SYSTEM_CALLERS="$2" "$3"' \
    _ "$AGENTS" "$RUN/cuad-callers.toml" "$CUAD" >"$RUN/cuad.log" 2>&1 </dev/null &
  local cuad_pid=$!
  record cuad "$cuad_pid"
  sleep 2
  kill -0 "$cuad_pid" 2>/dev/null || { tail -5 "$RUN/cuad.log" >&2; die "the screen helper did not start (see $RUN/cuad.log)"; }
}

start_page() {
  "${PY[@]}" serve --dir "$HERE/fixtures/w1" --port-file "$RUN/port" >/dev/null 2>&1 </dev/null &
  record page $!
  local i
  for i in $(seq 50); do [ -s "$RUN/port" ] && break; sleep 0.1; done
  [ -s "$RUN/port" ] || die "the product page could not be served"
  PAGE_URL="http://127.0.0.1:$(cat "$RUN/port")/index.html"
}

start_browser() {
  local cmd
  case "$BROWSER_KIND" in
    custom) cmd=($W1_BROWSER_CMD "$PAGE_URL") ;;
    zen) cmd=("$(command -v zen || command -v zen-browser)" --profile "$RUN/browser-profile" --no-remote "$PAGE_URL") ;;
    zen-flatpak) cmd=(flatpak run --filesystem="$RUN/browser-profile" app.zen_browser.zen --profile "$RUN/browser-profile" --no-remote "$PAGE_URL") ;;
    firefox) cmd=(firefox --profile "$RUN/browser-profile" --no-remote "$PAGE_URL") ;;
  esac
  in_env MOZ_ENABLE_WAYLAND=1 "${cmd[@]}" >"$RUN/browser.log" 2>&1 </dev/null &
  record browser $!
}

# ---- watching

shot() { # NAME
  [ "$SHOTS" = yes ] && command -v grim >/dev/null || return 0
  SHOT_N=$((SHOT_N + 1))
  in_env timeout 15 grim "$RUN/shots/$(printf '%02d' "$SHOT_N")-$1.png" >/dev/null 2>&1 || true
}
SHOT_N=0

window_seen() { # IDS AFTER_NS -> 0 when a window of those ids was shown after AFTER_NS
  "${TIMING[@]}" wait --log-file "$RUN/casement.log" --app-ids "$1" --after-connected "${2:-0}" --timeout 0 >/dev/null 2>&1
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

wait_for_file() {
  local deadline=$((SECONDS + TIMEOUT)) last=0 size prev=-1 stable=0 next_shot=$((SECONDS + SHOT_EVERY))
  local blender_seen=no turn_seen=no screen_seen=no ask_state=none rc f epoch
  while [ "$SECONDS" -lt "$deadline" ]; do
    f=$(ls "$OUT"/*.glb 2>/dev/null | head -1)
    if [ -n "$f" ]; then
      size=$(stat -c %s "$f" 2>/dev/null || echo 0)
      if [ "$size" = "$prev" ] && [ "$size" -gt 0 ]; then stable=$((stable + 1)); else stable=0; fi
      prev=$size
      if [ "$stable" -ge 2 ]; then stamp glb_seen; shot file-saved; note "The file is saved: $f"; return 0; fi
    fi
    if [ "$blender_seen" = no ] && window_seen "blender,org.blender.blender" "$ASKED_NS"; then
      blender_seen=yes; stamp blender_open; shot blender-open; note "Blender is open."
    fi
    if [ "$turn_seen" = no ] && epoch=$("${PY[@]}" first-turn --audit "$AGENTS/.local/state/quire/inferd/audit.jsonl" --since "$ASKED_EPOCH"); then
      turn_seen=yes; stamp first_turn; note "The assistant has started thinking."
    fi
    if [ "$screen_seen" = no ] && epoch=$("${PY[@]}" first-screen --audit "$AGENTS/.local/state/quire/inferd/audit.jsonl" --since "$ASKED_EPOCH"); then
      screen_seen=yes; stamp first_screen_step; shot first-screen-step; note "The screen helper has started looking at the window."
    fi
    if [ "$ask_state" = none ] && [ -n "${ASK_PID:-}" ] && ! kill -0 "$ASK_PID" 2>/dev/null; then
      wait "$ASK_PID" 2>/dev/null; rc=$?
      ask_state=ended
      case "$rc" in
        0) note "The assistant has finished its turn; waiting a little for the file." ; deadline=$((SECONDS + 60)) ;;
        8) note "The assistant is waiting for you on the desktop window. Answer its question there; this script keeps waiting." ;;
        *) note "The request ended early (code $rc): $(tail -1 "$RUN/turn.err" 2>/dev/null)"; deadline=$((SECONDS + 30)) ;;
      esac
    fi
    if [ "$SECONDS" -ge "$next_shot" ]; then shot progress; next_shot=$((SECONDS + SHOT_EVERY)); fi
    sleep 2
  done
  note "No file was saved within $TIMEOUT seconds."
  return 1
}

check_file() {
  local f
  f=$(ls "$OUT"/*.glb 2>/dev/null | head -1)
  [ -n "$f" ] || return 0
  note "Reading the saved file in Blender..."
  env HOME="$HOME_S" XDG_CONFIG_HOME="$HOME_S/.config" XDG_CACHE_HOME="$HOME_S/.cache" XDG_DATA_HOME="$HOME_S/.local/share" \
    W1_GLB="$f" timeout 180 blender --background --factory-startup --python-expr "$("${PY[@]}" blender-expr)" \
    >"$RUN/glb-reading.txt" 2>&1 </dev/null || true
}

list_files_made() {
  (cd "$RUN" && find home out -type f -newer .start \( -name '*.blend' -o -name '*.glb' -o -name '*.obj' -o -name '*.stl' -o -name '*.py' \) \
    -not -path 'home/.config/*' -not -path 'home/.cache/*' 2>/dev/null | sort) >"$RUN/files-made.txt"
}

finish() {
  [ "$FINISHED" = no ] || return 0
  FINISHED=yes
  trap - EXIT INT TERM
  if [ "$DIED" = yes ]; then teardown; exit 2; fi
  stamp finished
  shot end
  check_file
  list_files_made
  say "Report"
  RESULT=0
  "${PY[@]}" report --run "$RUN" --expected "$HERE/fixtures/w1/expected.json" || RESULT=1
  teardown
  note ""
  note "The report is $RUN/report.md"
  exit "$RESULT"
}

on_signal() { INTERRUPTED=yes; note ""; note "Stopping."; exit 130; }

main() {
  parse_args "$@"
  if [ "$PRINT_BUILD" = yes ]; then print_build; exit 0; fi
  require_models
  require_session
  require_tools
  require_built
  check_model "assistant model" "$W1_PLANNER_URL" "$PLANNER_MODEL" "${W1_PLANNER_SERVED:-}" PLANNER_SERVED W1_PLANNER_SERVED
  check_model "screen model" "$W1_SCREEN_URL" "$SCREEN_MODEL" "${W1_SCREEN_SERVED:-}" SCREEN_SERVED W1_SCREEN_SERVED
  [ "$DRIVE" = no ] || [ -t 0 ] || die "--drive needs a terminal, because it waits for you to press Enter"
  setup_world
  trap finish EXIT
  trap on_signal INT TERM
  SENTENCE=$("${PY[@]}" sentence --outdir "$OUT")
  say "Before the window opens"
  note "The desktop window will ask you to allow the assistant's screen helper, the launcher and the apps the first time; say Allow."
  write_floor
  prepare_models
  say "Starting"
  start_bus
  start_casement
  start_sill
  start_assistant
  start_screen_helper
  start_page
  local before; before=$(now_ns)
  start_browser
  if "${TIMING[@]}" wait --log-file "$RUN/casement.log" --app-ids "$BROWSER_IDS" --after-connected "$before" --timeout 90 >/dev/null 2>&1; then
    stamp page_open
  else
    note "(The page's window was not seen in the timing lines; carrying on.)"
  fi
  in_env "$SILL" companion summon >/dev/null 2>&1 || note "(The launcher did not open; open it yourself.)"
  shot page-and-launcher
  say "Your turn"
  note "The product page is open in the window, on this computer only: $PAGE_URL"
  note "Say this to the assistant:"
  note ""
  note "    $SENTENCE"
  note ""
  if [ "$DRIVE" = yes ]; then
    note "Answer the window's questions now. Press Enter when it is ready and I will send the request for you."
    read -r _
  fi
  ASKED_NS=$(now_ns) ASKED_EPOCH=$(date +%s)
  stamp asked
  if [ "$DRIVE" = yes ]; then post_turn; note "Request sent."; fi
  say "Waiting for the file (press Ctrl-C to stop and get the report)"
  wait_for_file || true
}

main "$@"
