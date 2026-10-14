#!/usr/bin/env bash
# The desktop gate (plan §4.14, §6.4). Every exit code is checked; nothing is piped or tailed.
#
#   desktop-gate.sh --self                 the repo's own checks, nothing built
#   desktop-gate.sh --merge  [--only REPO] [--keep]
#   desktop-gate.sh --phase P<n> [--only REPO] [--keep]
#
# --self    the jail's selftest (inside, 2 fabricated GPUs), its negative check (outside), the
#           manifest's shape, install.sh against stub installers (gate/installer-check.sh), and every scenario in the jail (an unlisted SKIP fails).
# --merge   --self, plus each manifest repo with `gate = "lane"` checked out at its manifest rev
#           (a detached git worktree under $DESKTOP_GATE_DIR, siblings side by side so path
#           dependencies resolve at the manifest's revs) and run through
#           ~/rs-wt/gate-lane-jailed.sh, plus manifest-check (Cargo.lock agreement).
# --phase   --merge, and additionally an entry of expected-skips.toml whose `closes` is P<n> or
#           earlier must be gone: the list is empty at that phase's exit; and sill's own acceptance
#           suite on casement (dev/accept.sh --compositor casement from the pinned sill, its skips
#           listed in sill-accept-skips.txt). The scenarios launcher-p95-on-casement and
#           detent-on-casement-at-1.5 are the phase's other checks and run with every scenario.
# --only    with --merge/--phase: gate just that repo (its siblings are still checked out)
# --keep    leave the checkouts in place
#
# Exit codes (plan §6.1): 0 green; otherwise the worst step's code. Prints
# "DESKTOP GATE GREEN (<tier>)" only when every step passed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../harness/lib/all.sh
source "$HERE/../harness/lib/all.sh"
JAIL="$ROOT/harness/jail.sh"
LANE_GATE="${GATE_LANE_JAILED:-$HOME/rs-wt/gate-lane-jailed.sh}"
LANE_DIR="${DESKTOP_GATE_DIR:-$HOME/rs-wt/desktop-gate}"

tier="" phase="" only="" keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --self) tier=self; shift ;;
    --merge) tier=merge; shift ;;
    --phase) tier=phase; phase=${2:-}; [[ "$phase" =~ ^P[0-9]+$ ]] || { echo "usage: --phase P<n>" >&2; exit 64; }; shift 2 ;;
    --only) only=${2:-}; shift 2 ;;
    --keep) keep=1; shift ;;
    *) sed -n '2,23p' "$0" >&2; exit 64 ;;
  esac
done
[ -n "$tier" ] || { sed -n '2,23p' "$0" >&2; exit 64; }
label=$tier; [ "$tier" != phase ] || label="phase $phase"

# Preflight: environment incomplete is exit 3 with the fix printed.
preflight() {
  command -v bwrap >/dev/null || { echo "missing bubblewrap: sudo dnf install bubblewrap"; return 3; }
  [ -c /dev/udmabuf ] || { echo "missing /dev/udmabuf: log in locally (uaccess) or sudo modprobe udmabuf"; return 3; }
  if [ "$tier" != self ]; then
    [ -x "$LANE_GATE" ] || { echo "missing $LANE_GATE"; return 3; }
    command -v cargo-nextest >/dev/null || { echo "missing cargo-nextest: cargo install cargo-nextest"; return 3; }
  fi
}

