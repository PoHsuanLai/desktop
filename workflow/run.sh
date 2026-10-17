#!/usr/bin/env bash
# Real-app workflow timing: how fast apps open, how fast windows switch, how fast the file dialog and the
# login are, on YOUR real login and your real GPU. On demand only: not the gate, not CI, not the jail.
# Run it in a terminal inside the sill (casement) session. About 15 minutes for everything.
#
#   workflow/run.sh [--apps firefox,foot,...] [--rounds N] [--part launch|switch|dialog|login|checks|all]
#
#   --apps    which apps to measure, by key from apps.toml (default: all that are installed)
#   --rounds  warm launches per app after the first one (default 5)
#   --part    which measurement to run (default all)
#
# Needs sill (with `sill launch --print-timing`) and python3 (3.11 or newer). The dialog part needs gdbus
# and the switch, dialog and checks parts need you at the keyboard. It never installs anything: a missing app
# is skipped, with the command that would install it. Results: ${XDG_STATE_HOME:-~/.local/state}/quire-workflow/<stamp>/
# (raw.tsv, summary.txt, answers.txt). See workflow/README.md.
#
# Exit: 0 finished, 1 some measurement failed (see the lines marked FAILED), 2 bad usage, not the casement
# session, or a tool is missing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY=(python3 -I "$HERE/lib/timing.py")
ROUNDS=5 ONLY="" PART=all FAILS=0
ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/quire-workflow"
OUT="" RAW="" ANSWERS="" ERR=""
READY=()
OPEN=()
LAST_UNIT=- LAST_PID=-

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "run.sh: $*" >&2; exit 2; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '%s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); note "  FAILED: $*"; }
now_ns() { "${PY[@]}" now; }
alive() { [ "$1" != - ] && [ "$1" -gt 1 ] 2>/dev/null && [ -d "/proc/$1" ]; }

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --apps) ONLY=${2:?}; shift ;;
      --rounds) ROUNDS=${2:?}; shift ;;
      --part) PART=${2:?}; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  case "$PART" in launch|switch|dialog|login|checks|all) ;; *) usage >&2; exit 2 ;; esac
  case "$ROUNDS" in ''|*[!0-9]*) die "--rounds wants a whole number" ;; esac
}

wants() { [ "$PART" = all ] || [ "$PART" = "$1" ]; }

require_session() {
  [ -z "${JAIL_SCRATCH:-}" ] || die "this is the test jail; run it on your real login"
  [ -n "${WAYLAND_DISPLAY:-}" ] || die "no Wayland display: run it in a terminal inside the sill (casement) session"
  [ "${XDG_CURRENT_DESKTOP:-}" = quire ] || [ -n "${CASEMENT_SOCKET:-}" ] || pgrep -u "$USER" -x casement >/dev/null \
    || die "this is not the sill (casement) session; log in to it first"
  command -v python3 >/dev/null || die "python3 is missing"
  python3 -c 'import tomllib' 2>/dev/null || die "python3 is older than 3.11 (no tomllib)"
  command -v sill >/dev/null || die "sill is not on PATH"
  if wants switch || wants dialog || wants checks; then
    [ -t 0 ] || die "this part needs you at the keyboard (run it in a terminal)"
  fi
  if wants dialog; then command -v gdbus >/dev/null || die "gdbus is missing (the glib2 tools)"; fi
}

start_results() {
  OUT="$ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$OUT"
  RAW="$OUT/raw.tsv" ANSWERS="$OUT/answers.txt" ERR="$OUT/.err"
  printf 'part\tapp\tphase\tround\tstage\tvalue_ms\ttext\n' >"$RAW"
  : >"$ANSWERS"
  note "Results go to $OUT"
}

# ---- apps

split_app() { IFS=$'\t' read -r KEY STATE KIND DESKTOP_ID APP_IDS TIMEOUT TITLE BINARY HINT <<<"$1"; }

load_apps() {
  local line known
  known=$("${PY[@]}" apps --file "$HERE/apps.toml" | cut -f1 | tr '\n' ' ')
  for key in ${ONLY//,/ }; do
    case " $known " in *" $key "*) ;; *) die "unknown app '$key'; the keys are: $known" ;; esac
  done
  while IFS= read -r line; do
    split_app "$line"
    case "$STATE" in
      ok) READY+=("$line") ;;
      nodesktop) note "Skipping $TITLE: $BINARY is installed but has no desktop entry, so sill cannot launch it." ;;
      *) note "Skipping $TITLE: not installed. To install: $HINT" ;;
    esac
  done < <("${PY[@]}" apps --file "$HERE/apps.toml" ${ONLY:+--only "$ONLY"})
  [ "${#READY[@]}" -gt 0 ] || die "none of the apps is installed"
}

