#!/usr/bin/env bash
# release/selftest.sh: packs a tiny fake stage in a scratch directory with a throwaway key and verifies it,
# then checks that verify.sh refuses hostile releases (each signed and otherwise consistent): a file in the
# bundle that release.toml does not list, a wrong file digest, a wrong bundle size, a symlink, a `..` path,
# an absolute path, a setuid or group-writable mode, a `.slipway` path, an export outside the allowed directories,
# an export to a folder or to a file that is not in the bundle, a system file outside the allowed system folders or
# below one (or in /etc/xdg beside quire), in an allowed folder but named by no rule, unlisted, or without contents in the bundle, a bad version (leading zero), a date that is not a
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
printf 'ACTION=="add"\n' >"$top/system/etc/udev/rules.d/70-keycap.rules"
printf 'font\n' >"$top/share/fonts/quire/Noto-COLRv1.ttf"
printf 'i2c-dev\n' >"$top/system/etc/modules-load.d/sill-ddc.conf"
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
grep -q 'path = "/etc/modules-load.d/sill-ddc.conf"' "$tmp/a/release.toml" || check "the modules-load file is not listed as a system file"
grep -q 'path = "/etc/xdg/quire/fake.toml"' "$tmp/a/release.toml" || check "a system file in /etc/xdg/quire is not accepted and listed"
grep -q 'path = "/etc/udev/rules.d/70-keycap.rules"' "$tmp/a/release.toml" || check "the system file is not listed"
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
# ... and a system file no rule of system-files.list names (a polkit rule in an allowed folder, a file beside the
# named one in another) fails the pack: slipway would refuse the whole release.
for stray in etc/polkit-1/rules.d/00-all.rules etc/pam.d/other etc/udev/rules.d/99-unnamed.rules etc/quire/callers.toml; do
  mkdir -p "$top/system/$(dirname "$stray")"; printf 'x\n' >"$top/system/$stray"
  pack "$tmp/c" >/dev/null 2>&1 && check "pack accepted the unnamed system file /$stray"
  rm -f "$top/system/$stray"
done
rmdir "$top/system/etc/polkit-1/rules.d" "$top/system/etc/polkit-1" "$top/system/etc/pam.d" "$top/system/etc/quire" 2>/dev/null || true
pack "$tmp/c2" >/dev/null 2>&1 || check "pack no longer works after the unnamed files were taken away"

# The committed list is slipway's: the same text in slipway's format passes, one rule missing or added does not.
rust="$tmp/slipway/crates/slipway-core/src/release/system.rs"
mkdir -p "$(dirname "$rust")"
render() { # LIST-FILTER-AWK: the list as slipway's Rust, optionally changed by an awk program on the rule lines
  { echo "pub const ALLOWED_SYSTEM_FILES: [SystemRule; 13] = ["
    grep -v '^#' "$HERE/system-files.list" | grep . | awk "$1" | awk '{ k = ($2 == "exact") ? "Exact" : "Ending"; printf "    // %s\n    rule(\"%s\", NameRule::%s(\"%s\")),\n", $3, $1, k, $3 }'
    echo "];"; } >"$rust"
}
render '{ print }'
"$HERE/check-system-list.sh" --slipway "$tmp/slipway" >/dev/null || check "the list does not match slipway's own text"
render 'NR != 4 { print }'
"$HERE/check-system-list.sh" --slipway "$tmp/slipway" >/dev/null 2>&1 && check "a rule slipway does not have was not noticed"
render '{ print } END { print "/etc/polkit-1/rules.d exact 00-all.rules" }'
"$HERE/check-system-list.sh" --slipway "$tmp/slipway" >/dev/null 2>&1 && check "a rule only slipway has was not noticed"

# The forger itself is sound: with no fault, its release verifies (so a refusal above is for the fault).
python3 -I "$HERE/selftest-forge.py" "$tmp/h-good" good "$tmp/key.sec" && "$HERE/verify.sh" "$tmp/h-good" --pubkey "$tmp/key.pub" >/dev/null || check "the forger's fault-free release does not verify"
python3 -I "$HERE/selftest-forge.py" "$tmp/h-system-good" system-good "$tmp/key.sec" && "$HERE/verify.sh" "$tmp/h-system-good" --pubkey "$tmp/key.pub" >/dev/null || check "the forger's release with a system file does not verify"
for hostile in extra digest size symlink dotdot absolute setuid export export-dir export-target tamper reserved mode-writable mode-unreadable version-zero version-pre date notes-big notes-del legacy system-dir system-xdg-other system-unnamed system-nested system-unlisted system-nosource; do
  python3 -I "$HERE/selftest-forge.py" "$tmp/h-$hostile" "$hostile" "$tmp/key.sec" || { check "could not forge $hostile"; continue; }
  if "$HERE/verify.sh" "$tmp/h-$hostile" --pubkey "$tmp/key.pub" >/dev/null 2>&1; then check "verify accepted the hostile release '$hostile'"; fi
done

