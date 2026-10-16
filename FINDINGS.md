# Findings

## Release bundle (lane desk-release, 2026-10-15)

`release/build.sh` stages the whole desktop under `/opt/quire/current` with a destdir. Where a component's
installer could stage, it is used (porter, detent, anyview, mailo, and this repo's session installer). The
rest is staged by build.sh itself, marked INTERIM in the script, because the component's installer cannot
stage without sudo or writes `$HOME`. What each installer must gain so the INTERIM block can go (all
`--prefix DIR --destdir DIR`, no sudo, nothing under `$HOME` or `/etc` outside the destdir, `--no-build`
and `--locked` builds, the installed path (never the destdir-prefixed one) inside any unit or service file):

- casement: no installer at all. Needs one that installs `bin/casement`, `bin/casementctl` and
  `dist/casement.service` with `ExecStart=<prefix>/bin/casement` (the unit says `/usr/bin/casement`; build.sh
  rewrites it).
- sill (`dist/install.sh`): fixed `/usr/local`, `/etc/pam.d/sill`, `~/.config/keycap`, sudo, and a build
  inside the installer. Needs `--prefix/--destdir/--no-build/--bin`, no keycap layer copy into the home
  (split the per-user copy into the session), and a place for the PAM service.
- keycap (`install.sh`): stages under DESTDIR but at `/etc` and `/usr/local`, not under a prefix, and builds
  unlocked. Needs `--prefix` so the binary, the unit (with `ExecStart` for that prefix), the udev and
  polkit rules go under it.
- palmrest (`install.sh`): writes `~/.local/bin` and `~/.config/systemd/user`, enables the service, builds
  unlocked. Needs the same prefix/destdir staging and no `systemctl` in staging; the unit's `ExecStart` is
  `%h/.local/bin/palmrest` (build.sh rewrites it).
- mailo (`dist/install.sh`): `MAILO_PREFIX` as a destdir writes the destdir-prefixed path into
  `org.quire.Mail.service` (build.sh seds it out). Needs a real `--destdir` beside the prefix.
- porter (`scripts/install.sh`): fine, but builds without `--locked` (build.sh builds locked first and passes
  `--no-build`); the top-level `install.sh` has no way to pass `--no-build`, so build.sh calls porter directly.
- anyview (`dist/install.sh`): builds the mpv plugin's C plugin and fetches mpv-wgpu without `--locked`
  (build.sh builds it locked and passes `ANYVIEW_MPV_CPLUGIN`); `--mpv PATH` cannot be passed through the
  top-level `install.sh`, so the plugin manifest names the builder's `mpv` or `/usr/bin/mpv`.
- slipway: its `scripts/install.sh` installs the helper, polkit action, unit, bus file and release key on a
  machine (release/bootstrap.sh runs after it). The bundle carries only `bin/slipway`, built from the
  manifest pin; `slipway-apply` is deliberately outside the release. build.sh's staging of `bin/slipway`
  is INTERIM until slipway has a stageable installer for the user program.
- transom: named in the brief, but no repo beside this one and no entry in `manifest.toml`; not built.
  Add it to `ALL` and a `build_transom` in `release/build.sh` when it exists.

What the bundle exports and places (lane distro-slip, 2026-10-16; slipway-core's allow-lists are the same
lists as `release.py`'s):

- Links (`[[export]]`, derived from the staged tree): everything staged under `share/wayland-sessions`,
  `share/xdg-desktop-portal`, `share/dbus-1/services`, `lib/systemd/user`, `share/applications`,
  `share/polkit-1/actions`, and now `share/quire` (intents, skills, settings schemas, helpers, icons),
  `share/porter` (providers, client tables), `share/stoker` (the model catalog) and `share/fonts` (the desktop
  lane ships `fonts/Noto-COLRv1.ttf` to `share/fonts/quire/`). Commands are `exports.toml` links in `/usr/local/bin`.
  A distribution's own file at the same path is a conflict and is left alone.
- Files (`[[system]]`, staged in `system/<absolute path>`): `/etc/pam.d/sill`, keycap's `keycap.service` (at
  `/usr/lib/systemd/system`), `70-keycap.rules`, `keycap.polkit.rules` and `modules-load.d/keycap.conf` (`uinput`,
  written by build.sh because keycap ships none), palmrest's `70-palmrest.rules` and `modprobe.d/99-palmrest.conf`,
  and porter's `/etc/porter/callers.toml` (porter's installer is pointed at `<prefix>/system/etc`).
