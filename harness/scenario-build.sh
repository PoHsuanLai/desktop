#!/usr/bin/env bash
# Builds, OUTSIDE the jail, every artefact the scenarios use (plan A7: nothing inside the jail calls
# cargo or the network), into this checkout's git-ignored build/. Never
# writes into a sibling checkout: each repo builds into its own target directory under build/.
#
#   build/tools/bin/{casement,casementctl,casement-probe,fake-logind}   casement's dev/bootstrap.sh --build-only
#   build/tools/bin/foot                                                 the host's, else Fedora's (dnf download, unpacked)
#   build/sill-target/debug/sill                                         sill with --features debug (the fake DDC)
#   build/shell-host-target/debug/examples/demo_*                        shell-host's real-input demos
#   build/src/{sill,shell-host}                                          private checkouts of the siblings' HEADs the scripts run from
#   build/pin/<repo>                                                     every manifest repo at its pinned rev (detent builds against these)
#   build/detent-target/debug/detent                                     detent at its pin, for the detent-on-casement-at-1.5 scenario
#
# The siblings are the checkouts beside this one (<this>/../sill, ...): the lane's symlinks, or ~ itself.
# Exit codes: 0 built, 2 run inside a jail, 3 a host tool is missing or a build failed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/all.sh
source "$ROOT/harness/lib/all.sh"
if [ -z "$(jail_violations)" ]; then
  echo "scenario-build: this builds (cargo, dnf, git, the network): run it outside the jail" >&2
  exit 2
fi
source "$ROOT/harness/lib/scenario.sh"
mkdir -p "$SCEN_BUILD"
log="$SCEN_BUILD/build.log"
: >"$log"
fail() { echo "scenario-build: $1 (see $log)" >&2; exit 3; }
# stage NAME CMD...: runs CMD with its output in the log.
stage() { local name=$1; shift; echo "scenario-build: $name"; "$@" >>"$log" 2>&1 || fail "$name failed"; }

build_casement() {
  (cd "$SCEN_SIB/casement" && CARGO_TARGET_DIR="$SCEN_BUILD/casement-target" CASEMENT_TOOLS="$SCEN_BUILD/tools" \
    dev/bootstrap.sh --build-only)
}

fetch_foot() {
  local bin="$SCEN_BUILD/tools/bin/foot" dir="$SCEN_BUILD/foot-root"
  [ ! -x "$bin" ] || return 0
  if command -v foot >/dev/null; then ln -sf "$(command -v foot)" "$bin"; return 0; fi
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

build_detent() {
  (cd "$SCEN_BUILD/pin/detent" && CARGO_TARGET_DIR="$SCEN_BUILD/detent-target" cargo build -p detent)
}

build_sill() {
  (cd "$SCEN_SRC/sill" && CARGO_TARGET_DIR="$SCEN_BUILD/sill-target" cargo build -p sill --features debug)
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

stage "casement (bootstrap --build-only)" build_casement
stage "foot" fetch_foot
stage "checkouts of sill and shell-host" checkouts
stage "sill (--features debug)" build_sill
stage "shell-host demos" build_shell_host
stage "every repo at its manifest rev" pinned
stage "detent (at its pin)" build_detent
echo "scenario-build: done ($SCEN_BUILD)"
