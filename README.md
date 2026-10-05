# desktop

The meta repo of the desktop program (quire, sill, shell-host, casement and the rest): the
version manifest, the test jail and the whole-desktop gate. No Rust, no product code.

| Path | What |
|---|---|
| `manifest.toml` | which rev of which repo works with which; wire protocol versions |
| `harness/jail.sh` | the one jail: a bubblewrap namespace with no input devices, no GPU, no session, no network |
| `harness/lib/` | `require_jail`, step timing and exit codes, budgets, run ids, a private dbus-daemon |
| `harness/scenario-build.sh` | outside the jail: builds what the scenarios run (casement tools, foot, sill, shell-host's demos) into the git-ignored `build/`; the gate runs it first |
| `harness/selftest.sh` | proves the jail holds (`--all` also runs the negative check outside) |
| `gate/desktop-gate.sh` | `--self`, `--merge`, `--phase P<n>`: prints `DESKTOP GATE GREEN (<tier>)` |
| `gate/manifest-check.sh` | every Cargo.lock agrees with the manifest, and resolves `--locked` against the pinned siblings |
| `gate/expected-skips.toml` | scenarios not runnable yet, each with a finding id and the closing phase |
| `scenarios/` | whole-desktop scenarios; each calls `require_jail` first and exits with the plan's codes |

Nothing that can see input devices, a GPU output or the user's session runs outside
`harness/jail.sh`. Exit codes: 0 pass, 1 test failed, 2 could not run safely (a SKIP, fails unless
listed), 3 environment incomplete, 4 budget overrun, 5 jail breach.

The lane gate for every other repo is `~/rs-wt/gate-lane-jailed.sh <repo dir> [args]`: fmt, clippy
and the nextest archive build outside, the tests inside `harness/jail.sh`.

Conventions: the casement-scope plan (`~/rs-wt/compositor-scope/20-FREEZE-PLAN.md`) sections 3, 4.14
and 6; shell code follows the style of `~/sill/dev/lib`.
