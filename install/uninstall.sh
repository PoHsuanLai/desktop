#!/usr/bin/env bash
# Remove exactly what install/install.sh put in place, and nothing else. A file is removed only
# when it is still what the installer wrote; one you changed is kept and named. That includes casement.service
# and sill.service in <sysconfdir>/systemd/user, compared with the checkouts they came from (give the same --siblings; a
# unit whose checkout is gone is kept and named). Directories are left alone. Same flags as install.sh (give the same
# --prefix, --destdir, --sysconfdir, --sessions-dir and --siblings you installed with).
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
while read -r _ _ dest; do if [ -e "$destdir$dest" ]; then dests+=("$dest"); fi; done < <(files)
[ "${#dests[@]}" = 0 ] || need_write "${dests[@]}"
while read -r _ source dest; do
  target="$destdir$dest"
  if [ ! -e "$target" ]; then
    note "absent: $target"
  elif [ ! -f "$source" ]; then
    note "kept (its source $source is not here to compare with): $target"
  elif content "$source" | cmp -s - "$target"; then
    note "remove: $target"
    [ "$dry" = 1 ] || rm -f -- "$target"
  else
    note "kept (not what the installer wrote): $target"
  fi
done < <(files)

step "2/2 the user manager"
if [ -n "$destdir" ]; then
  note "staged under $destdir: nothing to reload"
elif [ "$dry" = 1 ]; then
  note "\$ systemctl --user daemon-reload"
else
  systemctl --user daemon-reload || note "could not reload the user manager"
fi
step "done"
