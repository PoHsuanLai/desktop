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
- slipway: no installer yet. build.sh stages `bin/slipway`, `libexec/slipway-apply` and a copy of its `dist/`
  under `share/slipway/dist`; its units, polkit action and `/usr/share/slipway/release.pub` need an
  installer with the same flags. It is not in `manifest.toml`, so the workflow builds it at the
  `slipway_ref` input and `release.toml` records its rev; it should join the manifest.
- transom: named in the brief, but no repo beside this one and no entry in `manifest.toml`; not built.
  Add it to `ALL` and a `build_transom` in `release/build.sh` when it exists.

Things the bundle cannot export (outside the allowed directories) and so cannot activate by itself; they sit
in the bundle as data and need slipway's privileged apply step, or the bootstrap, to install:
`share/sill/pam.d/sill` (needs `/etc/pam.d/sill`), `share/keycap/` (system unit, udev and polkit rules, the
Plasma overlay), `share/palmrest/` (udev rule, modprobe file), porter's caller table at `etc/porter/callers.toml`
(porter reads `/etc/porter/callers.toml`; the installer's `--sysconfdir` was pointed under the prefix) and the
`/usr/lib/systemd/user` units that name `/opt/quire/current` paths. `share/sill/keycap.toml` is the sill
session's keycap layer, which sill's installer copied into the home. Decide with the slipway lane whether
the allowed export set grows (`/etc/pam.d`, `/etc/porter`, `/usr/lib/systemd/system`, `/etc/udev/rules.d`,
`/usr/share/polkit-1/rules.d`) or those stay a bootstrap step.

Other choices: file modes are normalised to 0644 or 0755 (executable bit kept) so the bundle does not depend on
the builder's umask; the date is the packing time (`SOURCE_DATE_EPOCH` overrides it); `release/release.pub`
is committed by the owner and the CI refuses to publish without it.
