#!/usr/bin/env bash
# Scenario `shell-host-on-kwin` (plan §4.14, the KWin half of shell-host-on-casement-and-kwin):
# shell-host's accept scripts pass on a headless `kwin_wayland --virtual` in the jail, for the
# differential comparison with casement (plan 11 §3.4).
# Not runnable: exits 2 (SKIP), listed in gate/expected-skips.toml (FD-07), closed by P2.
# Why: plan 11 §3.4 and open question Q-T4 keep KWin differential runs "a tool, never in a gate", and
# shell-host's lifecycle script (scripts/dev/kwin-virtual.sh) cannot run in the jail as it stands: it
# writes `.kwin-env` and its logs into the checkout (read-only in the jail, and a second KWin run
# would collide with a person's own), starts a systemd user scope, and fake-input.sh builds
# tools/fake-input with cargo. The spike's jail wrapper (SP1: ~/rs-wt/spikes/casement-sp1/work) is not
# landed in shell-host. KWin leaves the harness at P2, when this row and file go.
# Contract: require_jail first, only harness/lib, exits with plan §6.1's codes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
require_jail
echo "SKIP shell-host-on-kwin: not a gate scenario (11 §3.4, Q-T4): shell-host's kwin-virtual.sh needs a writable checkout and a user scope; see FD-07" >&2
exit 2
