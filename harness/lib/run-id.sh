# A run id and a directory for one run's logs and artefacts. Inside the jail the directory is
# under the jail's scratch; outside it is under $DESKTOP_RUN_ROOT (default ~/.cache/desktop-runs).

run_id() { date +%Y%m%dT%H%M%S-$$; }

# Sets RUN_ID and RUN_DIR (created) once; later calls keep them.
run_dir_init() {
  if [ -z "${RUN_ID:-}" ]; then
    RUN_ID=$(run_id)
    RUN_DIR="${JAIL_SCRATCH:-${DESKTOP_RUN_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/desktop-runs}}/runs/$RUN_ID"
    mkdir -p "$RUN_DIR"
    export RUN_ID RUN_DIR
  fi
}
