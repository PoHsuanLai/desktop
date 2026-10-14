#!/usr/bin/env bash
# check-cosmic-free.sh against fixtures: the clean tree passes, the tree with one offending file fails.
#   cosmic-free-selftest.sh
# Exit 0 pass, 1 a check failed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT
fail() { echo "cosmic-free-selftest: $*" >&2; exit 1; }

for kind in clean offending; do
  cp -r "$HERE/fixtures/cosmic-free/$kind" "$tmp/$kind"
  git -C "$tmp/$kind/sill" init -q || fail "git init"
done

rc=0; "$HERE/check-cosmic-free.sh" "$tmp/clean" >"$tmp/clean.out" 2>&1 || rc=$?
[ "$rc" = 0 ] || { cat "$tmp/clean.out"; fail "the clean tree must pass (exit $rc)"; }
rc=0; "$HERE/check-cosmic-free.sh" "$tmp/offending" >"$tmp/bad.out" 2>&1 || rc=$?
[ "$rc" = 1 ] || { cat "$tmp/bad.out"; fail "the offending tree must fail with 1 (exit $rc)"; }
grep -q 'sill:src/main.rs' "$tmp/bad.out" || { cat "$tmp/bad.out"; fail "the offending file is not named"; }
echo "cosmic-free-selftest: ok"
