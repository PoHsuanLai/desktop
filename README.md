# desktop

The meta repo of the desktop program (quire, sill, shell-host, casement and the rest): the
version manifest, the test jail and the whole-desktop gate. No Rust, no product code.

| Path | What |
|---|---|
| `manifest.toml` | which rev of which repo works with which; wire protocol versions |
| `install.sh` | installs the desktop: runs each component repo's own installer in order (porter, stoker, almanac, docket, cua, detent, casement, sill, transom, keycap, anyview, mailo, palmrest, session) and the colour emoji font; `--check` lists what the machine lacks with the exact dnf, apt or pacman line; see below and `docs/distros.md` |
| `docs/distros.md` | Ubuntu 24.04+, Fedora and Arch: what is checked, the install lines, picking the session at login, the Ubuntu AppArmor note |
| `install/` (helpers) | `distro.sh` (family from os-release, sudo/doas/pkexec), `packages.sh` (the one package table), `check.sh`, `cargo.sh` (builds a tree from `/` with `--manifest-path`, so the system linker is used), `fonts.sh` |
| `fonts/` | `Noto-COLRv1.ttf` (OFL) with its source and sha256: Ubuntu and Arch ship a bitmap emoji font our renderer cannot draw |
| `gate/distro-check.sh` | the family detection, package table, escalation, the cargo helper and `--check` against made-up machines |
| `harness/jail.sh` | the one jail: a bubblewrap namespace with no input devices, no GPU, no session, no network |
| `harness/lib/` | `require_jail`, step timing and exit codes, budgets, run ids, a private dbus-daemon |
| `harness/scenario-build.sh` | outside the jail: builds what the scenarios run (casement tools, foot, sill, shell-host's demos, detent at its pin, transom) into the git-ignored `build/`; the gate runs it first |
| `harness/selftest.sh` | proves the jail holds (`--all` also runs the negative check outside) |
| `gate/desktop-gate.sh` | `--self`, `--merge`, `--phase P<n>`: prints `DESKTOP GATE GREEN (<tier>)` |
| `session/` | the "sill (casement)" login: `desktop-session` (casement as the session's compositor child, with sill beside it; the portal is transom, started by D-Bus activation, `XDG_CURRENT_DESKTOP=quire`, and the crash-loop guard: three quick exits, then `casement --safe`, then the session ends with a guard log line that also names `pkexec /usr/libexec/slipway-rollback` as the way back by hand; the log is kept in `$XDG_STATE_HOME/desktop-session/guard.log`, and before the first casement starts the session runs `slipway recover`, which puts the previous version back when the latest update failed to start in several restarts of the computer; your other session stays available at the login screen), the wayland-sessions entry, `quire-portals.conf`, `desktop-session.target` (which also wants `slipway.service`, the update service, so its daily check runs in every login) |
| `release/` | signed release bundle of the whole desktop: `build.sh` (components at their manifest revs, staged under `/opt/quire/current`), `pack.sh`, `verify.sh`, `system-files.list` (the system files a release may place, slipway's list), `check-helpers.sh` (slipway's three privileged programs and its polkit file are all in place), `health-scenarios.sh` (the start check: good logins keep a release, failed starts put the previous one back), `selftest.sh` (in `gate/desktop-gate.sh --self`), `README.md` (what to set up once and how to cut a release); built by `.github/workflows/release.yml` and published to the public PoHsuanLai/desktop-releases |
| `install/` | `install.sh` and `uninstall.sh` for `session/` (`--dry-run`, `--prefix`, `--destdir`, `--sysconfdir`, `--sessions-dir`); never sudo, never `$HOME`; the uninstall removes exactly the files the install wrote, and only while they are unchanged |
| `gate/installer-check.sh` | `install.sh` against stub installers in a scratch dir: the dry-run plan and order, PREFIX/DESTDIR passed through, stop at the first failure, no sudo, nothing written to the home |
| `gate/manifest-check.sh` | every Cargo.lock agrees with the manifest, and resolves `--locked` against the pinned siblings |
| `gate/sill-accept-skips.txt` | the scripts of sill's `dev/accept.sh --compositor casement` that may SKIP in the phase gate, with the closing phase |
| `gate/expected-skips.toml` | scenarios not runnable yet, each with a finding id and the closing phase |
| `scenarios/` | whole-desktop scenarios; each calls `require_jail` first and exits with the plan's codes |
| `harness/lib/accounts.sh` | what the `accounts-*` scenarios share: porter's real daemons (accountd, syncd, inferd) and porter's test rig (`porter-rig-servers`, `-client`, `-secrets`) on casement's private bus with sill drawing the sheets and detent as Settings; the caller identities (a fixture /proc for the daemons' `test-proc-root` builds); the secret scan (`secret-scan.py`) over a `busctl monitor` record |
| `harness/lib/regress.sh`, `pixels.py`, `sheet-bus.py` | what the `accounts-regress-*` scenarios share: checks that fail a step (`must`), the sheet's traffic read from the recorded bus (what accountd shows it, what the keys sent back), and measurements of a capture (the card's box, equal pixels, dark text, contrast). sill's surfaces write no debug probe (shell-host does not run ds-blitz's), so the sheet is read this way; detent's controls are read by role and name |

