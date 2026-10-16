# shellcheck shell=bash
# install.sh --check (sourced, never run): does this machine have what the desktop needs, and if not, the exact
# line to install it. Reads the needs from install/packages.sh; changes nothing.
#
#   run_check [--runtime-only]   print what is missing per group and the install line for it; exit 0 when
#                                everything needed to run (and, unless --runtime-only, to build) is there,
#                                1 otherwise. What is only recommended never changes the exit.
#
# Overrides, for tests: DESKTOP_OS_RELEASE (the os-release file), DESKTOP_CHECK_ROOT (put in front of every
# file: check), DESKTOP_LDCONFIG (the ldconfig program), PATH.

RUSTUP_LINE="curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"

# lib_cached SONAME: the linker cache lists the library.
lib_cached() {
  local program=${DESKTOP_LDCONFIG:-} listing
  if [ -z "$program" ]; then
    program=$(command -v ldconfig 2>/dev/null || true)
    [ -n "$program" ] || for program in /sbin/ldconfig /usr/sbin/ldconfig; do [ -x "$program" ] && break; done
  fi
  [ -x "$program" ] || return 1
  listing=$("$program" -p 2>/dev/null || true)
  case "$listing" in *$'\t'"$1 "*) return 0 ;; esac
  return 1
}

# check_alt KIND:ARG: one alternative of a check (the kinds are listed in packages.sh).
check_alt() {
  local kind=${1%%:*} arg=${1#*:} out
  case "$kind" in
    cmd) command -v "$arg" >/dev/null ;;
    pc) command -v pkg-config >/dev/null && pkg-config --exists "$arg" ;;
    lib) lib_cached "$arg" ;;
    file) compgen -G "${DESKTOP_CHECK_ROOT:-}$arg" >/dev/null ;;
    unit)
      command -v systemctl >/dev/null || return 1
      out=$(systemctl list-unit-files "$arg" --no-legend 2>/dev/null || true)
      [ -n "$out" ] ;;
    deb) command -v dpkg >/dev/null || return 0; dpkg -s "$arg" >/dev/null 2>&1 ;;
    lang)
      command -v fc-list >/dev/null || return 1
      out=$(fc-list ":lang=$arg" 2>/dev/null || true)
      [ -n "$out" ] ;;
    *) return 1 ;;
  esac
}

# file: alternatives continue on the same line without repeating the kind: "file:/a /b" means two files.
expand_alternatives() {
  local word kind=cmd
  set -f # the words are glob patterns: keep them as they are
  for word in $1; do
    case "$word" in
      cmd:* | pc:* | lib:* | file:* | unit:* | deb:* | lang:*) kind=${word%%:*}; echo "$word" ;;
      *) echo "$kind:$word" ;;
    esac
  done
  set +f
}

# missing_keys GROUP FAMILY: the keys of GROUP whose check fails (and that apply on FAMILY, "other" meaning all).
missing_keys() {
  local group=$1 family=$2 g key check alt ok applies fam
  while read -r g key check; do
    [ "$g" = "$group" ] || continue
    applies=0
    if [ "$family" = other ]; then
      for fam in fedora debian arch; do [ "$("packages_$fam" "$key")" = - ] || applies=1; done
    else
      [ "$("packages_$family" "$key")" = - ] || applies=1
    fi
    [ "$applies" = 1 ] || continue
    ok=0
    while read -r alt; do
      check_alt "$alt" && { ok=1; break; }
    done < <(expand_alternatives "$check")
    [ "$ok" = 1 ] || echo "$key"
  done < <(need_table)
}

# report_group TITLE GROUP FAMILY: print the missing needs of one group and how to install them; exit 1 if any.
report_group() {
  local title=$1 group=$2 family=$3 keys=() key notes=() note fam names pkgs=()
  mapfile -t keys < <(missing_keys "$group" "$family")
  echo
  echo "$title"
  if [ "${#keys[@]}" = 0 ]; then
    echo "  all there"
    return 0
  fi
  for key in "${keys[@]}"; do echo "  missing: $key"; done
  case "$family" in other) names=(fedora debian arch) ;; *) names=("$family") ;; esac
  for fam in "${names[@]}"; do
    mapfile -t pkgs < <(family_packages "$fam" "${keys[@]}")
    if [ "${#pkgs[@]}" -gt 0 ]; then
      [ "$family" != other ] || printf '  %s: ' "$fam"
      [ "$family" = other ] || printf '  '
      install_line "$fam" "${pkgs[@]}"
    fi
    mapfile -t notes < <(family_notes "$fam" "${keys[@]}")
    for note in "${notes[@]}"; do [ -z "$note" ] || echo "  note: $note"; done
  done
  return 1
}

run_check() {
  local runtime_only=0 family rc=0
  case "${1:-}" in
    --runtime-only) runtime_only=1 ;;
    "") ;;
    *) echo "install.sh --check: unknown option $1" >&2; return 2 ;;
  esac
  family=$(distro_family)
  echo "desktop check: $(distro_name) ($family family)"
  report_group "needed to run" runtime "$family" || rc=1
  if [ "$runtime_only" = 0 ]; then
    echo
    echo "needed to build from source (not for a prebuilt install; --runtime-only skips this)"
    if command -v rustup >/dev/null; then
      echo "  rustup: found"
    else
      echo "  missing: rustup. The repos pin Rust 1.98.1, which only rustup installs for you; your distro's rust package is the wrong version."
      echo "    $RUSTUP_LINE"
      rc=1
    fi
    report_group "build libraries and tools" build "$family" || rc=1
  fi
  report_group "recommended (a feature is missing without it)" recommended "$family" || true
  echo
  [ "$rc" = 0 ] && echo "ready" || echo "not ready: install what is missing above and run --check again"
  return "$rc"
}
