#!/usr/bin/env bash
# Remove exactly what install/install.sh put in place, and nothing else. A file is removed only
# when it is still what the installer wrote; one you changed is kept and named. Directories are
# left alone. An old /etc/systemd/user/casement.service (copied by an earlier version of this installer, before
# casement's own installer took over the unit) is removed only when it is byte for byte what that version shipped;
# any other file there is kept and named. Same flags as install.sh (give the same --prefix, --destdir, --sysconfdir and
# --sessions-dir you installed with).
#
#   install/uninstall.sh --dry-run    print every step, change nothing
#   install/uninstall.sh              do it
set -euo pipefail
ORIG_ARGS=("$@")
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
parse_flags "$@"
[ "$dry" = 0 ] || echo "dry run: nothing below is executed"

step "1/2 the files"
dests=()
while read -r _ _ dest; do [ ! -e "$destdir$dest" ] || dests+=("$dest"); done < <(files)
# The old casement.service: ours to remove only if unchanged.
old_unit=$(old_casement_unit)
old_unit_ours=0
if [ -f "$destdir$old_unit" ]; then
  if [ "$(sha256sum "$destdir$old_unit" | cut -d' ' -f1)" = "$OLD_CASEMENT_UNIT_SHA256" ]; then
    old_unit_ours=1
    dests+=("$old_unit")
  fi
fi
[ "${#dests[@]}" = 0 ] || need_write "${dests[@]}"
while read -r _ source dest; do
  target="$destdir$dest"
  if [ ! -e "$target" ]; then
    note "absent: $target"
  elif content "$source" | cmp -s - "$target"; then
    note "remove: $target"
    [ "$dry" = 1 ] || rm -f -- "$target"
  else
    note "kept (not what the installer wrote): $target"
  fi
done < <(files)

if [ -e "$destdir$old_unit" ]; then
  if [ "$old_unit_ours" = 1 ]; then
    note "remove: $destdir$old_unit (the copy an earlier installer made; casement's installer puts the unit under its prefix)"
    [ "$dry" = 1 ] || rm -f -- "$destdir$old_unit"
  else
    note "kept (not what the earlier installer copied): $destdir$old_unit"
  fi
fi

step "2/2 the user manager"
if [ -n "$destdir" ]; then
  note "staged under $destdir: nothing to reload"
elif [ "$dry" = 1 ]; then
  note "\$ systemctl --user daemon-reload"
else
  systemctl --user daemon-reload || note "could not reload the user manager"
fi
step "done"
