#!/usr/bin/env bash
# release/selftest.sh: packs a tiny fake stage in a scratch directory with a throwaway key and verifies it,
# then checks that verify.sh refuses hostile releases (each signed and otherwise consistent): a file in the
# bundle that release.toml does not list, a wrong file digest, a wrong bundle size, a symlink, a `..` path,
# an absolute path, a setuid or group-writable mode, a `.slipway` path, an export outside the allowed directories,
# an export to a folder or to a file that is not in the bundle, a system file outside the allowed system folders or
# below one (or in /etc/xdg beside quire), unlisted, or without contents in the bundle, a bad version (leading zero), a date that is not a
# real time, notes over 16 KiB, a raw DEL in the notes, a legacy (not prehashed) signature, and a release.toml
# changed after signing. The bundle and file-count limits are not forged (too big for a test). Packing the same stage twice gives the same bundle.
#
#   release/selftest.sh
# Exit: 0 pass, 1 a check failed, 2 skipped (minisign, zstd or python3 is not installed).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release/lib.sh
. "$HERE/lib.sh"
for tool in minisign zstd python3; do
  command -v "$tool" >/dev/null || { echo "release selftest: SKIP, $tool is not installed ($(install_hint "$tool"))"; exit 2; }
done
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT
fail=0
check() { echo "FAIL release selftest: $*" >&2; fail=1; }

top="$tmp/stage/opt/quire/current"
mkdir -p "$top/bin" "$top/share/wayland-sessions" "$top/lib/systemd/user" "$top/share/quire" "$top/share/fonts/quire" "$top/system/etc/udev/rules.d" "$top/system/etc/modules-load.d" "$top/system/etc/xdg/quire"
printf '#!/bin/sh\necho hi\n' >"$top/bin/tool"; chmod 755 "$top/bin/tool"
printf '[Desktop Entry]\nName=Quire\n' >"$top/share/wayland-sessions/quire.desktop"
printf '[Service]\nExecStart=/opt/quire/current/bin/tool\n' >"$top/lib/systemd/user/tool.service"
printf 'data\n' >"$top/share/quire/data.txt"; chmod 600 "$top/share/quire/data.txt"
printf 'ACTION=="add"\n' >"$top/system/etc/udev/rules.d/70-fake.rules"
printf 'font\n' >"$top/share/fonts/quire/Noto-COLRv1.ttf"
printf 'i2c-dev\n' >"$top/system/etc/modules-load.d/fake-ddc.conf"
printf 'x = 1\n' >"$top/system/etc/xdg/quire/fake.toml"
printf 'A fake release.\n' >"$tmp/notes.txt"
printf '[[export]]\nlink = "/usr/local/bin/tool"\ntarget = "bin/tool"\n' >"$tmp/exports.toml"
minisign -G -W -p "$tmp/key.pub" -s "$tmp/key.sec" >/dev/null

pack() { # OUT
  MINISIGN_KEY_FILE="$tmp/key.sec" MINISIGN_PASSWORD="" SOURCE_DATE_EPOCH=1790000000 \
    "$HERE/pack.sh" --stage "$tmp/stage" --version 1.2.3 --notes "$tmp/notes.txt" --out "$1" --exports "$tmp/exports.toml"
}
pack "$tmp/a" >/dev/null || check "pack failed"
"$HERE/verify.sh" "$tmp/a" --pubkey "$tmp/key.pub" >/dev/null || check "a good release does not verify"
pack "$tmp/b" >/dev/null || check "second pack failed"
cmp -s "$tmp/a/bundle.tar.zst" "$tmp/b/bundle.tar.zst" || check "the bundle is not deterministic"
grep -q 'link = "/usr/share/wayland-sessions/quire.desktop"' "$tmp/a/release.toml" || check "the session entry is not exported"
grep -q 'link = "/usr/lib/systemd/user/tool.service"' "$tmp/a/release.toml" || check "the unit is not exported"
grep -q 'link = "/usr/share/quire/data.txt"' "$tmp/a/release.toml" || check "share/quire is not exported"
grep -q 'link = "/usr/share/fonts/quire/Noto-COLRv1.ttf"' "$tmp/a/release.toml" || check "the emoji font is not exported"
grep -q 'path = "/etc/modules-load.d/fake-ddc.conf"' "$tmp/a/release.toml" || check "the modules-load file is not listed as a system file"
grep -q 'path = "/etc/xdg/quire/fake.toml"' "$tmp/a/release.toml" || check "a system file in /etc/xdg/quire is not accepted and listed"
grep -q 'path = "/etc/udev/rules.d/70-fake.rules"' "$tmp/a/release.toml" || check "the system file is not listed"
grep -q 'target = "system/' "$tmp/a/release.toml" && check "a system file was exported as a link"
grep -q 'path = "share/quire/data.txt"' "$tmp/a/release.toml" && grep -q 'mode = 0o644' "$tmp/a/release.toml" || check "modes are not normalised"
"$HERE/verify.sh" "$tmp/a" --pubkey "$tmp/a/../key.sec" >/dev/null 2>&1 && check "verify accepted a wrong public key"

# Notes with a DEL are escaped, so they still verify.
printf 'a\177b\n' >"$tmp/notes-del.txt"
MINISIGN_KEY_FILE="$tmp/key.sec" "$HERE/pack.sh" --stage "$tmp/stage" --version 1.2.3 --notes "$tmp/notes-del.txt" --out "$tmp/d" --exports "$tmp/exports.toml" >/dev/null &&
  "$HERE/verify.sh" "$tmp/d" --pubkey "$tmp/key.pub" >/dev/null || check "notes with a DEL do not pack and verify"

# The pack itself refuses a symlink in the stage and a file outside opt/quire/current.
ln -s tool "$top/bin/link"
pack "$tmp/c" >/dev/null 2>&1 && check "pack accepted a symlink"
rm "$top/bin/link"
mkdir "$tmp/stage/etc"
pack "$tmp/c" >/dev/null 2>&1 && check "pack accepted a file outside opt/quire/current"
rmdir "$tmp/stage/etc"

# The forger itself is sound: with no fault, its release verifies (so a refusal above is for the fault).
python3 -I "$HERE/selftest-forge.py" "$tmp/h-good" good "$tmp/key.sec" && "$HERE/verify.sh" "$tmp/h-good" --pubkey "$tmp/key.pub" >/dev/null || check "the forger's fault-free release does not verify"
python3 -I "$HERE/selftest-forge.py" "$tmp/h-system-good" system-good "$tmp/key.sec" && "$HERE/verify.sh" "$tmp/h-system-good" --pubkey "$tmp/key.pub" >/dev/null || check "the forger's release with a system file does not verify"
for hostile in extra digest size symlink dotdot absolute setuid export export-dir export-target tamper reserved mode-writable mode-unreadable version-zero version-pre date notes-big notes-del legacy system-dir system-xdg-other system-nested system-unlisted system-nosource; do
  python3 -I "$HERE/selftest-forge.py" "$tmp/h-$hostile" "$hostile" "$tmp/key.sec" || { check "could not forge $hostile"; continue; }
  if "$HERE/verify.sh" "$tmp/h-$hostile" --pubkey "$tmp/key.pub" >/dev/null 2>&1; then check "verify accepted the hostile release '$hostile'"; fi
done

[ "$fail" = 0 ] || exit 1
echo "release selftest: pass (deterministic pack, verify, 25 hostile releases refused)"
