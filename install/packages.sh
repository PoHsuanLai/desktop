# shellcheck shell=bash
# The one package table (sourced, never run): what the desktop needs on the machine, and what each
# distro family calls it. install.sh --check, the harness and the gate all print their install hints from
# here. Needs and names come from the distro audit (~/rs-wt/distro-audit/REPORT.md, section 2).
#
# need_table prints one need per line: GROUP KEY CHECK. The check is one or more alternatives, any of which
# satisfies it:
#   cmd:NAME     a program on PATH
#   pc:NAME      a pkg-config module
#   lib:SONAME   a shared library in the linker cache
#   file:GLOB    a path (a glob; $DESKTOP_CHECK_ROOT, when set, goes in front: tests)
#   unit:NAME    a systemd unit file
#   deb:NAME     an installed Debian package (satisfied where there is no dpkg)
#   lang:CODE    a font that covers a language
# Groups: runtime (the session does not work without it), build (source builds only), recommended (a feature
# is missing without it), gate (the test harness).
#
# One function per family gives the package words for a key: fedora, debian (Ubuntu too), arch. A word list,
# "-" (does not apply on this family), or "!TEXT" (no package: TEXT says what to do instead). A name written
# from memory and not checked on the distro carries the comment "# unverified".
#
#   family_packages FAMILY KEY...   the packages for those keys, each once, in order
#   family_notes FAMILY KEY...      the "!TEXT" lines for those keys
#   install_line FAMILY PKG...      the command to install them (through the escalation program)
#   install_hint KEY...             the install line(s) for this machine's family: one line, or one per
#                                   family when the family is not known

# xwayland-satellite on Ubuntu (not in the archive): the tag the release bundle builds (release/build.sh SATELLITE_TAG; keep
# them the same) and the two lines that give a source install the same program.
XWAYLAND_SATELLITE_TAG=v0.8.3
XWAYLAND_SATELLITE_CARGO_LINE="cargo install --locked --git https://github.com/Supreeeme/xwayland-satellite --tag $XWAYLAND_SATELLITE_TAG"
# casement's own setting for the program's place (xwayland.satellite in casement/settings.toml): a full path, no ~.
XWAYLAND_SATELLITE_CONFIG_LINE="satellite = \"${HOME:-/home/YOU}/.cargo/bin/xwayland-satellite\""
XWAYLAND_SATELLITE_APT_LINE="sudo apt install clang pkg-config libxcb1-dev libxcb-composite0-dev libxcb-randr0-dev libxcb-res0-dev libxcb-cursor-dev"

