# shellcheck shell=bash
# The faster linker some repos ask for (sourced, never run). Several repos' .cargo/config.toml say
# `linker = "clang"` with `-C link-arg=-fuse-ld=mold`, a speed setting for the people who work on them.
# A machine without clang and mold would fail at link time, so before any `cargo build` the installer
# calls use_plain_linker, which overrides that with the system linker through the environment. The repos'
# configs are not edited (the gates rely on them).
#
#   faster_linker_present        clang and mold are both on PATH (DESKTOP_FASTER_LINKER=yes|no overrides, tests)
#   plain_rustflags REPO_DIR     REPO_DIR/.cargo/config.toml's x86_64 Linux rustflags without the mold argument
#                                (one line of quoted words; empty when there is nothing else)
#   use_plain_linker REPO_DIR    export the linker override (CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=cc) and
#                                the rest of the config's rustflags (an empty value replaces the config's) when
#                                the faster linker is missing on an x86_64 machine; exit 1, changing nothing,
#                                otherwise (also when the caller already set the rustflags variable, which cargo
#                                prefers to the config anyway)
#   plain_linker_notice          one line saying the faster linker was not found, printed when it is not

host_arch() { echo "${DESKTOP_HOST_ARCH:-$(uname -m)}"; }

faster_linker_present() {
  case "${DESKTOP_FASTER_LINKER:-}" in
    yes) return 0 ;;
    no) return 1 ;;
  esac
  command -v clang >/dev/null && command -v mold >/dev/null
}

plain_rustflags() {
  local config=$1/.cargo/config.toml line word words=() kept=() i
  [ -r "$config" ] || return 0
  line=$(awk '/^\[/ { inside = ($0 == "[target.x86_64-unknown-linux-gnu]") } inside && /^rustflags/ { print; exit }' "$config")
  while IFS= read -r word; do words+=("$word"); done < <(printf '%s\n' "$line" | grep -o '"[^"]*"' | tr -d '"')
  for ((i = 0; i < ${#words[@]}; i++)); do
    case "${words[$i]}" in
      *fuse-ld=mold*) continue ;;
      -C) case "${words[$((i + 1))]:-}" in *fuse-ld=mold*) i=$((i + 1)); continue ;; esac ;;
    esac
    kept+=("${words[$i]}")
  done
  echo "${kept[*]:-}"
}

use_plain_linker() {
  faster_linker_present && return 1
  [ "$(host_arch)" = x86_64 ] || return 1
  [ -z "${RUSTFLAGS+set}" ] || return 1
  export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=cc
  RUSTFLAGS=$(plain_rustflags "$1")
  export RUSTFLAGS
}

plain_linker_notice() {
  faster_linker_present && return 0
  [ "$(host_arch)" = x86_64 ] || return 0
  echo "the faster linker (clang and mold) was not found: building with the system linker, which is slower to link and gives the same result"
}
