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

## Production audit lane pa-desk (2026-10-16)

Written without a compiler, a systemd user manager, polkit or minisign; nothing here was run except `bash -n`. What to
check first is listed under "Not verified" at the end of this section.

### ROOT-03: the crash guard consults slipway

- `session/desktop-session` runs `"$(bin slipway)" recover` once, before the respawn loop, and only when it is not a nested
  test run and slipway is installed (`have slipway`). Exit 5 (the previous version was put back) is logged as "the latest
  update did not start; the previous version was put back" and the session starts the restored version; any other nonzero
  exit is logged and the session starts anyway. slipway's own words go to guard.log.
- guard.log moved from `$XDG_RUNTIME_DIR` (erased at the end of the session, which is when it is needed) to
  `${XDG_STATE_HOME:-$HOME/.local/state}/desktop-session/`, created at start, moved to `guard.log.1` once past 256 KiB.
  casement.log stays in the runtime folder (the drop-in appends to it and the socket name is read from it).
  `DESKTOP_SESSION_STATE` (tests) still puts both in one folder.
- When the guard ends the session it prints `pkexec /usr/libexec/slipway-rollback` (only where that program is
  installed; `DESKTOP_SESSION_ROLLBACK_HELPER` overrides the path for tests). That command asks for the administrator's
  password, by the owner's decision.
- **Not closed, needs a decision (slipway FINDINGS 22):** slipway counts different boots, so a crash loop inside one boot
  (login screen, log in, guard ends the session, log in again) is not rolled back until the computer restarts; the manual
  line above is the only way back within a boot. Closing it needs the guard to tell root, on a channel a program of the
  person cannot forge, that the session was ended by the guard; there is none today and none is invented here.
- The scenario `session-crash-guard` checks the way-back line and that guard.log is in the state folder while casement.log
  stays in the runtime folder. The `slipway recover` call itself is not testable there (it is skipped when nested, which is
  the only way that scenario runs); see the release scenarios below.

### ROOT-02: the update service starts in every login; sill confirms the start

- `session/desktop-session.target` now has `Wants=slipway.service`, so the daily check runs without anyone enabling the
  unit (slipway's `scripts/install.sh` deliberately does not enable it: that would write under the home folder). A computer
  without slipway has no such unit and the line is ignored. `gate/installer-check.sh` checks the staged target has the line.
- The session does **not** run `slipway confirm`: sill does, about 30 s after the shell answers (sill lane, landing
  separately). **Landing order matters:** with `slipway recover` in the session and no `slipway confirm` anywhere, every
  update would be put back after its third restart of the computer. Land (and pin in `manifest.toml`) the sill revision that
  confirms before or together with this commit. Nothing in this repo can check that; it is the release gate's job.
- slipway also installs a D-Bus activation file for the update service, so a call to it (Settings, `slipway status`)
  starts the unit in a login that does not have the target; the target line makes it deterministic.

### ROOT-07 (desktop half): system files are named one by one

- slipway's helper now accepts a system file only when a rule of `ALLOWED_SYSTEM_FILES` names it (13 rules, file by
  file; the folder list is gone). `release/system-files.list` is the committed copy, `release.py` reads it
  (`system_ok`, so `pack` and `verify` refuse any other path), `release/check-system-list.sh` compares it with slipway's
  Rust source, and the `small` build job runs that check against the pinned checkout. The selftest renders the list in
  slipway's format and checks equal, one rule missing and one rule extra, packs with four unnamed files (a polkit rule in an
  allowed folder, a second PAM file, an unnamed udev rule, `/etc/quire/callers.toml`, which does not end in `-callers.toml`
  with something before it) and forges one more hostile release (`system-unnamed`). The selftest ran here (minisign 0.12): pass.
