# shellcheck shell=bash
# Shared by install/install.sh and install/uninstall.sh (sourced, never run): the one list of what the
# session puts where, and the flags both take. The uninstall removes exactly this list.
#
#   --dry-run          print every step, change nothing
#   --prefix DIR       where the script and its data go (default $PREFIX, else /usr/local)
#   --destdir DIR      a staging root put in front of every path (default $DESTDIR, else none)
#   --sysconfdir DIR   where the user target goes (default $SYSCONFDIR, else /etc)
#   --sessions-dir DIR the display manager's wayland-sessions directory (default /usr/share/wayland-sessions)
#
# Never runs sudo and never writes to $HOME: a destination you cannot write is printed with the
# command to run as root, and the script stops there.

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../session" && pwd)"
prefix=${PREFIX:-/usr/local}
destdir=${DESTDIR:-}
sysconfdir=${SYSCONFDIR:-/etc}
sessions_dir=/usr/share/wayland-sessions
dry=0

die() { echo "$(basename "$0"): $*" >&2; exit "${2:-2}"; }

parse_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --prefix) prefix=${2:?--prefix needs a directory}; shift ;;
      --destdir) destdir=${2:?--destdir needs a directory}; shift ;;
      --sysconfdir) sysconfdir=${2:?--sysconfdir needs a directory}; shift ;;
      --sessions-dir) sessions_dir=${2:?--sessions-dir needs a directory}; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown argument $1" ;;
    esac
    shift
  done
  for dir in "$prefix" "$sysconfdir" "$sessions_dir"; do
    case "$dir" in /*) ;; *) die "$dir: paths must be absolute" ;; esac
  done
  prefix=${prefix%/}
  destdir=${destdir%/}
  sysconfdir=${sysconfdir%/}
  sessions_dir=${sessions_dir%/}
}

# files: "MODE SOURCE DEST" per line, DEST without the destdir. The desktop entry's SOURCE is
# rendered (Exec filled in) by render_entry; the others are copied as they are.
files() {
  echo "755 $SRC/desktop-session $prefix/bin/desktop-session"
  echo "644 $SRC/quire-portals.conf $prefix/share/xdg-desktop-portal/quire-portals.conf"
  echo "644 $SRC/desktop-session.target $sysconfdir/systemd/user/desktop-session.target"
  echo "644 $SRC/sill-casement.desktop $sessions_dir/sill-casement.desktop"
}

# content SOURCE: what is installed from SOURCE (the entry gets its Exec path).
content() {
  case "$1" in
    */sill-casement.desktop) sed "s|@BINDIR@|$prefix/bin|" "$1" ;;
    *) cat "$1" ;;
  esac
}

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# writable_for DEST: DEST (under the destdir) can be written, or created, by this user.
writable_for() {
  local path=$1
  while [ ! -e "$path" ]; do path=$(dirname "$path"); done
  [ -w "$path" ]
}

# need_write DEST...: stop with the command to run as root unless every DEST can be written.
need_write() {
  local dest bad=0
  for dest in "$@"; do
    writable_for "$destdir$dest" || { note "not writable by you: $destdir$dest"; bad=1; }
  done
  if [ "$bad" = 0 ] || [ "$dry" = 1 ]; then return 0; fi
  echo "run it with the privileges those places need, for example: sudo $0 ${ORIG_ARGS[*]}" >&2
  exit 1
}