- Still data only (no home on the system): `share/sill/keycap.toml` (the sill session's keycap layer, which sill's
  installer copied into the home), `share/keycap/keycap.plasma.toml` (the Plasma overlay; not used by this
  desktop).
- Not staged yet: sill's DDC/CI udev rule and `i2c-dev` module list (`dist/udev`, `dist/modules-load.d`; sill's own
  installer leaves them out on purpose, ddcutil's package ships the rule on Fedora; audit D7 decides) and
  `/etc/keycap/keycap.toml` (keycap's machine layer; `/etc/keycap` is not an allowed system folder).

Whether the release should write `/etc/pam.d` at all is slipway's open question 5; deleting the folder from
both lists (`ALLOWED_SYSTEM_DIRS`, `SYSTEM_DIRS`) turns it off.

Other choices: file modes are normalised to 0644 or 0755 (executable bit kept) so the bundle does not depend on
the builder's umask; the date is the packing time (`SOURCE_DATE_EPOCH` overrides it); `release/release.pub`
is committed by the owner and the CI refuses to publish without it.

## Distro audit (lane 5, 2026-10-16)

B3/D18: the workflow builds in `ubuntu:24.04` (was `fedora:44`), with `release/deps.sh debian build`, rustup with each
repo's pinned toolchain, and Zig 0.16.0 from ziglang.org with its SHA-256 pinned; `check-glibc.sh` and `check-ldd.sh`
run after every build. The smoke job installs the signed release with slipway-apply in `ubuntu:24.04`, `fedora:44` and
`archlinux:latest`; publishing waits for it. B2: four more export folders (above). D17: the system step (above).
N2: `lib.sh` gives the install hint per family. Not run (no compiler, minisign or runner here): the workflow, the
package names marked `# unverified` in `deps.sh` (Ubuntu t64 and libdav1d names, Fedora libdav1d), the selftest's
new cases, and `smoke.sh`. The smoke runs the helper as root against `/etc/slipway/config.toml` and the real
`/opt/quire`, which is why it only runs with `--really` as root.

## Round 2 (release.py aligned with slipway-core)

Applied from slipway's FINDINGS "Release pipeline": `.slipway` reserved, mode rules (readable by owner, not
group/other writable), semver.org regex, real date parse, the five size limits in pack and verify (the
bundle-size and file-count limits are not forged in selftest: too big), DEL escaped in `toml_str`, prehashed
(`ED`) signatures required (`minisign -S -H`; needs minisign 0.11 or later), exports must be bundle files
(a folder target is refused by verify; pack derives only file exports). The README path is
`scripts/install.sh`. slipway is in `manifest.toml` (`[repo.slipway]`, rev e8af08f4); the workflow's
`slipway_ref` input is gone. polkit's action directory follows a link into /opt on a real machine only if
polkit does; confirm on a machine.

## desk-callers (2026-10-16)

The top-level `install.sh` now installs almanac (the memory daemon, `/etc/quire/memory-callers.toml`) and
docket (its four daemons, `quire-do`, and the `/etc/quire/*-callers.toml` tables), between porter and detent.
Both are in `ORDER`, the `--only` help, the README list and `gate/installer-check.sh` (stubs, plan order, the
staged arguments, and the not-staged case).

What I found and decided:

