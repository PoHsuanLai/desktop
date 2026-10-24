# Distros

The desktop is meant to work out of the box on three families:

- **Ubuntu 24.04 and newer** (and Debian-based systems that share its package names)
- **Fedora**, the current release
- **Arch Linux**

Anything else is treated as "unknown": the installer prints the install line for all three families and lets
you pick.

## What the installer checks

`./install.sh --check` changes nothing. It reads `/etc/os-release` (`ID` and `ID_LIKE`) to find the family, looks for
what the desktop needs, and prints the exact `dnf`, `apt` or `pacman` line for what is missing. It exits 1 when
something needed is missing, so you can use it in a script. `--check --runtime-only` leaves out the tools for
building from source.

It looks for:

- **To run the session**: a way to ask for administrator rights (polkit), the desktop portals (file chooser,
  screenshots, screen sharing; the backend that answers screenshots and screen sharing is transom, which the
  installer builds and puts in place), Xwayland, a place to keep saved passwords (gnome-keyring or KWallet), bubblewrap
  (the sandbox for agents), fuse3 (cloud drives in Files open their files when you open them), curl, xdg-utils, the Vulkan loader and a Vulkan driver. On Ubuntu also
  `dbus-user-session`, which minimal installs lack.
- **To build from source**: rustup (the repos pin Rust 1.98.1; a distro's own rust package is the wrong version,
  and Ubuntu's is far too old), a C toolchain, cmake, pkg-config, libclang, perl and the development packages of
  the libraries we link (Wayland, libinput, libseat, libdrm, Mesa, PipeWire, PAM, fontconfig and others).
  If you install a prebuilt bundle you can skip all of this.
- **Recommended**: NetworkManager, BlueZ, UPower, power-profiles-daemon and AccountsService (Wi-Fi,
  Bluetooth, battery, power mode, your picture; each simply stays empty without its service), PipeWire with
  its PulseAudio layer and WirePlumber (sound, screen sharing), ddcutil (brightness of external monitors),
  at-spi2-core (reading other apps' windows, which the assistant's helper for apps that are not ours needs; the installer
  tells you when it is missing), an input method (fcitx5 or ibus), PackageKit and CJK fonts.
  `xwayland-satellite` runs older X11 apps; casement starts it by itself when it is installed. The prebuilt release
  includes it on every distribution. Fedora and Arch package it; Ubuntu 24.04 does not (see below).

Everything the check prints comes from one file, `install/packages.sh`. The harness and the gate use it for their
own hints.

Source builds do not need `mold`, and never use a linker other than the system's: several repos' cargo config asks
for clang and mold to link faster, which is for the people who work on them. An install builds from `/` with
`--manifest-path` (`install/cargo.sh`), so cargo does not read that file, and nothing is installed for the linker.

## Install lines

These are what `--check` prints when everything is missing (run them with `sudo`, `doas` or as root; the
installer picks the one you have, or set `SUDO`).

**Fedora**

```
dnf install polkit xdg-desktop-portal xdg-desktop-portal-gtk xorg-x11-server-Xwayland gnome-keyring bubblewrap fuse3 curl xdg-utils vulkan-loader mesa-vulkan-drivers
```

**Ubuntu / Debian**

```
apt install dbus-user-session polkitd pkexec xdg-desktop-portal xdg-desktop-portal-gtk xwayland gnome-keyring bubblewrap fuse3 curl xdg-utils libvulkan1 mesa-vulkan-drivers
```

**Arch**

```
pacman -S polkit xdg-desktop-portal xdg-desktop-portal-gtk xorg-xwayland gnome-keyring bubblewrap fuse3 curl xdg-utils vulkan-icd-loader
```

Arch also needs a Vulkan driver for your graphics card: `vulkan-radeon`, `vulkan-intel` or `nvidia-utils`.

For building from source, add rustup first:

```
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

and then the build line for your family:

```
dnf install gcc gcc-c++ make cmake pkgconf-pkg-config clang-devel llvm-devel perl-core git curl tar zstd xz python3 wayland-devel wayland-protocols-devel libxkbcommon-devel libinput-devel libseat-devel systemd-devel libdrm-devel mesa-libgbm-devel mesa-libEGL-devel mesa-libGL-devel pixman-devel pipewire-devel pulseaudio-libs-devel pam-devel alsa-lib-devel fontconfig-devel freetype-devel harfbuzz-devel libxml2-devel libpng-devel dbus-devel libX11-devel libxcb-devel libdav1d-devel vulkan-loader-devel
apt install build-essential cmake pkg-config libclang-dev perl git curl tar zstd xz-utils python3 libwayland-dev wayland-protocols libxkbcommon-dev libinput-dev libseat-dev libudev-dev libdrm-dev libgbm-dev libegl-dev libgl-dev libpixman-1-dev libpipewire-0.3-dev libpulse-dev libpam0g-dev libasound2-dev libfontconfig-dev libfreetype-dev libharfbuzz-dev libxml2-dev libpng-dev libdbus-1-dev libx11-dev libxcb1-dev libdav1d-dev libvulkan-dev
pacman -S base-devel cmake pkgconf clang perl git curl tar zstd xz python3 wayland wayland-protocols libxkbcommon libinput seatd systemd-libs libdrm mesa libglvnd pixman pipewire libpulse pam alsa-lib fontconfig freetype2 harfbuzz libxml2 libpng dbus libx11 libxcb dav1d vulkan-icd-loader
```

Every package name above, and those in `release/deps.sh`, was looked up on 2026-10-16 in the `ubuntu:24.04`,
`fedora:44` and `archlinux` images.

### X11 apps on Ubuntu

`xwayland-satellite` (MPL-2.0, from `github.com/Supreeeme/xwayland-satellite`) is a separate program that
casement starts when it is installed. Fedora (`xwayland-satellite`, 0.8.2 on Fedora 43 to 45) and Arch
(`xwayland-satellite`) package it; Ubuntu 24.04 does not, and `--check` says so. The prebuilt release has it, so a
bundle install needs nothing more. For a source install on Ubuntu, you build it yourself, once. It needs Rust from
rustup (Ubuntu's own Rust is older than the 1.85 it asks for), the Xwayland package from the table above (it needs
Xwayland 23.1 or newer, and 24.04 has 23.2) and these build packages:

```
sudo apt install clang pkg-config libxcb1-dev libxcb-composite0-dev libxcb-randr0-dev libxcb-res0-dev libxcb-cursor-dev
cargo install --locked --git https://github.com/Supreeeme/xwayland-satellite --tag v0.8.3
```

That puts `xwayland-satellite` in `~/.cargo/bin`, which the session's search path may not include. casement has a
setting for the program's place, so point it there with one line in your own `~/.config/casement/settings.toml`
(or `$XDG_CONFIG_HOME/casement/settings.toml`), under the heading `[xwayland]`, with your own home folder written out
in full (casement does not expand `~`):

```
[xwayland]
satellite = "/home/YOU/.cargo/bin/xwayland-satellite"
```

You write that file yourself: the installer never runs the two lines above and never touches your settings. Run the
`cargo install` line as yourself, never as root. The setting takes effect at the next login. v0.8.3 is the tag the release bundle builds as well
(`SATELLITE_TAG` in `release/build.sh`; `gate/distro-check.sh` checks it matches `install/packages.sh`).

## Colour emoji

Our renderer draws only the COLRv1 build of Noto Color Emoji. Fedora ships that. Ubuntu
(`fonts-noto-color-emoji`) and Arch (`noto-fonts-emoji`) ship the older bitmap build, which shows nothing for us.
So the repo carries the COLRv1 font (`fonts/`, with its licence and source) and `install.sh` puts it in
`<prefix>/share/fonts/quire/` and refreshes the font cache, unless fontconfig already lists a `Noto-COLRv1`
font. Use a prefix of `/usr` or `/usr/local`, which fontconfig searches by default.

## Running AI on this computer

The assistant can run models on this computer through llama.cpp's server (`llama-server`). The installer does not
install it: it is optional, and large. Settings, under Models on this computer, says when it is missing and shows
the one command for your distro, with a button to copy it:

- **Fedora**: `sudo dnf install llama-cpp`
- **Arch**: `sudo pacman -S llama-cpp`
- **Debian 14 and newer, Ubuntu 26.04 and newer**: `sudo apt install llama.cpp-tools`
- **Debian 13, Ubuntu 24.04 to 25.10**: no package. Get the server from llama.cpp's releases page
  (`github.com/ggml-org/llama.cpp/releases`) and put `llama-server` in `/usr/local/bin` as root.

The assistant looks for `llama-server` in `/usr/bin`, then `/usr/local/bin`, and never in your own search path. It
reads that list when it starts, so after installing, press **Start using it** in Settings: it restarts the assistant
(asking first, since a conversation that is open stops).

vLLM is not looked for. If you run it, install it into a Python environment of your own (for example
`uv venv ~/vllm && uv pip install --python ~/vllm vllm`) and name that Python in `~/.config/quire/inferd.toml`
(or `$XDG_CONFIG_HOME/quire/inferd.toml`):

```
[engines]
vllm_python = "/home/YOU/vllm/bin/python"
```

## Picking the session at login

The installer puts the entry **sill (casement)** in `/usr/share/wayland-sessions`.

- **GDM** (Ubuntu, Fedora Workstation): choose your user, click the gear at the lower right of the password
  screen, pick **sill (casement)**, then type the password. GDM remembers the choice for next time.
- **SDDM** (Fedora KDE, Arch with SDDM): use the session drop-down on the login screen (lower left in most themes).
  It remembers your last choice.
- **No display manager** (typical on Arch): log in on a text console and start the session from your shell's
  login file. In `~/.bash_profile` (or `~/.zprofile`):

  ```
  if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "${XDG_VTNR:-}" = 1 ]; then
    exec desktop-session
  fi
  ```

  The guard on `XDG_VTNR=1` keeps the other consoles as plain text consoles. If the session ends, you are logged
  out of that console; log in again for a text shell.
- **LightDM**: Wayland sessions are only partly supported there; not checked for this desktop.

If the session crashes at start, it falls back to a safe mode, and if that fails too it ends and your other session
is still there at the login screen.

## Ubuntu 24.04 and user namespaces

Ubuntu 24.04 stops programs without an AppArmor profile from creating user namespaces
(`kernel.apparmor_restrict_unprivileged_userns=1`). Bubblewrap is one of those programs, so on a stock install:

- the test jail (`harness/jail.sh`, the gate) refuses to start and prints the fix;
- the agent sandbox cannot start and refuses to run shell tools rather than run them unprotected.

Two fixes, pick one:

1. Turn the restriction off (until reboot, or permanently with a file in `/etc/sysctl.d/`):

   ```
   sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
   ```

2. Give bwrap its own AppArmor profile that allows user namespaces. Save as `/etc/apparmor.d/bwrap`, then load it
   with `sudo apparmor_parser -r /etc/apparmor.d/bwrap`:

   ```
   abi <abi/4.0>,
   include <tunables/global>
   profile bwrap /usr/bin/bwrap flags=(unconfined) {
     userns,
     include if exists <local/bwrap>
   }
   ```

Some background services use systemd's private mount namespaces and may be affected by the same rule; if one of
them fails to start on Ubuntu with a "namespace" error, the same two fixes apply.

## Updates

Updates come from slipway, a program of its own. Its installer puts three programs in `/usr/libexec`
(`slipway-apply`, `slipway-rollback`, `slipway-health`) and one polkit file, `org.quire.slipway.policy`, that names them,
the same on Ubuntu, Fedora and Arch. A newer signed release installs without a password for the person at the keyboard;
going back to an earlier version asks for the administrator's password. The session wants slipway's update service in every
login, so the daily check asks before it installs anything.

If an update does not start, the session puts the previous version back by itself after several restarts of the computer, and
if the compositor cannot start at all the session ends and says so in `~/.local/state/desktop-session/guard.log`. To go back
at once by hand, open a text console (Ctrl+Alt+F3) and run:

```
pkexec /usr/libexec/slipway-rollback
```

slipway never places or reloads an AppArmor profile, so the Ubuntu note below is unchanged by it. It needs polkit, which
the install lines above already include (`polkit` on Fedora and Arch, `polkitd pkexec` on Ubuntu).

## Where things go

`./install.sh` takes `--prefix` (default `/usr/local`), `--sysconfdir` (default `/etc`) and `--destdir`. porter goes
under the same prefix as the rest: its daemons find the providers, the client table and the model catalog under the
first `$XDG_DATA_DIRS` entry that has them (default `/usr/local/share:/usr/share`), and its caller tables in
`/etc/porter`. The session script, the desktop target and the login entry
are installed by `install/install.sh`, which `./install.sh` runs last. casement and its user unit are installed by
casement's own installer, which `./install.sh` runs too. Both print the exact command to run as root when they
cannot write a place (`/etc`, `/usr/share/wayland-sessions`) themselves.

### The input service and the list of programs

The same on Ubuntu, Fedora and Arch (all three run systemd and udev; no package is needed, so there are no apt, dnf or pacman lines).
`/dev/uinput` is the file a program writes to make a keyboard or a mouse, and with it any program of yours could type into any window. The
desktop closes it: the device rule `72-turnstile.rules` makes it root-only and takes off the tag (`uaccess`) that some distributions and
game packages add, and one small service (`turnstile`, started when something asks for it) makes the virtual devices for the keyboard map
and the touchpad program, and for nobody else. Its socket accepts any local program; who gets a device is decided by which program is asking,
from `/etc/quire/desktop-callers.toml`. Nothing in the desktop gives that file to a group, so a keyboard-map install left over from before
(`/etc/udev/rules.d/70-keycap.rules`, `/etc/systemd/system/keycap.service.d/10-uinput.conf`) should be removed; `install/system.sh keycap`
says so when it finds them. The same part places keycap's vendor file, `/usr/lib/keycap/keycap.toml` (Caps Lock switches the input method), on every family; `/etc/keycap/keycap.toml` stays the administrator's and nothing here writes it. On Fedora the files are labelled with `restorecon` when SELinux is on. On Ubuntu no AppArmor profile is placed.
Services that were running before the list of programs was installed read it only when they start: log out and in once.
