#!/usr/bin/env bash
# Install the "sill (casement)" session: the session script, the portal choice for the quire
# desktop, the user target, casement.service (from the casement
# repo's dist/, when that sibling checkout has it) and the login-screen entry. Run as yourself; it never runs sudo (a
# destination you cannot write stops it with the command to run as root). Safe to run again.
#
#   install/install.sh --dry-run    print every step, change nothing
#   install/install.sh              do it
#   (flags: see install/lib.sh)
#
# Not installed here: casement, sill and xdg-desktop-portal-wlr themselves (their own installers
# and packages), other sessions (left untouched), and
# anything under $HOME. install/uninstall.sh removes exactly the files listed below.
set -euo pipefail
ORIG_ARGS=("$@")
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
parse_flags "$@"
[ "$dry" = 0 ] || echo "dry run: nothing below is executed"

step "1/3 checks"
for tool in casement sill; do
  command -v "$tool" >/dev/null || note "WARNING: $tool is not on PATH; the session cannot start without it"
done
[ -f "$casement_unit" ] || note "WARNING: no casement unit at $casement_unit (build the casement repo's dist/casement.service, or set CASEMENT_UNIT_FILE); the session needs casement.service and will not start casement without it"
[ -x /usr/libexec/xdg-desktop-portal-wlr ] || note "WARNING: /usr/libexec/xdg-desktop-portal-wlr is missing (dnf install xdg-desktop-portal-wlr)"

step "2/3 the files"
dests=()
while read -r _ _ dest; do dests+=("$dest"); done < <(files)
need_write "${dests[@]}"
while read -r mode source dest; do
  note "$destdir$dest ($mode)"
  [ "$dry" = 1 ] || {
    install -d "$(dirname "$destdir$dest")"
    content "$source" | install -m "$mode" /dev/stdin "$destdir$dest"
  }
done < <(files)

step "3/3 the user manager"
if [ -n "$destdir" ]; then
  note "staged under $destdir: nothing to reload"
elif [ "$dry" = 1 ]; then
  note "\$ systemctl --user daemon-reload"
else
  systemctl --user daemon-reload || note "could not reload the user manager; log out and in"
fi

step "done"
note "Pick \"sill (casement)\" at the login screen. First-login checks (not testable without a login):"
note "  the guard's real tty path, sill and the wlr portal against the real casement, the target, casement.service"
note "  the activation environment, a screen share through the wlr portal, logout through sill's power menu."
