#!/usr/bin/env bash
# Builds, OUTSIDE the jail, every artefact the scenarios use (plan A7: nothing inside the jail calls
# cargo or the network), into this checkout's git-ignored build/. Never
# writes into a sibling checkout: each repo builds into its own target directory under build/.
#
#   build/tools/bin/{casement,casementctl,casement-probe,casement-shell-exec,fake-logind} casement's dev/bootstrap.sh --build-only
#   build/tools/bin/foot                                                 the host's (install foot from your distro), else, on Fedora only, its rpm (dnf download, unpacked)
#   build/sill-target/debug/sill                                         sill with --features debug (the fake DDC)
#   build/transom-target/debug/transom                                  transom (the portal backend) from the sibling checkout, for portal-quire; needs libpipewire-devel and clang
#   build/shell-host-target/debug/examples/demo_*                        shell-host's real-input demos
#   build/src/{sill,shell-host}                                          private checkouts of the siblings' HEADs the scripts run from
#   build/pin/<repo>                                                     every manifest repo at its pinned rev (detent builds against these)
#   build/detent-target/debug/detent                                     detent at its pin with ds-blitz/debug-probe, for the accounts-* and detent-on-casement-at-1.5 scenarios
#   build/sill-pin-target/debug/sill                                     sill at its pin, --features debug,ds-blitz/debug-probe (the accounts-* scenarios: the pin has the accounts sheet; the probe is linked but writes nothing for sill's surfaces)
#   build/porter-target/debug/{accountd,syncd,inferd}                    porter at its pin, test-proc-root builds
#   build/porter-target/debug/porter-rig-{servers,client,secrets}        porter's test rig: fakes, an app client, a fake Secret Service
#
#   scenario-build.sh --accounts   only what the accounts-* scenarios need (casement, the pins, detent, sill at its pin, porter and its rig)
#   scenario-build.sh --w2         only what scenarios/w2-excalidraw.sh needs (casement, the checkouts, sill, and the two below):
#   build/cua-target/debug/cuad                                          cuad (the screen helper) with --features fixture-callers: a plain build identifies nobody
#   build/docket-target/debug/{docket-bringup,accept-*}                  docket-accept's test builds (the assistant's services on a fake /proc, quire-do)
#
# The siblings are the checkouts beside this one (<this>/../sill, ...): the lane's symlinks, or ~ itself.
# Exit codes: 0 built, 2 run inside a jail, 3 a host tool is missing or a build failed.
set -euo pipefail
only_accounts=0 only_w2=0
case "${1:-}" in
  "") ;;
  --accounts) only_accounts=1 ;;
  --w2) only_w2=1 ;;
  *) echo "usage: scenario-build.sh [--accounts|--w2]" >&2; exit 64 ;;
esac
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/all.sh
source "$ROOT/harness/lib/all.sh"
# shellcheck source=../install/distro.sh
source "$ROOT/install/distro.sh"
# shellcheck source=../install/packages.sh
source "$ROOT/install/packages.sh"
if [ -z "$(jail_violations)" ]; then
  echo "scenario-build: this builds (cargo, git, the network): run it outside the jail" >&2
  exit 2
fi
source "$ROOT/harness/lib/scenario.sh"
mkdir -p "$SCEN_BUILD"
log="$SCEN_BUILD/build.log"
: >"$log"
fail() { echo "scenario-build: $1 (see $log)" >&2; exit 3; }
# stage NAME CMD...: runs CMD with its output in the log.
stage() { local name=$1; shift; echo "scenario-build: $name"; "$@" >>"$log" 2>&1 || fail "$name failed"; }

# built_at TARGET DIR...: notes in build/TARGET/BUILT_AT the HEAD each checkout DIR was built from ("<repo> <sha>" a
# line), so a scenario can refuse a build older than the siblings it is meant to test (stale_builds in scenarios/lib).
built_at() {
  local target=$SCEN_BUILD/$1 dir; shift
  mkdir -p "$target"
  for dir in "$@"; do printf '%s %s\n' "$(basename "$dir")" "$(git -C "$dir" rev-parse HEAD)"; done >"$target/BUILT_AT"
}

build_casement() {
  (cd "$SCEN_SIB/casement" && CARGO_TARGET_DIR="$SCEN_BUILD/casement-target" CASEMENT_TOOLS="$SCEN_BUILD/tools" \
    dev/bootstrap.sh --build-only) && built_at casement-target "$SCEN_SIB/casement"
}

