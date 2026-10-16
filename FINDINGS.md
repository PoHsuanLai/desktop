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
