# Steps, their timing and verdicts, with the exit codes of plan §6.1:
#   0 pass | 1 a test failed | 2 could not run safely (a SKIP) | 3 environment incomplete
#   4 budget overrun (> 2x) | 5 jail breach (stops the run at once).
# shellcheck source=budget.sh
source "$(dirname "${BASH_SOURCE[0]}")/budget.sh"

STEP_WORST=0   # the verdict steps_exit will use

# step NAME CMD...: runs CMD, prints "PASS|SKIP|FAIL NAME (Ns)". STEP_BUDGET (seconds) arms the
# budget check. A code 5 exits the whole script now. Returns the step's code.
step() {
  local name=$1 start end rc budget=${STEP_BUDGET:-}; shift
  start=$(date +%s)
  if "$@"; then rc=0; else rc=$?; fi
  end=$(date +%s)
  if [ "$rc" = 0 ] && [ -n "$budget" ] && budget_exceeded $(( end - start )) "$budget"; then rc=4; fi
  case "$rc" in
    0) echo "PASS $name ($(( end - start ))s)" ;;
    2) echo "SKIP $name ($(( end - start ))s)" ;;
    *) echo "FAIL $name (exit $rc, $(( end - start ))s)" ;;
  esac
  if [ "$rc" = 5 ]; then echo "JAIL BREACH in $name: stopping at once" >&2; exit 5; fi
  case "$rc" in
    1|3|4) [ "$STEP_WORST" = 1 ] || [ "$STEP_WORST" = 3 ] || [ "$STEP_WORST" = 4 ] || STEP_WORST=$rc ;;
    2) [ "$STEP_WORST" != 0 ] || STEP_WORST=2 ;;
  esac
  return "$rc"
}

# steps_exit: exit with the worst code seen (a SKIP only when nothing failed).
steps_exit() { exit "$STEP_WORST"; }