- Neither installer takes `--sysconfdir`; `/etc/quire` (and docket's `/etc/xdg/quire`) are fixed. Not
  invented: the top-level declares those places as written, under the destdir, and passes only `--prefix` and
  `--destdir`. No `--distro`, `--sandbox` or `--no-build` is passed (nothing existing passes them either); the
  installers read the family from the machine, so Ubuntu, Fedora and Arch work. No linker is asked for.
- They do not fit porter's "print the root command" path: both refuse to run as root ("Run this as yourself")
  and escalate (`$SUDO`, sudo, doas, pkexec) per step themselves. A root hint for them would fail. So without a
  `--destdir` they are listed as "yourself" with the plain command (the same way sill and keycap are); with a
  `--destdir` they run here and never escalate. A destdir that you cannot write stops them with their own message.
- `release/build.sh` is not changed: it builds by name from a fixed list and neither is in it. Adding them
  needs the installers to stage `/etc/quire` inside the prefix (a `--sysconfdir`, or put_system-style output for
  `memory-callers.toml` and the docket tables), because build.sh refuses files outside `/opt/quire/current` and
  `release.py` allows system files only in listed folders. Ask almanac and docket for `--sysconfdir`, then add
  `build_almanac` and `build_docket` (build locked, `--no-build --bin-dir`). The manifest already lists both
  with gate rows; revs untouched.
- `install/uninstall.sh` is the session's alone; no top-level uninstall lists components.

## Release bundle: emoji font and monitor brightness (lane desk-callers, item 212, 2026-10-16)

- The session component of `release/build.sh` now stages `fonts/Noto-COLRv1.ttf` and the licence
  (`OFL-Noto-COLRv1.txt`, the name `install.sh` uses) at `share/fonts/quire/`. `share/fonts` is an automatic export,
  so the bundle links `/usr/share/fonts/quire/Noto-COLRv1.ttf`; quire's `emoji_file.rs` looks for
  `<data dir>/fonts/quire/Noto-COLRv1.ttf` over `XDG_DATA_DIRS` (default includes `/usr/share`), and fontconfig
  reads `/usr/share/fonts` too. The bundle ships the font on every distro (Fedora's own copy is byte-identical,
  harmless); `install.sh` skips it where fontconfig already has one, which a bundle cannot test.
- sill ships both files (`dist/udev/60-sill-ddc.rules`, `dist/modules-load.d/sill-ddc.conf`), and slipway's system
  folders (origin/master at b607414, `ALLOWED_SYSTEM_DIRS`) include `/etc/udev/rules.d` and `/etc/modules-load.d`, so
  both are staged with `put_system` at those paths (the same folders keycap uses). No slipway follow-up needed. The
  local ~/slipway checkout is five commits behind origin (its link list still has 7 folders); `release.py`'s lists
  match origin. Same-tag duplicate with Fedora's `60-ddcutil-i2c.rules` is harmless (install.sh's "unless ddcutil
  has it" test is not reproduced).
- `pack.sh` needed no change: it lists whatever is staged. `release/selftest.sh` (the "release (pack, verify, hostile
  releases)" check) now also stages a font and a modules-load file and asserts the font link and the system entry.

## Release bundle: almanac and docket (lane desk-callers, 2026-10-16)

- `release/build.sh` builds almanac (`memoryd`) and docket (its four daemons, `quire-do`, `docket-acp`; not the
  voice daemon) after porter, locked, then runs their installers with `--bin-dir`, `--prefix /opt/quire/current`,
  `--destdir <stage>` and `--sysconfdir /opt/quire/current/system/etc`. The caller tables land as system files in
  `/etc/quire`, docket's default settings in `/etc/xdg/quire`. These steps need almanac >= 6aade09 and docket >=
  e44112c (the `--sysconfdir` commits); the manifest revs are unchanged and the next bump brings them, so a release
  built before that fails in these two steps.
- Decision (owner, 2026-10-16): `/etc/xdg/quire`, the XDG system-wide config folder, is an allowed system folder
  (slipway aa427f2, `ALLOWED_SYSTEM_DIRS`), and slipway leaves alone a file a person edited there. `release.py` and
  `release/README.md` carry the same list; `manifest.toml` moves only slipway's rev to aa427f2. The selftest accepts
  a file in `/etc/xdg/quire` and refuses one at `/etc/xdg/other.toml` (now 25 hostile releases).
- `install/cargo.sh` gives almanac the `net.git-fetch-with-cli` setting its own installer passes (docket's does not).
- Not exported: `quire-do` and `docket-acp` stay under `/opt/quire/current/bin` (no `/usr/local/bin` link in
  `exports.toml` yet), and the shell completions and interface XML ship in the bundle without links.
- The release workflow has a new job `agents` (almanac and docket together; both need perl and make, which
  `release/deps.sh` already installs). Not run here; it fails until the manifest carries almanac >= 6aade09 and
  docket >= e44112c.

## desk-pprefix (2026-10-16)

B1 is closed by porter 2e5cd74 (in the pinned de06006), so `install.sh` no longer forces porter to `/usr`: it gets
the desktop `--prefix` (default `/usr/local`) and `--sysconfdir` (default `/etc`) like the other components, and the
"porter goes to /usr" note is gone. Checked in porter's source at de06006, with `--prefix /usr/local --sysconfdir /etc`
(`scripts/install.sh` puts providers, `clients.toml`, the tailnet drop-in under `$prefix/share/porter` and the caller
tables at `$sysconfdir/porter`):

- providers, `clients.toml` and the stoker catalog: accountd, syncd and inferd take `Xdg::shipped("porter/providers")`,
  `("porter/clients.toml")` and `("stoker/catalog")` (`porter-core/src/xdg.rs`): the first `$XDG_DATA_DIRS` entry
  (default `/usr/local/share:/usr/share`) that has the path, else `/usr/share/...`.
- `callers.toml` and `inferd-callers.toml`: `/etc/porter/<file>` is searched first (`porter-daemon/src/system_callers.rs`,
  `SYSTEM_CALLERS`, `INFERD_CALLERS`, `search`), so `--sysconfdir /etc` is found. Since 36f5014 the other places are a
  fixed list (`TABLE_DIRS`), not `$XDG_*`, and a table counts only when root holds it (root-owned, no group or other
  write along its real path), so it must be installed as root, as before.
- Not verified: that the user session's `XDG_DATA_DIRS` keeps `/usr/local/share` (unset gives the default; a session that
  sets it without that entry would not find an install under `/usr/local`). Nothing was built or installed;
  `gate/installer-check.sh` and a dry run passed.
- The stoker catalog was installed by nothing on this repo's master, so inferd had no model catalogue on a fresh install.
  `install.sh` now has a `stoker` step right after porter (`scripts/install.sh --prefix P --sysconfdir S [--destdir D]`,
  stoker 3ae1211; it builds nothing and writes only `<prefix>/share/stoker/catalog`). Outside a `--destdir` it is left to
  the person like almanac (its installer escalates itself). `release/build.sh` has `build_stoker` (`--no-build`, staged
  under `share/stoker`, an auto-exported folder in `release.py`) and the CI `agents` job builds `almanac,docket,stoker`.
  Not run: the CI job and `build_stoker` (no build here; the stoker installer's dry run lists the catalog files).
- A prefix other than `/usr` and `/usr/local` is on no search path the session has. The plan now prints (never writes)
  an `environment.d` line `XDG_DATA_DIRS=<prefix>/share:/usr/local/share:/usr/share` for the D-Bus service files and the
  shipped data. Units are a separate matter: systemd's user manager reads `/usr/lib`, `/usr/local/lib` and
  `$XDG_DATA_DIRS/systemd/user`, never `<prefix>/lib/systemd/user`, so `XDG_DATA_DIRS` alone does not find them; the note
  also prints a root `ln -sf <prefix>/lib/systemd/user/* /usr/local/lib/systemd/user/`. That link command and the
  systemd search-path claim come from systemd's documented behaviour and were not tried on a machine. The session
  installer's casement.service check (`install/install.sh`) only tests that the file exists under the prefix, so it
  does not catch this.
- The release bundle is not affected: it lives under `/opt/quire/current` but `release.py` exports `share/dbus-1/services`,
  `lib/systemd/user`, `share/porter`, `share/stoker` and the other folders in `AUTO_EXPORT_DIRS` as links into `/usr/share`
  and `/usr/lib/systemd/user`, and the caller tables go to `/etc/porter` as system files. `release/build.sh` is unchanged
  apart from the stoker step.

## desk-cua: the helper for apps that are not ours (B6, 2026-10-16)

- `install.sh` has a `cua` step right after docket (`scripts/install.sh --prefix P [--destdir D]`, cua f6fe8bc, the
  manifest rev). It builds the daemon `cuad` from source (release, locked) unless the programs are given, and writes
  `<prefix>/libexec/quire/cuad`, `<prefix>/lib/systemd/user/cuad.service` with its `.service.d/sandbox.conf`, the two
  D-Bus activation files and the interface XML under `<prefix>/share/dbus-1`, the Settings schema under
  `<prefix>/share/quire/settings`, and `/etc/quire/cuad-callers.toml`. Read in full: nothing else is written, and
  `CONF_DIR` (`/etc/xdg/quire`) is computed but never used.
- No `--sysconfdir` is passed, as for almanac and docket: cuad reads `/etc/quire/cuad-callers.toml` and the person's file
  only (`crates/cuad/src/callers.rs`), so a table placed elsewhere would be ignored. Outside a `--destdir` the step is left
  to the person, as themselves (the installer refuses root and escalates per step). `gate/installer-check.sh` checks the
  stub, the order, the arguments, the no-`--sysconfdir` rule and the left-to-you case.
- Build prerequisites: its installer wants cargo, a C compiler, pkg-config and git, and the dependencies build sqlite with a
  vendored openssl (perl and make). All are already in `install/packages.sh` (build group) and `release/deps.sh`; no new
  package is needed. Run-time: at-spi2-core (already the `at-spi` row, a recommended need); the cua installer prints a
  note when the accessibility service is missing. No runtime library beyond the ones the other programs already load,
  so `release/deps.sh` is unchanged (the CI check of linked libraries will say if that is wrong).
- Release: `release/build.sh` has `build_cua` (`cargo build -p cuad`, then the installer with `--bin-dir`, `--prefix
  /opt/quire/current`, `--destdir <stage>`, `--sysconfdir /opt/quire/current/system/etc`). Everything it stages is in an
  exported folder (`libexec/quire` and `share/dbus-1/interfaces` stay in the bundle without links, as docket's do) or is
  the one system file `system/etc/quire/cuad-callers.toml`, in `/etc/quire`, an allowed system folder; no new folder is
  needed. The CI `agents` job builds `almanac,docket,stoker,cua`. cua's own build config needs no
  `net.git-fetch-with-cli` entry in `install/cargo.sh` (its config file has none, like docket's).
- Not run: the CI job and `build_cua` (no build here). `gate/installer-check.sh` and a dry run passed.

## desk-cua: xwayland-satellite on every distribution (D5, 2026-10-16)

- Facts, read on GitHub today: licence MPL-2.0 (`LICENSE`; Cargo.toml `license = "MPL-2.0"`), which is fine for a
  separate program; latest release v0.8.3 (2026-09-24, not a prerelease), with a committed `Cargo.lock` (so `--locked`
  works), edition 2024, `rust-version` 1.85.0, no `rust-toolchain`. Dependencies by its README: Xwayland >= 23.1, xcb,
  xcb-util-cursor; cargo, clang and optional git to build. Its manifest also uses the xcb extensions composite, randr and
  res. casement's own memo (`docs/xwayland-decision.md`) already says MPL-2.0 and "a separate process". Fedora packages it
  (0.8.2 on Fedora 43, 44 and 45, packages.fedoraproject.org); Arch packages it (the audit verified 0.8.3).
- Release bundle: `release/build.sh` has a `satellite` component (`cargo install --locked --git <url> --tag v0.8.3 --root
  <scratch>`, run from `/` with `RUSTUP_TOOLCHAIN` 1.98.1, then only the program is copied), staged at `bin/xwayland-satellite`
  with an MPL notice (version, licence, source address) at `share/licenses/xwayland-satellite/NOTICE.txt`, recorded as
  `xwayland-satellite v0.8.3` in the release's component list. `release/exports.toml` links it to
  `/usr/local/bin/xwayland-satellite` (on the user manager's default PATH, ahead of a distro's `/usr/bin` copy, so the
  bundle's wins), which is how casement finds it. The CI `small` job builds it with the other small components.
- Build dependencies in `release/deps.sh` (the CI image installs them): Ubuntu `libxcb-composite0-dev libxcb-randr0-dev
  libxcb-res0-dev libxcb-cursor-dev` (the last two checked on packages.ubuntu.com for noble; the first two written from
  memory), Fedora `xcb-util-cursor-devel` (libxcb-devel already has the extensions; unverified), Arch `xcb-util-cursor`
  (libxcb has them). clang, pkg-config and libxcb are already in the lists. Runtime lists (the smoke jobs): the same
  libraries without `-dev`, and the Xwayland package on all three (`xwayland`, `xorg-x11-server-Xwayland`, `xorg-xwayland`).
- Source install: `install/packages.sh` keeps `xwayland-satellite` for Fedora and Arch (the Fedora `# unverified` mark is
  gone) and the Ubuntu note now carries the apt build line and the exact `cargo install --locked --git ... --tag v0.8.3`
  line, in plain words; `docs/distros.md` has the same under "X11 apps on Ubuntu". Not run. The `--check` note is one
  line, because notes are printed that way.
- Not verified: that `cargo install --git ... xwayland-satellite` builds with the package list above (no build here);
  the first CI run shows.
- Superseded by the follow-up below: a satellite in `~/.cargo/bin` may not be on the PATH casement's unit sees.
- `gate/distro-check.sh` checks that the Ubuntu note carries the cargo line and that the tag matches `release/build.sh`.

### Follow-up: full MPL text and the Ubuntu config line (2026-10-16)

- The bundle now carries the full MPL-2.0 text beside the binary: `build_satellite` shallow-clones the tag
  (`git clone --depth 1 --branch v0.8.3`) in the scratch folder, checks the first line of `LICENSE` is the Mozilla Public
  License, and stages it as `share/licenses/xwayland-satellite/LICENSE` next to `NOTICE.txt` (which keeps the source
  address and now also the commit). The release selftest checks no licences for any component, so it asserts nothing new.
- casement has a path setting (casement 5ea8b42, `config/sections/xwayland.rs` and `xwayland/resolve.rs`): key
  `satellite` in the `[xwayland]` table of `$XDG_CONFIG_HOME/casement/settings.toml` (default
  `~/.config/casement/settings.toml`); a value with a `/` is used as the full path and is not expanded (no `~`), empty means
  look in the PATH; it takes effect at the next login. So the Ubuntu note no longer asks for `sudo install`: it prints the
  cargo line (as yourself, never root) and then `satellite = "<home>/.cargo/bin/xwayland-satellite"` with the path to the
  file, and says the person writes it. The installer writes nothing there. `gate/distro-check.sh` and `docs/distros.md`
  match. Not run on a machine: that casement reads the key as described (read from its source only).
