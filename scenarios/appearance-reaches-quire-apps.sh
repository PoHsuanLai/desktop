#!/usr/bin/env bash
# Scenario `appearance-reaches-quire-apps` (plan §4.14, the second half of appearance-reaches-apps):
# an appearance change written to `quire/appearance.toml` reaches a quire app that is not sill
# (anyview, mailo, a shell-host demo), running on the jailed casement.
# Not runnable yet: exits 2 (SKIP), listed in gate/expected-skips.toml (FD-08), closed by P1.
# Why: nothing in the jail can observe such an app's pixels. casementctl shot needs
# ext-image-copy-capture (P1-C1), and the apps (anyview, mailo) have no `debug capture` of their own.
# Once P1-C1 lands: start the app on casement, `casementctl shot --window`, write the file, compare.
# Contract: require_jail first, only harness/lib, exits with plan §6.1's codes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../harness/lib/all.sh"
require_jail
echo "SKIP appearance-reaches-quire-apps: not runnable until P1 (a quire app's pixels need casementctl shot, P1-C1; see FD-08)" >&2
exit 2