need_table() {
  cat <<'TABLE'
runtime user-bus          deb:dbus-user-session
runtime polkit            cmd:pkexec
runtime portal            file:/usr/libexec/xdg-desktop-portal /usr/lib/xdg-desktop-portal /usr/lib/*/xdg-desktop-portal
runtime portal-gtk        file:/usr/libexec/xdg-desktop-portal-gtk /usr/lib/xdg-desktop-portal-gtk /usr/lib/*/xdg-desktop-portal-gtk
runtime xwayland          cmd:Xwayland
runtime secrets           cmd:gnome-keyring-daemon cmd:ksecretd file:/usr/share/dbus-1/services/org.freedesktop.secrets.service
runtime bwrap             cmd:bwrap
runtime curl              cmd:curl
runtime xdg-open          cmd:xdg-open
runtime vulkan-loader     lib:libvulkan.so.1
runtime vulkan-driver     file:/usr/share/vulkan/icd.d/*.json /etc/vulkan/icd.d/*.json
recommended xwayland-satellite cmd:xwayland-satellite
recommended pipewire      cmd:pipewire
recommended pipewire-pulse cmd:pipewire-pulse
recommended wireplumber   cmd:wireplumber
recommended network-manager unit:NetworkManager.service
recommended bluez         unit:bluetooth.service
recommended upower        unit:upower.service
recommended power-profiles unit:power-profiles-daemon.service
recommended accounts-service unit:accounts-daemon.service
recommended ddcutil       cmd:ddcutil
recommended at-spi        file:/usr/libexec/at-spi-bus-launcher /usr/libexec/at-spi2-core/at-spi-bus-launcher /usr/lib/at-spi-bus-launcher /usr/lib/at-spi2-core/at-spi-bus-launcher
recommended input-method  cmd:fcitx5 cmd:ibus-daemon
recommended packagekit    unit:packagekit.service
recommended cjk-fonts     lang:ja
build   cc                cmd:cc
build   make              cmd:make
build   cmake             cmd:cmake
build   pkg-config        cmd:pkg-config
build   libclang          file:/usr/lib64/libclang.so* /usr/lib/libclang.so* /usr/lib/*/libclang.so* /usr/lib/*/libclang-*.so* /usr/lib/llvm-*/lib/libclang*.so*
build   perl              cmd:perl
build   git               cmd:git
build   curl              cmd:curl
build   tar               cmd:tar
build   zstd              cmd:zstd
build   xz                cmd:xz
build   python3           cmd:python3
build   pc-wayland-client pc:wayland-client
build   pc-wayland-server pc:wayland-server
build   pc-wayland-protocols pc:wayland-protocols
build   pc-xkbcommon      pc:xkbcommon
build   pc-libinput       pc:libinput
build   pc-libseat        pc:libseat
build   pc-libudev        pc:libudev
build   pc-libdrm         pc:libdrm
build   pc-gbm            pc:gbm
build   pc-egl            pc:egl
build   pc-gl             pc:gl
build   pc-pixman         pc:pixman-1
build   pc-pipewire       pc:libpipewire-0.3
build   pc-libpulse       pc:libpulse
build   pam-header        file:/usr/include/security/pam_appl.h
build   pc-alsa           pc:alsa
build   pc-fontconfig     pc:fontconfig
build   pc-freetype       pc:freetype2
build   pc-harfbuzz       pc:harfbuzz
build   pc-libxml2        pc:libxml-2.0
build   pc-libpng         pc:libpng
build   pc-dbus           pc:dbus-1
build   pc-x11            pc:x11
build   pc-xcb            pc:xcb
build   pc-dav1d          pc:dav1d
build   pc-vulkan         pc:vulkan
gate    bwrap             cmd:bwrap
gate    foot              cmd:foot
gate    lavapipe          file:/usr/share/vulkan/icd.d/lvp_icd*.json
TABLE
}

packages_fedora() {
  case "$1" in
    user-bus) echo - ;;
    polkit) echo polkit ;;
    portal) echo xdg-desktop-portal ;;
    portal-gtk) echo xdg-desktop-portal-gtk ;;
    xwayland) echo xorg-x11-server-Xwayland ;;
    secrets) echo gnome-keyring ;;
    bwrap) echo bubblewrap ;;
    curl) echo curl ;;
    xdg-open) echo xdg-utils ;;
    vulkan-loader) echo vulkan-loader ;;
    vulkan-driver) echo mesa-vulkan-drivers ;;
    xwayland-satellite) echo xwayland-satellite ;; # packages.fedoraproject.org: 0.8.2 on Fedora 43, 44 and 45
    pipewire) echo pipewire ;;
    pipewire-pulse) echo pipewire-pulseaudio ;;
    wireplumber) echo wireplumber ;;
    network-manager) echo NetworkManager ;;
    bluez) echo bluez ;;
    upower) echo upower ;;
    power-profiles) echo power-profiles-daemon ;;
    accounts-service) echo accountsservice ;;
    ddcutil) echo ddcutil ;;
    at-spi) echo at-spi2-core ;;
    input-method) echo ibus ;;
    packagekit) echo PackageKit ;;
    cjk-fonts) echo google-noto-sans-cjk-fonts ;;
    cc) echo gcc gcc-c++ ;;
    make) echo make ;;
    cmake) echo cmake ;;
    pkg-config) echo pkgconf-pkg-config ;;
    libclang) echo clang-devel llvm-devel ;;
    perl) echo perl-core ;;
    git | tar | zstd | xz | python3) echo "$1" ;;
    pc-wayland-client | pc-wayland-server) echo wayland-devel ;;
    pc-wayland-protocols) echo wayland-protocols-devel ;;
    pc-xkbcommon) echo libxkbcommon-devel ;;
    pc-libinput) echo libinput-devel ;;
    pc-libseat) echo libseat-devel ;;
    pc-libudev) echo systemd-devel ;;
    pc-libdrm) echo libdrm-devel ;;
    pc-gbm) echo mesa-libgbm-devel ;;
    pc-egl) echo mesa-libEGL-devel ;;
    pc-gl) echo mesa-libGL-devel ;;
    pc-pixman) echo pixman-devel ;;
    pc-pipewire) echo pipewire-devel ;;
    pc-libpulse) echo pulseaudio-libs-devel ;;
    pam-header) echo pam-devel ;;
    pc-alsa) echo alsa-lib-devel ;;
    pc-fontconfig) echo fontconfig-devel ;;
    pc-freetype) echo freetype-devel ;;
    pc-harfbuzz) echo harfbuzz-devel ;;
    pc-libxml2) echo libxml2-devel ;;
    pc-libpng) echo libpng-devel ;;
    pc-dbus) echo dbus-devel ;;
    pc-x11) echo libX11-devel ;;
    pc-xcb) echo libxcb-devel ;;
    pc-dav1d) echo libdav1d-devel ;;
    pc-vulkan) echo vulkan-loader-devel ;;
    foot) echo foot ;;
    lavapipe) echo mesa-vulkan-drivers ;;
    *) echo - ;;
  esac
}

