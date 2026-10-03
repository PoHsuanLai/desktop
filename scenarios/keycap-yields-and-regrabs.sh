#!/usr/bin/env bash
# Scenario `keycap-yields-and-regrabs` (plan §4.14): keycap Yield and re-grab around a casement crash, with a fake keycap socket; needs keycap v2
# Not runnable yet: exits 2 (SKIP), listed in gate/expected-skips.toml, closed by P4.
# Contract: require_jail first, only harness/lib, exits with plan §6.1's codes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
require_jail
echo "SKIP keycap-yields-and-regrabs: not runnable until P4 (keycap Yield and re-grab around a casement crash, with a fake keycap socket; needs keycap v2)" >&2
exit 2