- `manifest.toml` moves slipway from aa427f2 to 769704c, the tip with the exact list, the three helpers and the session
  calls. The release cannot be installed by the older helper once it carries a path the older list does not name; the
  hand-installed helper must be replaced on each computer (slipway's `scripts/install.sh`).
- Every file `build.sh` stages is on the list. porter, almanac, docket and cua stage their caller tables through their own
  installers, so a name they write that the list does not cover is only found when `pack` runs in CI.
- Superseded wording above: "allowed system folders" (this file and the README) now means the list; the stale line in
  "Whether the release should write `/etc/pam.d` at all" is answered: one file, `/etc/pam.d/sill`, named.

### Packaging: slipway's three programs and one polkit file

- slipway's `scripts/install.sh` (origin/master 769704c) installs `slipway-apply`, `slipway-rollback` and `slipway-health`
  in `PREFIX/libexec`, `org.quire.slipway.policy` (three actions) in `PREFIX/share/polkit-1/actions`, the user unit and bus
  file, `/etc/slipway/config.toml` and, with `--pubkey`, `/usr/share/slipway/release.pub`. The desktop's own `install.sh` does
  not run it (it needs root and a key, and builds with cargo's defaults: ROOT-17's linker and root-build points stay with
  slipway); the desktop's path is `release/bootstrap.sh` after it, and both now say so.
- New `release/check-helpers.sh` holds the install to the owner's decisions: the three programs exist, are root-owned and
  not group/other writable; the policy has exactly the three actions, each naming its program; apply and health allow only an
  active local session without a password, rollback is `auth_admin_keep`. `smoke.sh` now installs the three programs and the
  policy the way slipway's install does and runs it before the release; `bootstrap.sh` runs it before it asks for anything.
  The workflow's `small` job uploads all four slipway programs and the policy file (artifact `helper`). The selftest covers
  a complete install, a rollback without a password, a missing program and a group-writable one.
- `docs/distros.md` has a short "Updates" section (what is installed where, the password rules, the by-hand way back).
- Not verified: `scripts/install.sh --bin-dir` flow on a real machine; that polkit follows the policy file's `exec.path`
  to `/usr/libexec/slipway-*` on Fedora and Arch as on Ubuntu (it reads the path, not the distro).

### CI scenarios for the start check (ROOT-02, ROOT-03)

- `release/health-scenarios.sh` and the workflow job `health` (publishing waits for it). Scenario 1: install two signed
  releases, two logins each running `slipway recover` then `slipway confirm`, four more restarts: the newest release stays.
  Scenario 2: install two, six starts inside one restart (not counted), then restarts that never confirm: the third makes
  `slipway recover` exit 5 and say the previous version came back; the next three leave it alone; a newer release starts
  its own count. The releases are made with the repo's own `pack.sh` and a throwaway key; the programs are slipway's real
  ones.
- **The gap:** `slipway-health` reads the boot id from a fixed path and the settings from `/etc/slipway/config.toml`, and
  pkexec clears the environment, so no variable can stand in for them. The scenario therefore needs root and the right
  to mount: it binds a made-up boot id over `/proc/sys/kernel/random/boot_id` (a `--privileged` container job) and puts a
  stand-in `pkexec` (runs its arguments; the container is already root) first on the path. It cannot run in the jail
  (`scenarios/` is unprivileged, with no mounts) and so is not part of `desktop-gate.sh`; the gate's checks of it are
  `bash -n` only. The jail-run `session-crash-guard` cannot cover `slipway recover` because the session skips it when nested.
  A seam in slipway (a boot-id file and a settings path taken from an environment variable that only a non-setuid run
  honours) would let it run unprivileged; it is not asked for, since a root helper must not read either from its caller.
- Not verified: that a hosted runner starts a container with `--privileged` and allows `mount --bind` over a procfs file
  (Docker mounts `/proc/sys` read-only without `--privileged`); that `slipway confirm` creates its state folders under the
  scratch home; the exact words of `slipway recover` when it restores (the scenario looks for "previous version").
  If `mount` is refused the script exits 2 and the job fails; that is the signal, not a pass.

### ROOT-18: the jail hides the person's keys (partly)

- `harness/jail.sh` showed the whole host read-only, including `~/.ssh`, `~/.config/quire-release` and API-key files, and a
  `--bind` dir is writable: code run in a lane could copy a key into the worktree. `harness/secret-paths.list` now names the
  places keys live (14 folders, 7 files); the jail covers each that exists with an empty folder or an empty file, and
  sets `JAIL_REAL_HOME` so `selftest.sh` checks they read empty (verified here: `selftest.sh --all` passes, `.ssh`,
  `.gnupg` and `~/.cargo/credentials.toml` show empty inside).
- **Deferred, a decision:** the verified fix is an allow-list (show only `/usr`, `/etc/os-release`, the worktree and scratch).
  Lanes also read `~/.cargo`, `~/.rustup`, the sibling checkouts and the gate's build directories under the home folder, so
  an allow-list needs a pass over every scenario and the lane gate to find what they read; I could not run those here. A
  list of known places misses a key kept somewhere new, so a new kind of secret needs a line in the list.
- `--cap-drop`, `--unshare-uts` and a seccomp filter (also in the finding) are not added: the user namespace already has
  no capabilities outside it, and a filter needs the same lane-by-lane test.

### ROOT-08: what builds the signed release is pinned

- rustup: `release/install-rustup.sh` downloads `rustup-init` 1.29.1 for x86_64 from `static.rust-lang.org` and checks its
  SHA-256 (dda72343...; read from the published `.sha256` and from the downloaded file on 2026-10-16) instead of
  `curl sh.rustup.rs | sh`. Any other version needs `--sha256`. The toolchains themselves still come from rustup's
  own signed manifests.
- Container: the build jobs and the `health` job use `ubuntu:24.04@sha256:534baea6...` (the index digest on Docker Hub,
  read 2026-10-16). It does not follow Ubuntu's security rebuilds until someone bumps it; apt inside it is still
  unversioned (the archive is signed and the base is fixed; pinning every package version would break at the first archive
  update and was not done). smoke keeps `fedora:44` and `archlinux:latest` moving on purpose: they only test, they sign nothing.
- xwayland-satellite: `SATELLITE_REV` (b83eab90..., the commit `v0.8.3` names) replaces the tag in the build; the commit is
  fetched once, verified by `rev-parse`, built with `cargo install --locked --path`, and the licence, the notice and the
  component record come from the same checkout (the second clone is gone). `gate/distro-check.sh` checks the value is a
  full commit hash. The source-install line for people in `install/packages.sh` and `docs/distros.md` still says
  `--tag v0.8.3` (it is typed by a person, not by CI).
- Cache: `restore-keys` is gone, so a cache is restored only for exactly this manifest. Cost: the first build after a
  manifest change is cold (casement and sill take the longest).
- Not verified: that `git fetch --depth 1 <url> <full sha>` is accepted by GitHub for that repository (it is for public
  repositories that allow reachable-sha fetches, as GitHub does), and that `cargo install --path` of the repository root
  installs only `xwayland-satellite` (its root `Cargo.toml` is a package that is also a workspace root; read from
  the file at that commit).

### ROOT-09: the signing key is in a protected environment

- The workflow's `pack` job runs in the environment `release-signing` (the signing key and its password) and `publish` in
  `release-publish` (the token that can create a release in desktop-releases); the `prepare` job also refuses any ref but the
  default branch and `v*` tags. The pack job checks `release/release.pub` is committed, and that the environment has a key,
  before it signs anything, and prints the public key's id line in every run. `release/README.md` "What you do once" steps 3,
  5 and 6 are the owner's one-time commands (create both environments with a reviewer and branch/tag restriction, a tag ruleset
  on `v*`, set the secrets in the environments, delete any repository-level copies). Nothing was created: no repository,
  secret, environment or key.
- Until the owner has done that, the run stops at `pack` with a message naming the missing piece. `release/release.pub` is not in
  the repository (only the owner can make the key), so the first release also needs step 3.
- **Needs a decision:** a second signer and a list of next keys (so a key can be rotated without every person reinstalling the
  helper) need a change in slipway's `PublicKey` and a new helper on every computer. Not done.
- Limits: environment rules protect the secrets from a pushed branch, not from someone who can change the default branch or
  push a `v*` tag; approvals are a click by the owner, who is also the only reviewer.