## Installing

`./install.sh [--dry-run] [--prefix DIR] [--destdir DIR] [--sysconfdir DIR] [--siblings DIR] [--only NAME,...]`
runs each component's own installer, siblings checked out side by side, in this order: porter
(`scripts/install.sh`: the daemons and the caller table), stoker (`scripts/install.sh`: the model catalogue inferd reads;
nothing is built), almanac (`scripts/install.sh`: the memory daemon, its unit
and `/etc/quire/memory-callers.toml`), docket (`scripts/install.sh`: the action router, the companion, the reader, the tool
server and `quire-do`, with their units and the `/etc/quire/*-callers.toml` tables; they read porter's accounts, so they come
after it), cua (`scripts/install.sh`: the helper that lets the assistant use apps that are not ours, its unit and
`/etc/quire/cuad-callers.toml`; it needs at-spi2-core at run time), detent (`scripts/install.sh`: Settings, which
porter's caller table knows as the unit `org.quire.Settings.service`), sill (`dist/install.sh`), transom
(`scripts/install.sh`: the portal backend for screen sharing and screenshots, started by D-Bus activation), keycap,
anyview, mailo, palmrest, then the session itself (`install/install.sh`: `desktop-session`, the user target, the login entry; it never runs sudo and prints the root command when a place is not writable) (casement, with its unit, goes between detent and sill; it is skipped with a message until casement's `scripts/install.sh` exists). `--prefix` (default `/usr/local`) and `--destdir` are passed through in the form each
installer takes; the first failure stops the run and names the component and what was installed before it.
`--dry-run` prints the plan and runs and builds nothing.

It never runs sudo and never writes under `~/.config` or `/etc` itself. A component runs only when every place
it writes is writable by you (a user prefix, or a `--destdir`); the rest are printed as "yourself", with the
command, to run with the right privileges: a system prefix, sill and palmrest (fixed destinations, their own
sudo or home files), keycap outside a `--destdir`, stoker outside a `--destdir` (its installer asks for sudo itself), and almanac, docket and cua outside a `--destdir` (their caller tables go to the
fixed `/etc/quire`; their installers refuse to run as root and ask for sudo for just those steps, so the command is
printed to run as yourself). Neither takes `--sysconfdir`. `gate/installer-check.sh` tests all of this against stub
installers.

Nothing that can see input devices, a GPU output or the user's session runs outside
`harness/jail.sh`. Exit codes: 0 pass, 1 test failed, 2 could not run safely (a SKIP, fails unless
listed), 3 environment incomplete, 4 budget overrun, 5 jail breach.

The lane gate for every other repo is `~/rs-wt/gate-lane-jailed.sh <repo dir> [args]`: fmt, clippy
and the nextest archive build outside, the tests inside `harness/jail.sh`.

Conventions: the casement-scope plan (`~/rs-wt/compositor-scope/20-FREEZE-PLAN.md`) sections 3, 4.14
and 6; shell code follows the style of `~/sill/dev/lib`.
