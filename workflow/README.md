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

## W1: from a product page to a Blender model

`workflow/w1-blender.sh` runs one designer workflow on your real login, on demand (never in CI): you browse a product
page, open the launcher, ask the assistant to get the specs of the thing on the page, and the assistant opens Blender,
has several helpers model it, and saves a `.glb` file. The script builds the stage and measures; it does not drive
Blender in any special way. The assistant looks at the screen and works the apps like a person would, and may find
faster ways itself, asking you first.

What it sets up, all in a scratch folder (`~/.cache/w1-runs/<date-time>`, or `--run-dir`), never touching your own
files, settings or message bus:

- a window of our desktop inside yours, with the shell (bar, dock, launcher);
- the assistant's services on a private bus of their own, with its model log switched on;
- the screen helper, with computer use turned on only for Blender and your browser, each set to ask first;
- a made-up product page (a desk lamp, with sizes in millimetres, a parts list, colours and a drawing) served on this
  computer only, from `workflow/fixtures/w1/`;
- Zen (else Firefox) opened on that page, and the launcher shown.

You choose the models yourself; there is no default. Set `W1_PLANNER_URL` (the assistant's own model) and
`W1_SCREEN_URL` (the model that looks at the screen), each as an address on this computer such as
`http://127.0.0.1:8090`. For the screen model on fatcat use the end of a tunnel. The script only checks that each
answers; it never starts one. If the screen model does not answer it says "start the screen model on fatcat, then run
again". Start it only when you are ready and stop it after the run.

    W1_PLANNER_URL=http://127.0.0.1:8090 W1_SCREEN_URL=http://127.0.0.1:8091 workflow/w1-blender.sh
    workflow/w1-blender.sh --print-build      # the builds it needs, for whoever builds
    workflow/w1-selftest.sh                   # checks the script's own parts on canned input; needs no session

The desktop window asks you the first time each program connects (the screen helper, the launcher, the apps); say
Allow. With `--floor-dir DIR` (a root-owned folder you supply; a proposal is written to `<run dir>/floor`) it asks less.

Then it prints one sentence to say to the assistant, for example "Get the specs of the lamp on this page, then build it
in Blender with a few helpers and save it as a .glb file in <run dir>/out". Say it in the launcher, or run with
`--drive` and it sends the same sentence for you after you press Enter. If the assistant needs you to answer a
question, answer it in the window; the script keeps waiting until the file appears, the time is up (`--timeout`,
3600 s by default) or you press Ctrl-C. On the way out it always writes the report and stops everything it started.

### What the report checks

`report.md` in the run folder. Checked by the script:

- a `.glb` file was saved in the run folder;
- Blender, run in the background on that file afterwards (the only Blender scripting here), opens it and finds at
  least five separate shapes (the page lists five parts);
- the overall size is within 10% of the page's 285 x 160 x 228 mm, in whatever order the axes are and whether one unit
  is a millimetre, a centimetre or a metre;
- the turn did not end in the guard's words ("Couldn't do that", "I keep getting the same answer", "stopped:", "That is
  done").

Recorded, not judged: the time of each stage (page shown, request given, first answer, first look at the screen,
Blender shown, file saved), the turns of the assistant and of each conversation, the number of looks at the screen and
when they began, pictures of the window at each stage change (with `grim`, if installed), and the files made during the
run. Left to you, by eye: that every install or first run of a new tool was asked about first, that nothing was written
outside the run folder, and that you could still use the computer without delay.

Limits: the model log has no helper names, so turns are grouped by the opening words of each conversation's
instructions; and the screen helper's steps are counted from the model server's own log of calls that carried a
picture. The Blender window id the screen helper is allowed to use is `org.blender.Blender` (unverified window id; the
settings pattern needs a dot, so a plain `blender` cannot be listed). The timing lines for the browser and Blender
windows are read from the desktop window's log; if that build does not write them, those two stage marks are missing.

Exit codes: 0 every checked criterion passed, 1 the run did not finish or a criterion failed, 2 bad usage, a missing
program or model, or not a Wayland desktop.

## W2: from a product page to a drawing

The same lamp page, a different job: you ask the assistant to get the lamp's specs and draw its front view, with sizes,
in a drawing app, using a few helpers, and to save the drawing. The drawing app is Excalidraw, built offline from pinned
packages, so it needs no graphics card, no account and no network. The assistant uses it only through the screen: it
opens the drawing tab, and its helpers draw the base, the arms, the joint and the shade by looking and clicking. Nothing
in the script talks to the drawing app; the saved file is read once, afterwards, to check it.

**It runs in the test jail**, not on your login. A nested window on your real session cannot trust a shell built from the
source tree, so there the launcher and the questions would never appear. In the jail the desktop is the headless test
build, and nobody is there to press buttons: the script answers every confirmation sheet for you with "Allow once" (the
brief sheet with "Use this brief", which sends the brief's words back unchanged) and writes each one into the report.
Pictures of the desktop at each stage change, and every `W2_SHOT_EVERY` seconds, go in the run folder.

    # once: the offline drawing app (needs node and npm)
    workflow/fixtures/w2/build-excalidraw.sh
    # once, and after a change in the sources: the test builds (outside the jail)
    workflow/w2-excalidraw.sh --print-build        # the list; `harness/scenario-build.sh --w2` does it all
    # a run
    W2_PLANNER_SOCK=... W2_SCREEN_SOCK=... workflow/w2-excalidraw.sh
    workflow/w2-selftest.sh                        # checks the script's own parts on canned input; needs no session

What it needs:

- **The screen model.** There is no default, and the script refuses plainly without it (and without the assistant's own
  model). The jail has no network, so each model is reached through a Unix socket on this computer, which the jail
  bridges to a port of its own: `W2_PLANNER_SOCK` and `W2_SCREEN_SOCK` (or `W2_PLANNER_URL=unix:/path` and
  `W2_SCREEN_URL=unix:/path`). For the screen model on fatcat, open the tunnel and bridge its port to a socket only when
  you are ready, and close both right after, for example
  `ssh -N -L 8091:127.0.0.1:8000 fatcat &` then `socat UNIX-LISTEN:$HOME/w2-screen.sock,fork,mode=600 TCP:127.0.0.1:8091 &`.
  The assistant's own model is bridged the same way from wherever it runs. The script never starts a model.
- **The test builds** of casement, the shell, the screen helper and the assistant's services (`--print-build`), and the
  offline drawing app. Zen is read from `~/.local/opt/zen/zen` (`W2_BROWSER` to change it). The jail already shows the
  host read-only, so neither Zen nor the drawing app needs a bind of its own.
- **bubblewrap** and `/dev/udmabuf`, as for any test-jail scenario.

It is not part of the gate: the scenario carries an `# opt-in:` line, which the gate skips. The run folder defaults to
`~/.cache/w2-runs/<date-time>`; the saved drawing is in `scenario/w2-excalidraw/out/` and the report is `report.md`.

### What the W2 report checks

- a `.excalidraw` file was saved in the run folder (the browser is set to save downloads there, with no question) and it
  reads as a drawing file;
- it holds at least four shapes (rectangles, ellipses, diamonds, lines or strokes; arrows and text do not count);
- its text holds the lamp's three sizes, 285, 160 and 228 mm, with any reasonable spelling ("285 mm", "285mm",
  "28.5 cm");
- the base's width, the total height and the shade's width stand in the page's proportions to within 15%, whatever the
  drawing's scale (the scale is taken from one known size);
- every brief sheet was answered with its words unchanged;
- the turn did not end in the guard's words.

Recorded, not judged: the exported `.svg` picture, if one was saved (optional), every sheet answered and how, the stage
times, the turns of the assistant and of each helper, the looks at the screen and the pictures. Left to you, by eye: that
the drawing looks like the lamp, and that the assistant used only the screen.

Limits: the window id the screen helper is allowed to use is `app.zen_browser.zen`, which the script asks Zen to use as
its window name (unverified; the settings pattern needs a dot). The sheet answers go through the shell's debug keys:
Return for Allow once and for "Use this brief" (a short brief counts as read at once). A sheet that asks for a hold is
answered with Tab and a held Space.
