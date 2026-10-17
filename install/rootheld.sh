# shellcheck shell=bash
# Shared by install.sh and install/system.sh (sourced, never run): who can replace a program that root runs.
#
#   not_root_held DIR   prints why DIR cannot be trusted to hold a program that root runs, and returns 0; prints nothing and
#                       returns 1 when it can. DIR and every folder above it, up to /, must be owned by root and not
#                       writable by its group or by everybody (symbolic links are followed first). A folder that does not exist
#                       yet is judged by its nearest folder that does, since that is where it would be made.
#
# Why: a unit that root starts (the input service, the keyboard map) names a program. If the person can replace that
# program, or any folder on the way to it, they run their own code as root at the next start. A prefix such as ~/.local is
# such a place: the person owns it.

not_root_held() {
  local path mode owner
  path=$(realpath -m -- "$1") || { echo "$1 cannot be resolved"; return 0; }
  while [ ! -e "$path" ]; do path=$(dirname "$path"); done
  while :; do
    owner=$(stat -c %u -- "$path") && mode=$(stat -c %a -- "$path") || { echo "$path cannot be inspected"; return 0; }
    if [ "$owner" != 0 ]; then echo "$path is not owned by root"; return 0; fi
    if [ $((8#$mode & 8#022)) != 0 ]; then echo "$path can be written by someone other than root"; return 0; fi
    [ "$path" != / ] || return 1
    path=$(dirname "$path")
  done
}