fetch_foot() {
  local bin="$SCEN_BUILD/tools/bin/foot" dir="$SCEN_BUILD/foot-root"
  [ ! -x "$bin" ] || return 0
  if command -v foot >/dev/null; then ln -sf "$(command -v foot)" "$bin"; return 0; fi
  # Only the dnf family can fetch the rpm and unpack it; every other family installs foot from its archive.
  [ "$(distro_family)" = fedora ] || return 1
  command -v dnf >/dev/null && command -v rpm2cpio >/dev/null && command -v cpio >/dev/null || return 1
  rm -rf "$dir"; mkdir -p "$dir/rpms"
  (cd "$dir/rpms" && timeout 300 dnf download --arch x86_64 foot fcft)
  local rpm
  for rpm in "$dir"/rpms/*.rpm; do (cd "$dir" && rpm2cpio "$rpm" | cpio -idm 2>/dev/null); done
  [ -x "$dir/usr/bin/foot" ] || return 1
  printf '#!/usr/bin/env bash\nexport LD_LIBRARY_PATH="%s/usr/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\nexec "%s/usr/bin/foot" "$@"\n' \
    "$dir" "$dir" >"$bin"
  chmod +x "$bin"
}

# checkouts: private detached checkouts of the siblings' HEADs that the scenarios run from (sill and
# shell-host) under build/src, beside symlinks to every other sibling (so ../quire and the like
# resolve). A checkout is kept while its sibling's HEAD is unchanged (cargo's fingerprints survive).
# Cargo may update a Cargo.lock there; the sibling's own is never touched.
checkouts() {
  local repo rev dir other
  mkdir -p "$SCEN_SRC"
  for repo in sill shell-host; do
    dir="$SCEN_SRC/$repo"
    rev=$(git -C "$SCEN_SIB/$repo" rev-parse HEAD)
    [ ! -L "$dir" ] || rm "$dir"
    if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$rev" ]; then
      git -C "$SCEN_SIB/$repo" worktree remove --force "$dir" 2>/dev/null || rm -rf "$dir"
      git -C "$SCEN_SIB/$repo" worktree prune
      git -C "$SCEN_SIB/$repo" worktree add --detach "$dir" "$rev"
    fi
  done
  for other in $(manifest_repos) desktop; do
    case "$other" in sill|shell-host) continue ;; esac
    [ -e "$SCEN_SRC/$other" ] || ln -s "$(cd "$SCEN_SIB/$other" && pwd)" "$SCEN_SRC/$other"
  done
}

# pinned: a detached checkout of every manifest repo at its manifest rev under build/pin, side by side so
# path dependencies resolve at the pins (what the desktop gate's lane checkouts do). detent is built from here:
# its pin does not build against the siblings' newer HEADs.
pinned() {
  local repo rev dir
  mkdir -p "$SCEN_BUILD/pin"
  for repo in $(manifest_repos); do
    rev=$(manifest_repo_get "$repo" rev); dir="$SCEN_BUILD/pin/$repo"
    [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$rev" ] || continue
    git -C "$HOME/$repo" worktree remove --force "$dir" 2>/dev/null || rm -rf "$dir"
    git -C "$HOME/$repo" worktree prune
    git -C "$HOME/$repo" worktree add --detach "$dir" "$rev" || return 1
  done
  ln -sfn "$ROOT" "$SCEN_BUILD/pin/desktop"
}

# detent is built with quire's ds-blitz `debug-probe` feature (a feature of a direct dependency, so detent's own manifest
# is untouched): with QUIRE_DEBUG_PROBE=<dir> set it lists its controls by role and name (harness/lib/accounts.sh,
# detent_press). Never a release build.
build_detent() {
  (cd "$SCEN_BUILD/pin/detent" && CARGO_TARGET_DIR="$SCEN_BUILD/detent-target" cargo build -p detent --features ds-blitz/debug-probe,dev-callers)
}

build_sill() {
  (cd "$SCEN_SRC/sill" && CARGO_TARGET_DIR="$SCEN_BUILD/sill-target" cargo build -p sill --features debug) &&
    built_at sill-target "$SCEN_SRC/sill"
}

# transom from the sibling checkout, --locked (the sibling's Cargo.lock is never changed).
build_transom() {
  (cd "$SCEN_SIB/transom" && CARGO_TARGET_DIR="$SCEN_BUILD/transom-target" cargo build -p transom --features debug --locked)
}

# The demos shell-host's accept scripts run, built the way those scripts build them (two cargo
# invocations: the default features, then --features debug-inject, whose binaries the second set of
# scripts need). The scripts hard-code ROOT/target/debug/examples, so target is a link to the build dir.
build_shell_host() {
  local sh="$SCEN_SRC/shell-host" target="$SCEN_BUILD/shell-host-target"
  mkdir -p "$target"; ln -sfn "$target" "$sh/target"
  (cd "$sh" && cargo build -p shell-host \
    --example demo_hover --example demo_scroll --example demo_ime --example demo_swipe \
    --example demo_switcher --example demo_drag --example demo_lock)
  (cd "$sh" && cargo build -p shell-host --features debug-inject \
    --example demo_popup_keys --example demo_window --example probe_toplevel)
}

# Porter's daemons and test rig (crates/porter-rig) at the manifest pin (build/pin/porter, beside the other pins so ../quire
# and ../stoker resolve). The separate porter-rig checkout an earlier pin needed is removed if a build dir still has it.
# Test builds: `test-proc-root` makes each daemon read caller identities from a fixture /proc tree
# (ACCOUNTD_PROC_ROOT, SYNCD_PROC_ROOT, INFERD_PROC_ROOT), because nothing in the jail runs in a systemd scope.
# A release build ignores the variables; the features are never default.
build_porter() {
  local dir="$SCEN_BUILD/pin/porter" old="$SCEN_BUILD/pin/porter-rig"
  if [ -e "$old" ]; then
    git -C "$HOME/porter" worktree remove --force "$old" 2>/dev/null || rm -rf "$old"
    git -C "$HOME/porter" worktree prune
  fi
  # One invocation per daemon: `-p a -p b --features a/f,b/f` left syncd without its feature (the binary then ignores
  # SYNCD_PROC_ROOT and no caller is known), `-p x --features f` is what each needs.
  local d
  for d in accountd syncd inferd; do
    (cd "$dir" && CARGO_TARGET_DIR="$SCEN_BUILD/porter-target" cargo build -p "$d" --features test-proc-root) || return 1
  done
  (cd "$dir" && CARGO_TARGET_DIR="$SCEN_BUILD/porter-target" cargo build -p porter-rig)
}

# cuad, the screen helper, from the sibling checkout. The fixture-callers feature makes it read caller identities from a fake
# /proc (CUAD_TEST_PROC_ROOT): nothing in the jail runs in a systemd scope. A test build, never shipped.
build_cuad() {
  (cd "$SCEN_SIB/cua" && CARGO_TARGET_DIR="$SCEN_BUILD/cua-target" nice cargo build -p cuad --features fixture-callers) &&
    built_at cua-target "$SCEN_SIB/cua"
}

# The assistant's services as docket-accept builds (fixture identities, scripted stand-ins), docket-bringup and quire-do's
# test twin, from the sibling checkout.
build_docket() {
  (cd "$SCEN_SIB/docket" && CARGO_TARGET_DIR="$SCEN_BUILD/docket-target" nice cargo build -p docket-accept --bins) &&
    built_at docket-target "$SCEN_SIB/docket"
}

# sill at its pin: the accounts-* scenarios need the accounts sheet, which the sibling's HEAD may lack.
build_sill_pin() {
  (cd "$SCEN_BUILD/pin/sill" && CARGO_TARGET_DIR="$SCEN_BUILD/sill-pin-target" cargo build -p sill --features debug,ds-blitz/debug-probe)
}

# foot is the scenarios' terminal: say how to get it before the long builds, not after.
if [ "$only_accounts" = 0 ] && [ "$only_w2" = 0 ] && [ ! -x "$SCEN_BUILD/tools/bin/foot" ] && ! command -v foot >/dev/null && [ "$(distro_family)" != fedora ]; then
  echo "scenario-build: foot (a terminal the scenarios start) is not installed: $(install_hint foot | tr '\n' ' ')" >&2
  exit 3
fi

stage "casement (bootstrap --build-only)" build_casement
if [ "$only_w2" = 1 ]; then
  stage "checkouts of sill and shell-host" checkouts
  stage "sill (--features debug)" build_sill
  stage "cuad (--features fixture-callers)" build_cuad
  stage "docket-accept (the assistant's services, test builds)" build_docket
  echo "scenario-build: done for W2 ($SCEN_BUILD)"
  exit 0
fi
if [ "$only_accounts" = 0 ]; then
  stage "foot" fetch_foot
  stage "checkouts of sill and shell-host" checkouts
  stage "sill (--features debug)" build_sill
  stage "shell-host demos" build_shell_host
  stage "transom" build_transom
fi
stage "every repo at its manifest rev" pinned
stage "detent (at its pin)" build_detent
stage "sill at its pin (--features debug)" build_sill_pin
stage "porter at its pin: daemons (test-proc-root) and porter-rig" build_porter
echo "scenario-build: done ($SCEN_BUILD)"
