# shellcheck shell=bash
# Shared by install.sh, the check mode, harness/jail.sh and gate/desktop-gate.sh (sourced, never run):
# which distro family this machine is, and who can do things as root.
#
#   distro_family [FILE]        fedora | debian | arch | other, from FILE (default $DESKTOP_OS_RELEASE,
#                               else /etc/os-release): ID and ID_LIKE decide (fedora/rhel, debian/ubuntu,
#                               arch)
#   distro_name [FILE]          the PRETTY_NAME of that file, or the family when it has none
#   escalation_program          the program that runs a command as root: $SUDO, then sudo, doas, pkexec;
#                               nothing (and exit 1) when none is installed
#   as_root_hint CMD...         the command line to type to run CMD as root, or CMD alone for root, or a
#                               plain "as root: CMD" when nothing can escalate
#   escalate CMD...             run CMD as root through escalation_program; with none, print the hint and
#                               stop (exit 1). The installers never call this on their own: they print
#                               as_root_hint and leave the step to the person.

distro_family() {
  local file=${1:-${DESKTOP_OS_RELEASE:-/etc/os-release}} ids
  [ -r "$file" ] || { echo other; return 0; }
  ids=$( (ID='' ID_LIKE=''; . "$file" >/dev/null 2>&1; printf '%s %s' "${ID:-}" "${ID_LIKE:-}") )
  case " $ids " in
    *" fedora "* | *" rhel "* | *" centos "*) echo fedora ;;
    *" debian "* | *" ubuntu "*) echo debian ;;
    *" arch "* | *" archlinux "*) echo arch ;;
    *) echo other ;;
  esac
}

distro_name() {
  local file=${1:-${DESKTOP_OS_RELEASE:-/etc/os-release}} name=
  [ ! -r "$file" ] || name=$( (PRETTY_NAME=''; . "$file" >/dev/null 2>&1; printf '%s' "${PRETTY_NAME:-}") )
  echo "${name:-$(distro_family "$file")}"
}

escalation_program() {
  local candidate
  if [ -n "${SUDO:-}" ]; then echo "$SUDO"; return 0; fi
  for candidate in sudo doas pkexec; do
    if command -v "$candidate" >/dev/null; then echo "$candidate"; return 0; fi
  done
  return 1
}

as_root_hint() {
  local program
  if [ "$(id -u)" = 0 ]; then
    printf '%q ' "$@"; echo
  elif program=$(escalation_program); then
    printf '%s ' "$program"; printf '%q ' "$@"; echo
  else
    printf 'as root: '; printf '%q ' "$@"; echo
  fi
}

escalate() {
  local program
  if [ "$(id -u)" = 0 ]; then "$@"; return; fi
  if program=$(escalation_program); then
    # pkexec wants an absolute path to the program; the others take a name.
    case "$program" in
      pkexec | */pkexec) "$program" "$(command -v "$1")" "${@:2}" ;;
      # shellcheck disable=SC2086  # $SUDO may be a program with options, such as "sudo -n"
      *) $program "$@" ;;
    esac
    return
  fi
  echo "nothing here can run commands as root (no sudo, doas or pkexec). Run this yourself, as root:" >&2
  printf '  %q' "$@" >&2; echo >&2
  return 1
}