# ---- launching and closing

close_app() { # UNIT PID: ask politely (stop the unit, else SIGTERM) and wait until it is gone
  local unit=$1 pid=$2 waited=0
  [ "$unit" != - ] || [ "$pid" != - ] || return 0
  if [ "$unit" = - ] || ! systemctl --user stop "$unit" 2>/dev/null; then
    ! alive "$pid" || kill -TERM "$pid" 2>/dev/null || true
  fi
  while alive "$pid" && [ "$waited" -lt 40 ]; do sleep 0.5; waited=$((waited + 1)); done
  ! alive "$pid" || note "  it did not exit within 20 s; carrying on"
  sleep 1
}

record_gpu() { # KEY PHASE ROUND SILL_PID WINDOW_PID
  local text
  text=$("${PY[@]}" gpu --pid "$4")
  case "$text" in none*) [ "$5" = - ] || [ "$5" = 0 ] || text=$("${PY[@]}" gpu --pid "$5") ;; esac
  printf 'launch\t%s\t%s\t%s\tgpu\t\t%s\n' "$1" "$2" "$3" "$text" >>"$RAW"
}

launch_once() { # KEY DESKTOP_ID APP_IDS TIMEOUT KIND PHASE ROUND; PHASE - = start it, record nothing
  local key=$1 id=$2 ids=$3 timeout=$4 kind=$5 phase=$6 round=$7 out line unit pid requested ready rows wpid
  LAST_UNIT=- LAST_PID=-
  if ! out=$(sill launch "$id" --print-timing 2>"$ERR"); then
    fail "$key: sill could not launch it ($(head -1 "$ERR"))"; return 1
  fi
  line=$("${PY[@]}" pick launch <<<"$out") || { fail "$key: sill printed no timing line"; return 1; }
  read -r unit pid requested < <("${PY[@]}" field "$line" unit pid requested_at)
  LAST_UNIT=$unit LAST_PID=$pid
  if ! ready=$("${PY[@]}" wait --app-ids "$ids" --pid "$pid" --after-connected "$requested" --timeout "$timeout" --window 300); then
    fail "$key: no window within $timeout s"; return 1
  fi
  [ "$phase" != - ] || return 0
  rows=$("${PY[@]}" rows --kind launch --launch "$line" --ready "$ready" --app "$key" --phase "$phase" --round "$round")
  printf '%s\n' "$rows" >>"$RAW"
  read -r wpid < <("${PY[@]}" field "$ready" pid)
  # An app started over D-Bus has no unit and no pid of sill's: close the window's process instead.
  if [ "$LAST_PID" = 0 ] || [ "$LAST_PID" = - ]; then LAST_PID=$wpid; fi
  record_gpu "$key" "$phase" "$round" "$pid" "$wpid"
  if [ "$kind" = x11 ] && [ "$phase" = cold ]; then
    "${PY[@]}" xwayland --after "$requested" --app "$key" >>"$RAW" || note "  (no X11 bridge start seen: it was already running)"
  fi
  awk -F'\t' -v k="$key" -v p="$phase" -v r="$round" \
    '$5 == "total_to_first_frame" { a = $6 } $5 == "total_to_settled" { b = $6 } END { printf "  %-8s %-5s %s: %.0f ms to first frame, %.0f ms settled\n", k, p, r, a, b }' <<<"$rows"
}

launch_app() { # a READY line, PHASE, ROUND
  split_app "$1"
  launch_once "$KEY" "$DESKTOP_ID" "$APP_IDS" "$TIMEOUT" "$KIND" "$2" "$3"
}

part_launch() {
  local line round phase launched
  say "Launch: the first launch of this run, then $ROUNDS warm ones, per app"
  for line in "${READY[@]}"; do
    split_app "$line"; note "$TITLE"
    for ((round = 0; round <= ROUNDS; round++)); do
      phase=warm; [ "$round" -gt 0 ] || phase=cold
      launched=yes
      launch_app "$line" "$phase" "$round" || launched=no
      close_app "$LAST_UNIT" "$LAST_PID"
      [ "$launched" = yes ] || [ "$round" -gt 0 ] || break
    done
  done
}

# ---- switching windows

