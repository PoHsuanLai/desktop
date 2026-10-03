#!/usr/bin/env bash
# Scenario `sill-boots-on-casement` (plan §4.14): sill boots on casement headless; needs the casement binary (S1)
# Not runnable yet: exits 2 (SKIP), listed in gate/expected-skips.toml, closed by P0.
# Contract: require_jail first, only harness/lib, exits with plan §6.1's codes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
require_jail
echo "SKIP sill-boots-on-casement: not runnable until P0 (sill boots on casement headless; needs the casement binary (S1))" >&2
exit 2
