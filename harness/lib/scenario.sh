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

# scenario_fresh FIX TARGET...: exit 3 with FIX printed unless every build/TARGET was built from the HEAD its sibling
# checkout has now: each TARGET/BUILT_AT (written by scenario-build.sh) names a repo and the sha it was built at, and a
# missing note, a missing checkout or a different sha is a stale build. A scenario that silently ran yesterday's
# binary would report the fix it was meant to test as failed.
scenario_fresh() {
  local fix=$1 target repo sha now stale=0; shift
  for target in "$@"; do
    if [ ! -s "$SCEN_BUILD/$target/BUILT_AT" ]; then
      echo "scenario: build/$target does not say what it was built from" >&2; stale=1; continue
    fi
    while read -r repo sha; do
      now=$(git -C "$SCEN_SIB/$repo" rev-parse HEAD 2>/dev/null)
      [ "$now" = "$sha" ] || { echo "scenario: build/$target is $repo ${sha:0:9}, the checkout is ${now:0:9}" >&2; stale=1; }
    done <"$SCEN_BUILD/$target/BUILT_AT"
  done
  if [ "$stale" = 1 ]; then
    echo "scenario: rebuild: $fix" >&2
    exit 3
  fi
}

# scenario_out NAME: this scenario's directory in the jail's scratch (logs, captures); created.
scenario_out() {
  local dir="${JAIL_SCRATCH:?scenario_out: not in the jail}/scenario/$1"
  mkdir -p "$dir"
  echo "$dir"
}