press_phase() { # CAUSE WHAT: let the person act, then read the key-window lines of that time
  local cause=$1 what=$2 from until
  read -r -p "   Press Enter, then $what. Come back to this terminal and press Enter again. " _
  from=$(now_ns)
  read -r _
  until=$(now_ns)
  "${PY[@]}" switch --from "$from" --until "$until" --cause "$cause" >>"$RAW"
}

part_switch() {
  local line
  say "Switching windows"
  [ "${#READY[@]}" -ge 2 ] || { note "Needs at least two installed apps; skipped."; return 0; }
  for line in "${READY[@]:0:3}"; do
    split_app "$line"; note "Opening $TITLE ..."
    launch_once "$KEY" "$DESKTOP_ID" "$APP_IDS" "$TIMEOUT" "$KIND" - 0 || true
    [ "$LAST_UNIT" = - ] && [ "$LAST_PID" = - ] || OPEN+=("$LAST_UNIT $LAST_PID")
  done
  press_phase keyboard "press Cmd+Tab 10 times, about a second apart, ending on this terminal"
  press_phase pointer "click between the windows 5 times, ending on this terminal"
  cleanup
}

# ---- the file dialog, the login

part_dialog() {
  local number phase asked ready
  say "File dialog: the first and the second one of this run"
  for number in 1 2; do
    phase=warm; [ "$number" -gt 1 ] || phase=cold
    if ! asked=$("${PY[@]}" dialog-open --token "workflow$$x$number"); then fail "the portal did not open a file dialog"; continue; fi
    if ready=$("${PY[@]}" wait --any-app --after-commit "$asked" --timeout 30 --window 120); then
      "${PY[@]}" rows --kind dialog --request-at "$asked" --ready "$ready" --app dialog --phase "$phase" --round "$number" >>"$RAW"
    else
      fail "no dialog window within 30 s"
    fi
    read -r -p "   A file dialog should be open. Press Escape in it, then press Enter here. " _
  done
}

part_login() {
  say "Login: this boot's session-ready line"
  "${PY[@]}" login --boot >>"$RAW" || fail "no session-ready line in this boot's journal or casement.log (a build without the timing lines?)"
}

# ---- short checks

ask() { # ID TEXT: y works, n broken (then one line about it), s skip
  local id=$1 a= why=
  shift
  printf '\n\033[1m%s\033[0m  %s\n' "$id" "$*"
  while :; do read -r -p "   y/n/s? " a; case $a in y|n|s) break ;; esac; done
  [ "$a" != n ] || read -r -p "   what happened (one line)? " why
  printf '%s %s %s\n' "$id" "$a" "$why" >>"$ANSWERS"
}

part_checks() {
  say "Short checks: try each thing, then answer y / n / s"
  ask C1 "Typing works in every app: open each app you measured, click into it and type a few words."
  ask C2 "Copy a few words in Firefox, paste them into foot (Cmd+C, then Cmd+V)."
  ask C3 "Drag a file from the Files app into a Firefox window (for example onto a file upload page)."
  ask C4 "Blender: make the window full screen (Ctrl+Cmd+F or the green button) and back. Smooth, nothing flickers, the size comes back."
  ask C5 "Blender: open a big scene or the default cube, then drag the window corner to resize it. Smooth, no stutter."
}

# ---- the summary

previous_run() {
  local d
  for d in $(printf '%s\n' "$ROOT"/*/ | sort -r); do
    d=${d%/}
    if [ "$d" != "$OUT" ] && [ -f "$d/raw.tsv" ]; then echo "$d"; return; fi
  done
}

write_summary() {
  local prev
  prev=$(previous_run || true)
  {
    echo "Workflow timing $(basename "$OUT")   release: $(readlink /opt/quire/current 2>/dev/null || echo unknown)   kernel: $(uname -r)   warm rounds: $ROUNDS"
    echo
    "${PY[@]}" summarize --raw "$RAW" ${prev:+--previous "$prev/raw.tsv"} --answers "$ANSWERS"
  } >"$OUT/summary.txt"
  say "Summary"
  cat "$OUT/summary.txt"
  note ""
  note "Saved in $OUT"
}

cleanup() {
  local pair
  for pair in ${OPEN[@]+"${OPEN[@]}"}; do close_app ${pair}; done
  OPEN=()
}

main() {
  parse_args "$@"
  require_session
  start_results
  trap cleanup EXIT
  if wants launch || wants switch; then load_apps; fi
  if wants launch; then part_launch; fi
  if wants switch; then part_switch; fi
  if wants dialog; then part_dialog; fi
  if wants login; then part_login; fi
  if wants checks; then part_checks; fi
  write_summary
  [ "$FAILS" = 0 ]
}

main "$@"