# "<scenario> <finding> <closes>" per entry of expected-skips.toml.
expected_skips() {
  awk '
    function flush() { if (s != "") print s, f, c; s = f = c = "" }
    /^\[\[skip\]\]/ { flush(); next }
    $1 == "scenario" { gsub(/"/, "", $3); s = $3 }
    $1 == "finding"  { gsub(/"/, "", $3); f = $3 }
    $1 == "closes"   { gsub(/"/, "", $3); c = $3 }
    END { flush() }' "$HERE/expected-skips.toml"
}

skip_entries_resolve() {
  local s f c rc=0
  while read -r s f c; do
    [ -x "$ROOT/scenarios/$s.sh" ] || { echo "expected-skips lists $s, which is not an executable scenario"; rc=1; }
    [ -n "$f" ] && [ -n "$c" ] || { echo "expected-skips entry $s needs a finding and a closing phase"; rc=1; }
  done < <(expected_skips)
  return "$rc"
}

phase_closed() { # the entry's phase is the current phase or earlier
  [ "$tier" = phase ] && [ "${1#P}" -le "${phase#P}" ]
}

# A scenario's step budget in seconds: its `# budget: N` header line, else 60.
scenario_budget() { sed -n 's/^# budget: *\([0-9][0-9]*\).*/\1/p' "$1" | head -n 1 | grep . || echo 60; }

run_scenario() {
  local name=$1 rc=0 f c
  "$JAIL" --fabricate-gpus 2 -- "$ROOT/scenarios/$name.sh" || rc=$?
  [ "$rc" = 2 ] || return "$rc"
  read -r _ f c < <(expected_skips | awk -v n="$name" '$1 == n') || true
  if [ -z "${f:-}" ]; then echo "  unexpected SKIP: $name is not in expected-skips.toml"; return 2; fi
  if phase_closed "$c"; then echo "  $name still skips ($f) but $c has closed: the list must be empty at its exit"; return 1; fi
  echo "  expected skip: $name ($f, closes $c)"
  return 0
}

checkout_repos() {
  mkdir -p "$LANE_DIR"
  ln -sfn "$ROOT" "$LANE_DIR/desktop"
  local r rev d
  for r in $(manifest_repos); do
    rev=$(manifest_repo_get "$r" rev); d="$LANE_DIR/$r"
    if [ -e "$d" ]; then git -C "$HOME/$r" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d"; fi
    git -C "$HOME/$r" worktree prune
    git -C "$HOME/$r" worktree add --detach "$d" "$rev" >/dev/null 2>&1 || { echo "cannot check out $r at $rev"; return 3; }
  done
}

remove_checkouts() {
  local r
  for r in $(manifest_repos); do
    git -C "$HOME/$r" worktree remove --force "$LANE_DIR/$r" >/dev/null 2>&1 || true
    git -C "$HOME/$r" worktree prune
  done
  rm -f "$LANE_DIR/desktop"
}

# sill's own acceptance suite on casement (plan 20 §5.2: "sill's 19 minus listed WM-state steps"), from
# the checkout at the manifest pin, every script in its own jail on a headless casement. Everything is
# built outside the jail first (accept.sh --build: sill, the testkit's examples, sill-services' bins,
# docket's intentd, casement's tools from the pinned casement). Exit 0 and 2 (SKIP) are accepted; a SKIP
# only for a script listed in sill-accept-skips.txt whose phase has not closed; any FAIL is rerun once,
# alone and one at a time (a loaded host starves the timing-sensitive scripts), and says so.
sill_accept() {
  local work="$ROOT/build/sill-accept" sill="$LANE_DIR/sill" log rc=0 name why closes
  local -a failed=() skipped=()
  rm -rf "$work"; mkdir -p "$work"; log="$work/accept.log"
  export CARGO_TARGET_DIR="$work/target" CASEMENT_TARGET="$work/casement-target" CASEMENT_TOOLS="$work/casement-tools"
  "$sill/dev/accept.sh" --compositor casement --build --out "$work/run" >"$log" 2>&1 || rc=$?
  cat "$log"
  [ "$rc" != 3 ] && [ "$rc" != 4 ] || { echo "  sill acceptance could not run (exit $rc)"; return "$rc"; }
  mapfile -t failed < <(sed -n 's/^FAIL \([a-z0-9-]*\) .*/\1/p' "$log")
  if [ "${#failed[@]}" -gt 0 ]; then
    echo "  RETRY ${failed[*]} (failed under the parallel run; one at a time now)"
    rc=0
    for name in "${failed[@]}"; do
      "$sill/dev/accept.sh" --compositor casement --jobs 1 --out "$work/retry-$name" "$name" >"$work/retry-$name.log" 2>&1
      case $? in
        0) echo "  retry PASS $name" ;;
        2) echo "  retry SKIP $name"; sed -n 's/^SKIP \([a-z0-9-]*\) .*/\1/p' "$work/retry-$name.log" >>"$work/retry-skips" ;;
        *) echo "  retry FAIL $name"; cat "$work/retry-$name.log"; rc=1 ;;
      esac
    done
    [ "$rc" = 0 ] || return 1
  fi
  mapfile -t skipped < <({ sed -n 's/^SKIP \([a-z0-9-]*\) .*/\1/p' "$log"; cat "$work/retry-skips" 2>/dev/null; } | sort -u)
  rc=0
  for name in "${skipped[@]}"; do
    read -r _ closes why < <(awk -v n="$name" '!/^#/ && $1 == n' "$HERE/sill-accept-skips.txt") || true
    if [ -z "${closes:-}" ]; then echo "  unexpected SKIP: $name is not in sill-accept-skips.txt"; rc=1; continue; fi
    if [ "$closes" != never ] && phase_closed "$closes"; then echo "  $name still skips but $closes has closed"; rc=1; continue; fi
    echo "  expected skip: $name (closes $closes)"
  done
  return "$rc"
}

# The lane gate script names its logs $LANE_DIR/gate-target.<step>.log, one set shared by every repo
# (each repo's run overwrites the last): clear them before a repo's gate and keep that repo's set under
# build/lane-logs/<repo>/ when it ends, so a failure's cause survives the repos gated after it.
lane_gate() { # REPO
  local r=$1 rc=0 dest="$ROOT/build/lane-logs/$1" f
  rm -f "$LANE_DIR"/gate-target.*.log
  lane_gate_run "$r" || rc=1
  rm -rf "$dest"; mkdir -p "$dest"
  for f in "$LANE_DIR"/gate-target.*.log; do [ ! -e "$f" ] || mv "$f" "$dest/"; done
  [ "$rc" = 0 ] || echo "  $r logs kept in $dest/"
  return "$rc"
}

lane_gate_run() { # REPO
  local r=$1 args extra rc=0
  args=$(manifest_repo_get "$r" gate_args); extra=$(manifest_repo_get "$r" gate_extra)
  # shellcheck disable=SC2086  # gate_args is a word list on purpose
  "$LANE_GATE" "$LANE_DIR/$r" $args || return 1
  if [ -n "$extra" ]; then (cd "$LANE_DIR/$r" && eval "$extra") || rc=1; fi
  return "$rc"
}

run_dir_init
echo "run $RUN_ID"

step preflight preflight || true
[ "$STEP_WORST" = 0 ] || { echo "DESKTOP GATE FAIL ($label)"; exit "$STEP_WORST"; }

step "selftest (jail, 2 fabricated GPUs)" "$JAIL" --fabricate-gpus 2 -- "$ROOT/harness/selftest.sh" || true
step "selftest negative (outside the jail)" "$ROOT/harness/selftest.sh" --negative || true
step "manifest shape" "$HERE/manifest-check.sh" --syntax || true
step "installer (dry run and stubs)" "$HERE/installer-check.sh" || true
step "legacy-free check (generated trees)" "$HERE/legacy-free-selftest.sh" || true
step "expected-skips resolve" skip_entries_resolve || true
# The scenarios' artefacts are built outside the jail (plan A7); DESKTOP_GATE_NO_BUILD=1 skips it.
if [ -z "${DESKTOP_GATE_NO_BUILD:-}" ]; then step "scenario artefacts (built outside the jail)" "$ROOT/harness/scenario-build.sh" || true; fi
for s in "$ROOT"/scenarios/*.sh; do
  STEP_BUDGET=$(scenario_budget "$s") step "scenario $(basename "$s" .sh)" run_scenario "$(basename "$s" .sh)" || true
done

if [ "$tier" != self ]; then
  step "check out manifest revs" checkout_repos || true
  step "no removed-compositor traces in any manifest repo" "$HERE/check-legacy-free.sh" "$LANE_DIR" || true
  if [ -d "$LANE_DIR/sill" ]; then   # the checkouts exist: every lane gate runs, whatever failed before
    for r in $(manifest_repos); do
      [ "$(manifest_repo_get "$r" gate)" = lane ] || continue
      [ -z "$only" ] || [ "$only" = "$r" ] || continue
      step "lane gate $r @ $(manifest_repo_get "$r" rev | cut -c1-9)" lane_gate "$r" || true
    done
  fi
  # Whatever failed before, this check still runs (the checkouts exist): a phase gate names every failure.
  if [ "$tier" = phase ] && [ -d "$LANE_DIR/sill" ] && { [ -z "$only" ] || [ "$only" = sill ]; }; then
    step "sill acceptance on casement (dev/accept.sh --compositor casement, pinned sill)" sill_accept || true
  fi
  [ "$keep" = 1 ] || remove_checkouts
  step "manifest agrees with every Cargo.lock" "$HERE/manifest-check.sh" || true
fi

if [ "$STEP_WORST" = 0 ]; then echo "DESKTOP GATE GREEN ($label)"; else echo "DESKTOP GATE FAIL ($label, exit $STEP_WORST)"; fi
steps_exit