packages_debian() {
  case "$1" in
    user-bus) echo dbus-user-session ;;
    polkit) echo polkitd pkexec ;;
    portal) echo xdg-desktop-portal ;;
    portal-gtk) echo xdg-desktop-portal-gtk ;;
    xwayland) echo xwayland ;;
    secrets) echo gnome-keyring ;;
    bwrap) echo bubblewrap ;;
    curl) echo curl ;;
    xdg-open) echo xdg-utils ;;
    vulkan-loader) echo libvulkan1 ;;
    vulkan-driver) echo mesa-vulkan-drivers ;;
    xwayland-satellite) echo "!xwayland-satellite (older X11 apps) is not in the Ubuntu archive; the prebuilt release includes it. To build it yourself you need Rust from rustup (Ubuntu's is too old). First: $XWAYLAND_SATELLITE_APT_LINE   Then, as yourself and never as root: $XWAYLAND_SATELLITE_CARGO_LINE   That puts it in ~/.cargo/bin, which the session's search path may not include; point casement at it with this line under [xwayland] in your own ~/.config/casement/settings.toml, which you write yourself (the installer never touches it): $XWAYLAND_SATELLITE_CONFIG_LINE" ;;
    pipewire) echo pipewire ;;
    pipewire-pulse) echo pipewire-pulse ;;
    wireplumber) echo wireplumber ;;
    network-manager) echo network-manager ;;
    bluez) echo bluez ;;
    upower) echo upower ;;
    power-profiles) echo power-profiles-daemon ;;
    accounts-service) echo accountsservice ;;
    ddcutil) echo ddcutil ;;
    at-spi) echo at-spi2-core ;;
    input-method) echo ibus ;;
    packagekit) echo packagekit ;;
    cjk-fonts) echo fonts-noto-cjk ;;
    cc | make) echo build-essential ;;
    cmake) echo cmake ;;
    pkg-config) echo pkg-config ;;
    libclang) echo libclang-dev ;;
    perl) echo perl ;;
    git | tar | zstd | python3) echo "$1" ;;
    xz) echo xz-utils ;;
    pc-wayland-client | pc-wayland-server) echo libwayland-dev ;;
    pc-wayland-protocols) echo wayland-protocols ;;
    pc-xkbcommon) echo libxkbcommon-dev ;;
    pc-libinput) echo libinput-dev ;;
    pc-libseat) echo libseat-dev ;;
    pc-libudev) echo libudev-dev ;;
    pc-libdrm) echo libdrm-dev ;;
    pc-gbm) echo libgbm-dev ;;
    pc-egl) echo libegl-dev ;;
    pc-gl) echo libgl-dev ;;
    pc-pixman) echo libpixman-1-dev ;;
    pc-pipewire) echo libpipewire-0.3-dev ;;
    pc-libpulse) echo libpulse-dev ;;
    pam-header) echo libpam0g-dev ;;
    pc-alsa) echo libasound2-dev ;;
    pc-fontconfig) echo libfontconfig-dev ;;
    pc-freetype) echo libfreetype-dev ;;
    pc-harfbuzz) echo libharfbuzz-dev ;;
    pc-libxml2) echo libxml2-dev ;;
    pc-libpng) echo libpng-dev ;;
    pc-dbus) echo libdbus-1-dev ;;
    pc-x11) echo libx11-dev ;;
    pc-xcb) echo libxcb1-dev ;;
    pc-dav1d) echo libdav1d-dev ;;
    pc-vulkan) echo libvulkan-dev ;;
    foot) echo foot ;;
    lavapipe) echo mesa-vulkan-drivers ;;
    *) echo - ;;
  esac
}

