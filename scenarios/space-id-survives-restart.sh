#!/usr/bin/env bash
# Scenario `space-id-survives-restart` (plan §4.14): a Space id is stable across a casement restart; needs casement Spaces persistence
# Not runnable yet: exits 2 (SKIP), listed in gate/expected-skips.toml, closed by P1.
# Contract: require_jail first, only harness/lib, exits with plan §6.1's codes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
require_jail
echo "SKIP space-id-survives-restart: not runnable until P1 (a Space id is stable across a casement restart; needs casement Spaces persistence)" >&2
exit 2