# slipway's install is checked as a whole: three programs and one polkit file with three actions (installing and the
# good-start note need no password at the keyboard, going back asks for the administrator's).
h="$tmp/helpers"
mkdir -p "$h/usr/libexec" "$h/usr/share/polkit-1/actions"
for p in apply rollback health; do printf '#!/bin/sh\n' >"$h/usr/libexec/slipway-$p"; chmod 755 "$h/usr/libexec/slipway-$p"; done
policy() { # ACTIVE-FOR-ROLLBACK
  { echo '<policyconfig>'
    for p in apply rollback health; do
      active=yes; [ "$p" != rollback ] || active=$1
      printf '<action id="org.quire.slipway.%s"><defaults><allow_any>no</allow_any><allow_inactive>no</allow_inactive><allow_active>%s</allow_active></defaults><annotate key="org.freedesktop.policykit.exec.path">/usr/libexec/slipway-%s</annotate></action>\n' "$p" "$active" "$p"
    done
    echo '</policyconfig>'; } >"$h/usr/share/polkit-1/actions/org.quire.slipway.policy"
}
policy auth_admin_keep
"$HERE/check-helpers.sh" --root "$h" >/dev/null 2>&1 || check "a complete slipway install is not accepted"
policy yes
"$HERE/check-helpers.sh" --root "$h" >/dev/null 2>&1 && check "a rollback that needs no password was accepted"
policy auth_admin_keep
rm "$h/usr/libexec/slipway-health"
"$HERE/check-helpers.sh" --root "$h" >/dev/null 2>&1 && check "a missing slipway-health was accepted"
printf '#!/bin/sh\n' >"$h/usr/libexec/slipway-health"; chmod 775 "$h/usr/libexec/slipway-health"
"$HERE/check-helpers.sh" --root "$h" >/dev/null 2>&1 && check "a group-writable slipway-health was accepted"

# Each build job supplies only its own paths (stage-owners.list): a tar with a path outside its job's lines, a path two jobs
# both supply, a link, a path outside the stage or a job nobody knows is refused; a tar of the right shape passes.
so="$tmp/owners"; mkdir -p "$so"
mk_tar() { # JOB PATH...: stage-JOB.tar of those files, each below stage/opt/quire/current (or components.d/NAME.txt)
  local job=$1 d p; shift; d="$so/$job"; rm -rf -- "${d:?}"; mkdir -p "$d/components.d" "$d/stage/opt/quire/current"
  for p in "$@"; do
    case "$p" in
      components.d/*) printf x >"$d/$p" ;;
      *) mkdir -p "$d/stage/opt/quire/current/$(dirname "$p")"; printf x >"$d/stage/opt/quire/current/$p" ;;
    esac
  done
  tar -C "$d" -cf "$so/stage-$job.tar" stage components.d
}
owners() { python3 -I "$HERE/stage-owners.py" check "$HERE/stage-owners.list" "$@"; }
mk_tar root components.d/turnstile.txt bin/turnstile bin/keycap system/usr/lib/systemd/system/turnstile.service system/etc/udev/rules.d/72-turnstile.rules
mk_tar small bin/slipway bin/detent system/etc/quire/desktop-callers.toml components.d/desktop.txt
mk_tar mailo bin/mailo share/quire/skills/mail/SKILL.md
owners "$so"/stage-root.tar "$so"/stage-small.tar "$so"/stage-mailo.tar >/dev/null 2>&1 || check "the stage tars of the right shape were refused"
for bad in bin/turnstile bin/keycap system/usr/lib/systemd/system/turnstile.service system/usr/lib/systemd/system/keycap.service \
  system/etc/udev/rules.d/72-turnstile.rules system/etc/quire/desktop-callers.toml system/etc/polkit-1/rules.d/00-all.rules bin/anything; do
  for job in mailo anyview casement sill porter agents small; do
    [ "$job" = small ] && case "$bad" in system/etc/quire/desktop-callers.toml) continue ;; esac
    mk_tar "$job" "$bad"
    owners "$so/stage-$job.tar" >/dev/null 2>&1 && check "job $job was allowed to supply $bad"
  done
done
mk_tar sill share/quire/intents/org.quire.Shell.toml
mk_tar anyview share/quire/intents/org.quire.Shell.toml
owners "$so/stage-sill.tar" >/dev/null 2>&1 || check "sill alone was refused the path it owns"
owners "$so/stage-sill.tar" "$so/stage-anyview.tar" >/dev/null 2>&1 && check "a path supplied by two jobs was accepted"
mk_tar mailo bin/mailo; ln -s mailo "$so/mailo/stage/opt/quire/current/bin/link"; tar -C "$so/mailo" -cf "$so/stage-mailo.tar" stage components.d
owners "$so/stage-mailo.tar" >/dev/null 2>&1 && check "a link in a stage tar was accepted"
mk_tar mailo bin/mailo; mkdir -p "$so/mailo/etc"; printf x >"$so/mailo/etc/passwd"; tar -C "$so/mailo" -cf "$so/stage-mailo.tar" stage components.d etc
owners "$so/stage-mailo.tar" >/dev/null 2>&1 && check "a path outside the stage was accepted"
mk_tar rogue bin/mailo
owners "$so/stage-rogue.tar" >/dev/null 2>&1 && check "the tar of a job nobody knows was accepted"
# The job names in the list are the matrix of the workflow, no more and no fewer.
python3 -I "$HERE/stage-owners.py" jobs "$HERE/stage-owners.list" >"$tmp/jobs.list"
grep -o '{ name: [a-z]*, only' "$HERE/../.github/workflows/release.yml" | sed 's/{ name: //; s/, only//' | sort >"$tmp/matrix.list"
cmp -s "$tmp/jobs.list" "$tmp/matrix.list" || check "stage-owners.list and the build matrix of release.yml name different jobs: $(tr '\n' ' ' <"$tmp/jobs.list") / $(tr '\n' ' ' <"$tmp/matrix.list")"

[ "$fail" = 0 ] || exit 1
echo "release selftest: pass (deterministic pack, verify, 26 hostile releases refused)"
