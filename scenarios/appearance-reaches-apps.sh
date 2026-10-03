#!/usr/bin/env bash
# Scenario `appearance-reaches-apps` (plan §4.14): an appearance change through ds-settings reaches every running app; needs sill and quire apps on jailed casement
# Not runnable yet: exits 2 (SKIP), listed in gate/expected-skips.toml, closed by P0.
# Contract: require_jail first, only harness/lib, exits with plan §6.1's codes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
require_jail
echo "SKIP appearance-reaches-apps: not runnable until P0 (an appearance change through ds-settings reaches every running app; needs sill and quire apps on jailed casement)" >&2
exit 2
