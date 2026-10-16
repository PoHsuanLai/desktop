# Shared by the release scripts (sourced, not run): which kind of Linux this is, and the one line a person
# pastes to install a missing tool. Package names: REPORT.md section 2 of the distro audit.
#
#   release_family   prints fedora, debian, arch or unknown, from /etc/os-release (ID, then ID_LIKE);
#                    $OS_RELEASE_FILE names another file, for tests
#   install_hint T...  prints "sudo dnf install ..." / "sudo apt install ..." / "sudo pacman -S ..." for the
#                    logical tools curl python3 zstd minisign polkit; on an unknown system, all three lines

release_family() {
  local file="${OS_RELEASE_FILE:-/etc/os-release}" id="" like="" word
  [ -r "$file" ] || { echo unknown; return 0; }
  id=$(sed -n 's/^ID=//p' "$file" | head -n 1 | tr -d '"')
  like=$(sed -n 's/^ID_LIKE=//p' "$file" | head -n 1 | tr -d '"')
  for word in $id $like; do
    case "$word" in
      fedora|rhel|centos|rocky|almalinux) echo fedora; return 0 ;;
      debian|ubuntu) echo debian; return 0 ;;
      arch|manjaro|endeavouros) echo arch; return 0 ;;
    esac
  done
  echo unknown
}

# package_for FAMILY TOOL: the package(s) that provide a logical tool.
package_for() {
  case "$1:$2" in
    arch:python3) echo python ;;
    arch:polkit|fedora:polkit) echo polkit ;;
    debian:mount|debian:umount) echo mount ;;
    *:mount|*:umount) echo util-linux ;;
    debian:polkit) echo "polkitd pkexec" ;;
    *:minisign) echo minisign ;;  # Ubuntu 24.04 has it in universe (unverified); Fedora and Arch in the main repos
    *) echo "$2" ;;
  esac
}

install_hint() {
  local family tool packages="" f
  family=$(release_family)
  for f in ${family/unknown/fedora debian arch}; do
    packages=""
    for tool in "$@"; do packages="$packages $(package_for "$f" "$tool")"; done
    case "$f" in
      fedora) printf 'sudo dnf install%s' "$packages" ;;
      debian) printf 'sudo apt install%s' "$packages" ;;
      arch) printf 'sudo pacman -S%s' "$packages" ;;
    esac
    [ "$family" != unknown ] || [ "$f" = arch ] || printf '; or '
  done
}
