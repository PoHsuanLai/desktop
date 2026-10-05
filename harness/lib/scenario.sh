# Where a scenario finds the checkouts and the artefacts harness/scenario-build.sh built (outside the
# jail). Sourced by scenario-build.sh and by the scenarios that run real consumers; needs nothing else.
#
#   SCEN_ROOT   this checkout            SCEN_SIB    the directory holding the sibling checkouts
#   SCEN_BUILD  where the build went     SCEN_TOOLS  casement's tools (bin/casement, casementctl, ...)
SCEN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCEN_SIB="$(cd "$SCEN_ROOT/.." && pwd)"
SCEN_BUILD="$SCEN_ROOT/build"
SCEN_SRC="$SCEN_BUILD/src"    # private checkouts of sill and shell-host (scenario-build.sh)
SCEN_TOOLS="$SCEN_BUILD/tools"

# scenario_need PATH...: exit 3 (environment incomplete) with the fix printed unless each PATH is an
# executable or readable file. Scenarios call it after require_jail; the artefacts are built outside
# the jail by harness/scenario-build.sh (the desktop gate runs it first).
scenario_need() {
  local path missing=0
  for path in "$@"; do
    [ -e "$path" ] || { echo "scenario: $path is missing" >&2; missing=1; }
  done
  if [ "$missing" = 1 ]; then
    echo "scenario: fix: run $SCEN_ROOT/harness/scenario-build.sh outside the jail" >&2
    exit 3
  fi
}

# scenario_out NAME: this scenario's directory in the jail's scratch (logs, captures); created.
scenario_out() {
  local dir="${JAIL_SCRATCH:?scenario_out: not in the jail}/scenario/$1"
  mkdir -p "$dir"
  echo "$dir"
}
