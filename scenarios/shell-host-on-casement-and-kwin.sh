#!/usr/bin/env bash
# Scenario `shell-host-on-casement-and-kwin` (plan §4.14): shell-host's accept scripts pass on casement and on KWin-virtual; needs casement and SP1
# Not runnable yet: exits 2 (SKIP), listed in gate/expected-skips.toml, closed by P0.
# Contract: require_jail first, only harness/lib, exits with plan §6.1's codes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
require_jail
echo "SKIP shell-host-on-casement-and-kwin: not runnable until P0 (shell-host's accept scripts pass on casement and on KWin-virtual; needs casement and SP1)" >&2
exit 2