packages_arch() {
  case "$1" in
    user-bus) echo - ;;
    polkit) echo polkit ;;
    portal) echo xdg-desktop-portal ;;
    portal-gtk) echo xdg-desktop-portal-gtk ;;
    xwayland) echo xorg-xwayland ;;
    secrets) echo gnome-keyring ;;
    bwrap) echo bubblewrap ;;
    curl) echo curl ;;
    xdg-open) echo xdg-utils ;;
    vulkan-loader) echo vulkan-icd-loader ;;
    vulkan-driver) echo '!install the Vulkan driver for your graphics card: vulkan-radeon, vulkan-intel or nvidia-utils' ;;
    xwayland-satellite) echo xwayland-satellite ;;
    pipewire) echo pipewire ;;
    pipewire-pulse) echo pipewire-pulse ;;
    wireplumber) echo wireplumber ;;
    network-manager) echo networkmanager ;;
    bluez) echo bluez ;;
    upower) echo upower ;;
    power-profiles) echo power-profiles-daemon ;;
    accounts-service) echo accountsservice ;;
    ddcutil) echo ddcutil ;;
    at-spi) echo at-spi2-core ;;
    input-method) echo ibus ;;
    packagekit) echo packagekit ;;
    cjk-fonts) echo noto-fonts-cjk ;;
    cc | make) echo base-devel ;;
    cmake) echo cmake ;;
    pkg-config) echo pkgconf ;;
    libclang) echo clang ;;
    perl) echo perl ;;
    git | tar | zstd | xz | python3) echo "$1" ;;
    pc-wayland-client | pc-wayland-server) echo wayland ;;
    pc-wayland-protocols) echo wayland-protocols ;;
    pc-xkbcommon) echo libxkbcommon ;;
    pc-libinput) echo libinput ;;
    pc-libseat) echo seatd ;;
    pc-libudev) echo systemd-libs ;;
    pc-libdrm) echo libdrm ;;
    pc-gbm) echo mesa ;;
    pc-egl | pc-gl) echo libglvnd ;;
    pc-pixman) echo pixman ;;
    pc-pipewire) echo pipewire ;;
    pc-libpulse) echo libpulse ;;
    pam-header) echo pam ;;
    pc-alsa) echo alsa-lib ;;
    pc-fontconfig) echo fontconfig ;;
    pc-freetype) echo freetype2 ;;
    pc-harfbuzz) echo harfbuzz ;;
    pc-libxml2) echo libxml2 ;;
    pc-libpng) echo libpng ;;
    pc-dbus) echo dbus ;;
    pc-x11) echo libx11 ;;
    pc-xcb) echo libxcb ;;
    pc-dav1d) echo dav1d ;;
    pc-vulkan) echo vulkan-icd-loader ;;
    foot) echo foot ;;
    lavapipe) echo vulkan-swrast ;;
    *) echo - ;;
  esac
}

# family_packages FAMILY KEY...: the packages for those keys, each once, in order.
family_packages() {
  local family=$1 key words word
  local -A seen=()
  shift
  for key in "$@"; do
    words=$("packages_$family" "$key")
    case "$words" in - | '!'*) continue ;; esac
    # shellcheck disable=SC2086  # a word list on purpose
    for word in $words; do
      [ -z "${seen[$word]:-}" ] || continue
      seen[$word]=1
      echo "$word"
    done
  done
}

# family_notes FAMILY KEY...: the "!TEXT" answers (a key with no package here), TEXT only.
family_notes() {
  local family=$1 key text
  shift
  for key in "$@"; do
    text=$("packages_$family" "$key")
    case "$text" in '!'*) echo "${text#!}" ;; esac
  done
}

install_line() {
  local family=$1
  shift
  case "$family" in
    fedora) as_root_hint dnf install "$@" ;;
    debian) as_root_hint apt install "$@" ;;
    arch) as_root_hint pacman -S "$@" ;;
  esac
}

# install_hint KEY...: what to type on this machine for those keys (the family from distro_family). A
# family that is not known gets the three lines, each labelled.
install_hint() {
  local family names fam pkgs=()
  family=$(distro_family)
  case "$family" in
    other) names=(fedora debian arch) ;;
    *) names=("$family") ;;
  esac
  for fam in "${names[@]}"; do
    mapfile -t pkgs < <(family_packages "$fam" "$@")
    [ "${#pkgs[@]}" -gt 0 ] || continue
    [ "$family" != other ] || printf '%s: ' "$fam"
    install_line "$fam" "${pkgs[@]}"
  done
}
