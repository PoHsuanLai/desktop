#!/usr/bin/env bash
# Scenario `minimise-target-round-trip` (plan §4.14): the minimise target round trip; needs quire_* protocols and sill's Quire backend
# Not runnable yet: exits 2 (SKIP), listed in gate/expected-skips.toml, closed by P2.
# Contract: require_jail first, only harness/lib, exits with plan §6.1's codes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
require_jail
echo "SKIP minimise-target-round-trip: not runnable until P2 (the minimise target round trip; needs quire_* protocols and sill's Quire backend)" >&2
exit 2
