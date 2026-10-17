# Real-app workflow timing

How fast do real apps open on our desktop, how fast do windows switch, how fast does the file dialog
appear, how long does login take, and where does the time go? These scripts answer that on **your real
login, on your real GPU**, when you want to know. They are not part of the gate, CI or the release, and
they refuse to run in the test jail or outside the sill (casement) session.

Run them in a terminal inside the session:

    workflow/run.sh                       # everything, about 15 minutes
    workflow/run.sh --part launch         # only the launch timings
    workflow/run.sh --apps foot,blender --rounds 10
    workflow/selftest.sh                  # checks the scripts themselves on fixtures; needs no session

The scripts never install anything. An app that is not installed is skipped, with the command that would
install it on your distribution (apt, dnf or pacman is detected).

## What it measures

The desktop writes a few timing lines to its log for every window that opens, every change of the focused
window, and every login (casement: `window-ready`, `key-window`, `xwayland-ready`, `session-ready`; sill:
`launch`). The lines hold only app ids, process numbers and clock readings, never titles or file names.
`workflow/lib/timing.py` reads them from the user journal and from the session's `casement.log`, pairs a
launch with the window it produced, and does the arithmetic. Every time is on one clock (CLOCK_MONOTONIC), so
the differences between lines from different programs are exact.

**launch** (per app: one first launch of this run, then N warm launches, five by default). Each launch goes
through `sill launch <app> --print-timing`, the same path as a click in the Dock. The app is then closed
politely (its unit is stopped, or the process gets SIGTERM) before the next round. Stages, in order:

| Stage | What it is | Whose time |
| --- | --- | --- |
| request -> process started | sill gets the request until the app's process exists | sill |
| started -> connected | the process starts up until it connects to the desktop | the app |
| connected -> first picture | the app sets up and draws its first picture | the app |
| first picture -> on screen | the desktop puts that picture on the screen | the desktop |
| on screen -> settled | the opening animation | the desktop |
| TOTAL request -> on screen | everything up to the first visible frame | all |
| TOTAL request -> settled | everything up to the end of the animation | all |

A process can connect before sill has noted its number; then "started -> connected" would be negative and is
shown as 0 (raw.tsv marks the row). "Cold" means the first launch of this run: the app's files may still be in
memory from earlier, so for a truly cold start log out and in again, or drop the file cache as root, before
running. For an X11 app the first launch also records "X11 bridge start" (how long the bridge to X11 programs
took to answer); if it was already running from earlier in the session nothing is recorded and run.sh prints a note.
For each app it also records which GPU the app (and its child processes, such as a browser's GPU
process) had open, named as `lspci` names it. "none" means the app drew in software or through shared memory.

**switch**: with two or three of the apps open, you press Cmd+Tab ten times, then click between the windows
five times. For each change of the focused window: input -> focused (the key press or click until the desktop
made that window the key window), focused -> on screen (until the first frame showing it), and the total.
Changes without an input time (an app asking for focus) are left out. The script prints how many changes it
saw so you can see if some were missed.

**dialog**: the first and second file chooser, asked of the portal over D-Bus (`gdbus`), timed from the
request until the dialog's window is on screen. You press Escape to close each. The first is "cold" (the
portal may have to start; if it was running already it is warm too). The time includes about 30 ms of `gdbus`
starting up, because the clock is read just before the tool starts.

**login**: the `session-ready` line of this boot: casement started -> the shell program connected -> the bar
and dock on screen.

**checks**: five yes/no questions only a person can answer (typing in each app, copy from Firefox to foot,
drag a file from the Files app into Firefox, Blender full screen and back, resizing a big Blender window).
Answer y, n or s (skip); after n you can type one line about what you saw.

## The numbers

Every row of a table has: **cold** (the first launch of this run), then **p50** (the typical case: half the
launches were faster), **p95** (nearly the worst case), **max**, and **n** (how many warm launches). With five
rounds the p95 is the second-worst value, so it is close to the max; use `--rounds 20` for steadier tails. All
times are milliseconds.

## Where the results go

`${XDG_STATE_HOME:-~/.local/state}/quire-workflow/<date-time>/`

- `raw.tsv`: one row per measured event (part, app, phase, round, stage, value in ms, a note). The GPU of an
  app is a row with stage `gpu` and the name in the note column.
- `summary.txt`: the tables above, the GPU per app, the comparison with the previous run, the checks, and at
  the end **where the time went**: the three biggest stages across the apps, in plain words.
- `answers.txt`: your answers to the checks.

The summary compares with the previous run in the same folder and flags any stage whose p95 grew by more than
25% and more than 20 ms. Both limits are needed so a 3 ms stage cannot "double" and a 400 ms stage cannot
"grow" by noise.

## Which apps

`apps.toml` lists them: Firefox, foot, Blender, a GTK4 app (GNOME Text Editor, else the GTK4 demo), a Qt6 app
(KWrite, else KCalc) and an X11 app (xterm, else xeyes, which has no desktop entry and so cannot be launched
by sill). Pick some with `--apps firefox,foot,blender,gtk4,qt6,x11`. Add an app by copying an entry; the file
explains each field and which ids were checked on which distribution.

## Notes

- It needs a build of sill with `sill launch <id> --print-timing` and a casement that writes the timing lines.
  With an older build the launch part says so and measures nothing.
- Timing lines come from the user journal and from `$XDG_RUNTIME_DIR/desktop-session/casement.log`
  (override with `DESKTOP_SESSION_STATE`); whichever has them is used.
- Do not use the machine while a launch round runs: other windows opening at the same time can be mistaken
  for the app's window (the match is by window id and process number, so it is rare).
- Exit codes of `run.sh`: 0 finished, 1 some measurement failed (lines marked FAILED), 2 usage, wrong
  session or a missing tool.
