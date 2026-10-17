#!/usr/bin/env python3
"""The helper behind workflow/run.sh: parse the timing lines, pair them, compute the numbers.

Standard library only; run it as `python3 -I workflow/lib/timing.py <command> ...`.

Commands (run.sh uses them; selftest.sh runs them on fixtures):
  now                                  print CLOCK_MONOTONIC in nanoseconds
  apps --file apps.toml [--only k,k]   which apps are installed, tab separated (see cmd_apps)
  pick EVENT                           stdin -> the first EVENT line found, in canonical form
  field LINE KEY...                    the values of KEY... in LINE, tab separated
  wait --app-ids a,b ...               wait for the matching window-ready line, print it
  rows --kind launch|dialog ...        the stage rows (raw.tsv format) for one launch or dialog
  gpu --pid N                          which GPU the process and its children opened
  switch --from NS --until NS          the key-window rows between two instants
  login                                the session-ready rows of this boot
  xwayland --after NS --app KEY        the xwayland-ready row of the first X11 launch
  dialog-open --token T                ask the portal for a file chooser, print the instant asked
  summarize --raw FILE ...             the summary text, the trend and "where the time went"

The sources of the timing lines are the user journal and the session's casement.log (the session
script appends casement's stderr there); --log-file FILE (repeatable) replaces both, for tests.

Exit codes: 0 done; 1 nothing found (wait timed out, no event); 2 bad usage or an unreadable input.
"""
import argparse
import math
import os
import re
import shutil
import subprocess
import sys
import time
import tomllib
from collections import defaultdict, namedtuple
from pathlib import Path

NS_PER_MS = 1_000_000
ANSI = re.compile(r"\x1b\[[0-9;]*m")
KEY_VALUE = re.compile(r"(\w+)=(\S*)")

# event name -> (keys that must be present, the keys whose values are numbers)
REQUIRED = {
    "launch": ("desktop_id", "requested_at", "spawned_at"),
    "window-ready": ("app_id", "connected_at", "first_commit_at", "first_frame_at", "settled_at"),
    "key-window": ("app_id", "cause", "input_at", "focused_at", "presented_at"),
    "xwayland-ready": ("requested_at", "ready_at"),
    "session-ready": ("started_at", "shell_connected_at", "shell_ready_at"),
}
NUMERIC = {
    "launch": ("requested_at", "spawned_at", "pid"),
    "window-ready": ("pid", "connected_at", "first_commit_at", "first_frame_at", "settled_at"),
    "key-window": ("input_at", "focused_at", "presented_at"),
    "xwayland-ready": ("requested_at", "ready_at"),
    "session-ready": ("started_at", "shell_connected_at", "shell_ready_at"),
}

Event = namedtuple("Event", "name fields")
Row = namedtuple("Row", "part app phase round stage ms text")
HEADER = "part\tapp\tphase\tround\tstage\tvalue_ms\ttext"

# ---------------------------------------------------------------- parsing the timing lines


def parse_line(line):
    """The timing event in a log line, or None. Tolerates a timestamp, colours and the `timing:` target."""
    text = ANSI.sub("", line).rstrip()
    for name, required in REQUIRED.items():
        found = re.search(rf"(?<![\w-]){re.escape(name)}((?:\s+\w+=\S*)+)\s*$", text)
        if not found:
            continue
        fields = {k: v.strip('"') for k, v in KEY_VALUE.findall(found.group(1))}
        numeric = NUMERIC[name]
        if not all(k in fields for k in required):
            continue
        if not all(fields[k].isdigit() for k in numeric if k in fields):
            continue
        return Event(name, {k: int(v) if k in numeric else v for k, v in fields.items()})
    return None


def canonical(event):
    return event.name + " " + " ".join(f"{k}={v}" for k, v in event.fields.items())


def state_log_text():
    base = os.environ.get("DESKTOP_SESSION_STATE") or os.path.join(os.environ.get("XDG_RUNTIME_DIR", ""), "desktop-session")
    try:
        with open(os.path.join(base, "casement.log"), "rb") as handle:
            handle.seek(0, os.SEEK_END)
            handle.seek(max(0, handle.tell() - 8_000_000))
            return handle.read().decode(errors="replace")
    except OSError:
        return ""


def journal_text(window_s, whole_boot):
    when = ["-b"] if whole_boot else ["--since", f"-{window_s}s"]
    command = ["journalctl", "--user", "-o", "cat", "--no-pager", *when]
    try:
        return subprocess.run(command, capture_output=True, text=True, errors="replace", timeout=90).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def read_events(args):
    """Every timing event from the sources, each once, in the order found."""
    if args.log_file:
        texts = [Path(f).read_text(errors="replace") for f in args.log_file]
    else:
        texts = [journal_text(args.window, args.boot), state_log_text()]
    seen, events = set(), []
    for text in texts:
        for line in text.splitlines():
            event = parse_line(line)
            key = event and canonical(event)
            if event and key not in seen:
                seen.add(key)
                events.append(event)
    return events


def add_source_options(parser):
    parser.add_argument("--log-file", action="append", default=[], help="read this file instead of the journal and casement.log")
    parser.add_argument("--window", type=int, default=900, help="seconds of journal to read (default 900)")
    parser.add_argument("--boot", action="store_true", help="read the whole boot")


# ---------------------------------------------------------------- pairing and stages


def ms(delta_ns):
    return delta_ns / NS_PER_MS


def launch_stages(launch, ready):
    """(stage, milliseconds, note) from a launch line and its window-ready line."""
    lf, rf = launch.fields, ready.fields
    legs = [
        ("request_to_spawned", lf["spawned_at"] - lf["requested_at"]),
        ("spawned_to_connected", rf["connected_at"] - lf["spawned_at"]),
        ("connected_to_first_commit", rf["first_commit_at"] - rf["connected_at"]),
        ("first_commit_to_first_frame", rf["first_frame_at"] - rf["first_commit_at"]),
        ("first_frame_to_settled", rf["settled_at"] - rf["first_frame_at"]),
    ]
    out = [(name, ms(max(0, d)), "negative, clamped to 0" if d < 0 else "") for name, d in legs]
    out.append(("total_to_first_frame", ms(rf["first_frame_at"] - lf["requested_at"]), ""))
    out.append(("total_to_settled", ms(rf["settled_at"] - lf["requested_at"]), ""))
    return out


def dialog_stages(request_at, ready):
    rf = ready.fields
    return [
        ("request_to_first_commit", ms(rf["first_commit_at"] - request_at), ""),
        ("first_commit_to_first_frame", ms(rf["first_frame_at"] - rf["first_commit_at"]), ""),
        ("first_frame_to_settled", ms(rf["settled_at"] - rf["first_frame_at"]), ""),
        ("request_to_first_frame", ms(rf["first_frame_at"] - request_at), ""),
    ]


def pick_ready(events, ids, pid, after_connected, after_commit, any_app):
    """The first window-ready after the request that belongs to the app (by window id, or by pid)."""
    def belongs(f):
        return any_app or f["app_id"].lower() in ids or (pid > 0 and f.get("pid", 0) == pid)
    found = [e for e in events if e.name == "window-ready" and e.fields["connected_at"] >= after_connected
             and e.fields["first_commit_at"] >= after_commit and belongs(e.fields)]
    return min(found, key=lambda e: e.fields["first_commit_at"], default=None)


def row_text(row):
    value = "" if row.ms is None else f"{row.ms:.1f}"
    return "\t".join([row.part, row.app, row.phase, str(row.round), row.stage, value, row.text])


def split_ids(text):
    return {i.strip().lower() for i in text.split(",") if i.strip()}


# ---------------------------------------------------------------- small commands


def cmd_now(_args):
    print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))
    return 0


def cmd_pick(args):
    for line in sys.stdin:
        event = parse_line(line)
        if event and event.name == args.event:
            print(canonical(event))
            return 0
    return 1


def cmd_field(args):
    event = parse_line(args.line)
    fields = event.fields if event else {k: v for k, v in KEY_VALUE.findall(args.line)}
    print("\t".join(str(fields.get(k, "-")) for k in args.keys))
    return 0


def cmd_wait(args):
    ids = split_ids(args.app_ids)
    deadline = time.monotonic() + args.timeout
    while True:
        hit = pick_ready(read_events(args), ids, args.pid, args.after_connected, args.after_commit, args.any_app)
        if hit:
            print(canonical(hit))
            return 0
        if time.monotonic() >= deadline:
            return 1
        time.sleep(0.4)


def cmd_rows(args):
    ready = parse_line(args.ready)
    if ready is None:
        print("rows: the window-ready line does not parse", file=sys.stderr)
        return 2
    if args.kind == "launch":
        launch = parse_line(args.launch)
        stages = launch_stages(launch, ready) if launch else None
    else:
        stages = dialog_stages(args.request_at, ready)
    if stages is None:
        print("rows: the launch line does not parse", file=sys.stderr)
        return 2
    part = "launch" if args.kind == "launch" else "dialog"
    for stage, value, note in stages:
        print(row_text(Row(part, args.app, args.phase, args.round, stage, value, note)))
    return 0


def cmd_switch(args):
    inside = [e for e in read_events(args) if e.name == "key-window" and args.from_ns <= e.fields["focused_at"] <= args.until]
    for cause in ([args.cause] if args.cause else ["keyboard", "pointer"]):
        caused = [e for e in inside if e.fields["cause"] == cause]
        timed = [e for e in caused if e.fields["input_at"] > 0]
        print(f"switch: {len(caused)} {cause} changes seen, {len(timed)} with an input time", file=sys.stderr)
        for index, e in enumerate(timed):
            f = e.fields
            legs = [("input_to_focused", f["focused_at"] - f["input_at"]),
                    ("focused_to_presented", f["presented_at"] - f["focused_at"]),
                    ("input_to_presented", f["presented_at"] - f["input_at"])]
            for stage, delta in legs:
                print(row_text(Row("switch", cause, "run", index, stage, ms(delta), "")))
    return 0


def cmd_login(args):
    ready = [e for e in read_events(args) if e.name == "session-ready"]
    if not ready:
        return 1
    f = max(ready, key=lambda e: e.fields["started_at"]).fields
    legs = [("start_to_shell_connected", f["shell_connected_at"] - f["started_at"]),
            ("shell_connected_to_shell_ready", f["shell_ready_at"] - f["shell_connected_at"]),
            ("start_to_shell_ready", f["shell_ready_at"] - f["started_at"])]
    for stage, delta in legs:
        print(row_text(Row("login", "login", "boot", 0, stage, ms(delta), "")))
    return 0


def cmd_xwayland(args):
    found = [e for e in read_events(args) if e.name == "xwayland-ready" and e.fields["requested_at"] >= args.after]
    if not found:
        return 1
    f = min(found, key=lambda e: e.fields["requested_at"]).fields
    print(row_text(Row("launch", args.app, "cold", 0, "xwayland_request_to_ready", ms(f["ready_at"] - f["requested_at"]), "")))
    return 0


def cmd_dialog_open(args):
    command = ["gdbus", "call", "--session", "--dest", "org.freedesktop.portal.Desktop",
               "--object-path", "/org/freedesktop/portal/desktop",
               "--method", "org.freedesktop.portal.FileChooser.OpenFile",
               "", "Workflow timing check", f"{{'handle_token': <'{args.token}'>}}"]
    asked = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
    print(asked, flush=True)
    done = subprocess.run(command, capture_output=True, text=True, timeout=60)
    if done.returncode != 0:
        print(done.stderr.strip() or "the portal did not answer", file=sys.stderr)
    return done.returncode


# ---------------------------------------------------------------- which GPU a process opened

FD_NODE = re.compile(r"/dev/dri/(?:card|renderD)\d+$")
FD_NVIDIA = re.compile(r"/dev/nvidia\d+$")


def children_of(proc):
    kids = defaultdict(list)
    for entry in Path(proc).iterdir():
        if not entry.name.isdigit():
            continue
        try:
            after_name = (entry / "stat").read_text().rsplit(")", 1)[1].split()
            kids[int(after_name[1])].append(int(entry.name))
        except (OSError, IndexError, ValueError):
            continue
    return kids


def tree_pids(pid, proc):
    kids, todo, seen = children_of(proc), [pid], []
    while todo:
        current = todo.pop()
        if current not in seen:
            seen.append(current)
            todo.extend(kids.get(current, []))
    return seen


def fdinfo_gpus(pid, proc):
    found = {}
    for info in sorted(Path(proc, str(pid), "fdinfo").glob("*")):
        try:
            text = info.read_text()
        except OSError:
            continue
        pdev = re.search(r"^drm-pdev:\s*(\S+)", text, re.M)
        driver = re.search(r"^drm-driver:\s*(\S+)", text, re.M)
        if pdev:
            found[pdev.group(1)] = driver.group(1) if driver else "?"
    return found


def fd_node_gpus(pid, proc, sysroot):
    """The fallback for drivers that print no drm fdinfo (NVIDIA): the render node an open fd points at."""
    found = {}
    for fd in sorted(Path(proc, str(pid), "fd").glob("*")):
        try:
            target = os.readlink(fd)
        except OSError:
            continue
        if FD_NODE.search(target):
            device = Path(sysroot, "class/drm", os.path.basename(target), "device")
            driver = Path(os.path.realpath(device / "driver")).name if (device / "driver").exists() else "?"
            found[Path(os.path.realpath(device)).name] = driver
        elif FD_NVIDIA.search(target):
            found["(" + os.path.basename(target) + ")"] = "nvidia"
    return found


def gpu_name(pdev, lspci_file):
    if lspci_file:
        lines = Path(lspci_file).read_text().splitlines()
    elif shutil.which("lspci") and not pdev.startswith("("):
        lines = subprocess.run(["lspci", "-D", "-s", pdev], capture_output=True, text=True).stdout.splitlines()
    else:
        lines = []
    for line in lines:
        if line.startswith(pdev + " "):
            return re.sub(r"\s*\(rev [0-9a-f]+\)$", "", line.split(": ", 1)[-1])
    return pdev


def cmd_gpu(args):
    found = {}
    for pid in tree_pids(args.pid, args.proc_root):
        found.update(fd_node_gpus(pid, args.proc_root, args.sys_root))
        found.update(fdinfo_gpus(pid, args.proc_root))
    if not found:
        print("none (no GPU opened: drawn in software or through shared memory)")
        return 0
    print("; ".join(f"{gpu_name(pdev, args.lspci_file)} [{driver}, {pdev}]" for pdev, driver in sorted(found.items())))
    return 0


# ---------------------------------------------------------------- which apps are installed


def os_release_ids(path):
    try:
        fields = dict(KEY_VALUE.findall(Path(path).read_text().replace('"', "")))
    except OSError:
        return []
    return [fields.get("ID", "")] + fields.get("ID_LIKE", "").split()


def package_manager(ids, path_dirs):
    by_id = {"fedora": "dnf", "rhel": "dnf", "centos": "dnf", "debian": "apt", "ubuntu": "apt", "arch": "pacman", "manjaro": "pacman"}
    for i in ids:
        if i in by_id:
            return by_id[i]
    return next((m for m in ("dnf", "apt", "pacman") if shutil.which(m, path=path_dirs)), "")


def desktop_file(ids, share_dirs):
    for desktop_id in ids:
        for share in share_dirs:
            path = Path(share, "applications", desktop_id + ".desktop")
            if path.is_file():
                return desktop_id, path
    return None, None


def wm_class(path):
    found = re.search(r"^StartupWMClass=(.+)$", path.read_text(errors="replace"), re.M)
    return found.group(1).strip() if found else ""


def default_share_dirs():
    home = Path.home()
    data_home = os.environ.get("XDG_DATA_HOME") or str(home / ".local/share")
    data_dirs = (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":")
    return [data_home, *data_dirs, str(home / ".local/share/flatpak/exports/share"),
            "/var/lib/flatpak/exports/share", "/var/lib/snapd/desktop"]


def installed(candidate, share_dirs, path_dirs):
    """(state, desktop id, window ids) for one candidate: ok, nodesktop or missing."""
    on_path = shutil.which(candidate["binary"], path=path_dirs) is not None
    desktop_id, path = desktop_file(candidate["desktop_ids"], share_dirs)
    exported = path is not None and any(s in str(path) for s in ("/flatpak/", "/snapd/"))
    if path is not None and (on_path or exported):
        wanted = [wm_class(path), desktop_id, candidate["binary"], *candidate.get("app_ids", [])]
        return "ok", desktop_id, ",".join(sorted({re.sub(r"\s+", "_", w).lower() for w in wanted if w}))
    return ("nodesktop" if on_path else "missing"), "-", "-"


def hint_for(candidates, manager):
    def command(c):
        package = c["package"].get(manager)
        verb = {"dnf": "sudo dnf install", "apt": "sudo apt install", "pacman": "sudo pacman -S"}.get(manager)
        return f"{verb} {package}" if verb and package else f"install {c['binary']}"
    return "   or   ".join(command(c) for c in candidates)


def cmd_apps(args):
    config = tomllib.loads(Path(args.file).read_text())
    share_dirs = args.share_dirs.split(":") if args.share_dirs is not None else default_share_dirs()
    path_dirs = args.path if args.path is not None else os.environ.get("PATH", "")
    manager = package_manager(os_release_ids(args.os_release), path_dirs)
    only = split_ids(args.only) if args.only else None
    for app in config["app"]:
        if only is not None and app["key"] not in only:
            continue
        results = [(c, installed(c, share_dirs, path_dirs)) for c in app["candidate"]]
        order = {"ok": 0, "nodesktop": 1, "missing": 2}
        candidate, (state, desktop_id, ids) = min(results, key=lambda r: order[r[1][0]])
        hint = hint_for(app["candidate"], manager) if state != "ok" else "-"
        print("\t".join([app["key"], state, app["kind"], desktop_id, ids, str(app["timeout_s"]), app["title"], candidate["binary"], hint]))
    return 0


# ---------------------------------------------------------------- the summary

STAGE_ORDER = ["request_to_spawned", "spawned_to_connected", "connected_to_first_commit", "first_commit_to_first_frame",
               "first_frame_to_settled", "total_to_first_frame", "total_to_settled", "xwayland_request_to_ready",
               "request_to_first_commit", "request_to_first_frame", "input_to_focused", "focused_to_presented",
               "input_to_presented", "start_to_shell_connected", "shell_connected_to_shell_ready", "start_to_shell_ready"]
TOTALS = {"total_to_first_frame", "total_to_settled", "request_to_first_frame", "input_to_presented", "start_to_shell_ready"}
LABEL = {
    "request_to_spawned": "request -> process started", "spawned_to_connected": "started -> connected",
    "connected_to_first_commit": "connected -> first picture", "first_commit_to_first_frame": "first picture -> on screen",
    "first_frame_to_settled": "on screen -> settled", "total_to_first_frame": "TOTAL request -> on screen",
    "total_to_settled": "TOTAL request -> settled", "xwayland_request_to_ready": "X11 bridge start",
    "request_to_first_commit": "request -> first picture", "request_to_first_frame": "TOTAL request -> on screen",
    "input_to_focused": "input -> focused", "focused_to_presented": "focused -> on screen",
    "input_to_presented": "TOTAL input -> on screen", "start_to_shell_connected": "start -> shell connected",
    "shell_connected_to_shell_ready": "shell connected -> bar and dock", "start_to_shell_ready": "TOTAL start -> bar and dock",
}
PLAIN = {
    "request_to_spawned": "the desktop starting the app's process",
    "spawned_to_connected": "the app starting up until it reaches the desktop",
    "connected_to_first_commit": "the app drawing its first picture",
    "first_commit_to_first_frame": "the desktop putting that first picture on screen",
    "first_frame_to_settled": "the opening animation",
    "xwayland_request_to_ready": "starting the X11 bridge (the first X11 app only)",
    "request_to_first_commit": "the portal starting the dialog until it draws",
    "input_to_focused": "the desktop reacting to the key press or click",
    "focused_to_presented": "the newly focused window reaching the screen",
    "start_to_shell_connected": "the desktop starting until the shell program joins it",
    "shell_connected_to_shell_ready": "the shell drawing the bar and dock",
}
PART_TITLE = {"launch": "Launch", "switch": "Switching windows", "dialog": "File dialog", "login": "Login"}


def read_raw(path):
    rows = []
    for line in Path(path).read_text().splitlines()[1:]:
        cells = (line.split("\t") + [""] * 7)[:7]
        rows.append(Row(cells[0], cells[1], cells[2], cells[3], cells[4], float(cells[5]) if cells[5] else None, cells[6]))
    return rows


def percentile(values, p):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(p * len(ordered)) - 1)]


class Group:
    """All the measurements of one stage of one app: the cold one and the rest."""
    def __init__(self):
        self.cold, self.rest = [], []

    @property
    def typical(self):
        return self.rest or self.cold

    def stats(self):
        values = self.typical
        return percentile(values, 0.5), percentile(values, 0.95), max(values)


def grouped(rows):
    groups = defaultdict(Group)
    for r in rows:
        if r.ms is not None:
            (groups[(r.part, r.app, r.stage)].cold if r.phase == "cold" else groups[(r.part, r.app, r.stage)].rest).append(r.ms)
    return groups


def stage_rank(key):
    return (key[0], key[1], STAGE_ORDER.index(key[2]) if key[2] in STAGE_ORDER else 99)


def table(groups, part):
    keys = sorted((k for k in groups if k[0] == part), key=stage_rank)
    lines = [f"{'':<10}{'stage':<34}{'cold':>8}{'p50':>8}{'p95':>8}{'max':>8}{'n':>4}"]
    for key in keys:
        g = groups[key]
        p50, p95, top = g.stats()
        cold = f"{g.cold[0]:.0f}" if g.cold else "-"
        lines.append(f"{key[1]:<10}{LABEL.get(key[2], key[2]):<34}{cold:>8}{p50:>8.0f}{p95:>8.0f}{top:>8.0f}{len(g.typical):>4}")
    return lines if keys else []


def gpu_lines(rows):
    seen = {}
    for r in rows:
        if r.stage == "gpu":
            seen[r.app] = r.text
    return [f"{app:<10}{text}" for app, text in seen.items()]


def trend_lines(new, old):
    """Stages whose p95 grew by more than 25 percent and more than 20 ms."""
    lines = []
    for key in sorted(new, key=stage_rank):
        if key not in old:
            continue
        before, after = old[key].stats()[1], new[key].stats()[1]
        if after > before * 1.25 and after - before > 20:
            lines.append(f"SLOWER  {key[1]:<10}{LABEL.get(key[2], key[2]):<34}p95 {before:.0f} -> {after:.0f} ms (+{after - before:.0f} ms, +{(after / before - 1) * 100 if before else 0:.0f}%)")
    return lines


def subject(part, app):
    return {"launch": app, "switch": f"switching windows by {app}", "dialog": "the file dialog", "login": "login"}[part]


def where_time_went(groups):
    ranked = []
    for (part, app, stage), g in groups.items():
        if stage not in TOTALS and stage in PLAIN:
            ranked.append((g.stats()[0], g.stats()[1], part, app, stage))
    lines = []
    for number, (p50, p95, part, app, stage) in enumerate(sorted(ranked, reverse=True)[:3], 1):
        lines.append(f"{number}. {subject(part, app)}: {PLAIN[stage]} takes about {p50:.0f} ms (up to {p95:.0f} ms).")
    return lines or ["(nothing was measured)"]


def answers_line(path):
    try:
        answers = [l.split(None, 2) for l in Path(path).read_text().splitlines() if re.match(r"^C\d+\s", l)]
    except OSError:
        return []
    count = {a: sum(1 for x in answers if len(x) > 1 and x[1] == a) for a in "yns"}
    return [f"{count['y']} worked, {count['n']} broken, {count['s']} skipped (details in answers.txt)"]


def section(title, lines):
    return ["", f"== {title}", *lines] if lines else []


def cmd_summarize(args):
    rows = read_raw(args.raw)
    groups = grouped(rows)
    out = []
    out += section("Launch, milliseconds (cold = first launch of this run; the other columns cover the warm launches)", table(groups, "launch"))
    out += section("Which GPU each app opened", gpu_lines(rows))
    out += section("Switching windows, milliseconds", table(groups, "switch"))
    out += section("File dialog, milliseconds (cold = the first dialog of this run)", table(groups, "dialog"))
    out += section("Login, milliseconds (this boot)", table(groups, "login"))
    if args.previous:
        flagged = trend_lines(groups, grouped(read_raw(args.previous)))
        out += section(f"Compared with the previous run ({Path(args.previous).parent.name})", flagged or ["nothing got slower by more than 25% and 20 ms"])
    if args.answers:
        out += section("Short checks", answers_line(args.answers))
    out += section("Where the time went", where_time_went(groups))
    print("\n".join(out).lstrip("\n"))
    return 0


# ---------------------------------------------------------------- the command line


def build_parser():
    parser = argparse.ArgumentParser(description="the helper behind workflow/run.sh")
    sub = parser.add_subparsers(dest="command", required=True)

    def command(name, func, *options, sources=False):
        p = sub.add_parser(name)
        p.set_defaults(func=func)
        for flags, kwargs in options:
            p.add_argument(*flags, **kwargs)
        if sources:
            add_source_options(p)
        return p

    command("now", cmd_now)
    command("pick", cmd_pick, (["event"], {}))
    command("field", cmd_field, (["line"], {}), (["keys"], {"nargs": "+"}))
    command("wait", cmd_wait, (["--app-ids"], {"default": ""}), (["--pid"], {"type": int, "default": 0}),
            (["--after-connected"], {"type": int, "default": 0}), (["--after-commit"], {"type": int, "default": 0}),
            (["--any-app"], {"action": "store_true"}), (["--timeout"], {"type": float, "default": 60}), sources=True)
    command("rows", cmd_rows, (["--kind"], {"choices": ["launch", "dialog"], "required": True}), (["--launch"], {"default": ""}),
            (["--ready"], {"required": True}), (["--request-at"], {"type": int, "default": 0}), (["--app"], {"required": True}),
            (["--phase"], {"required": True}), (["--round"], {"type": int, "default": 0}))
    command("gpu", cmd_gpu, (["--pid"], {"type": int, "required": True}), (["--proc-root"], {"default": "/proc"}),
            (["--sys-root"], {"default": "/sys"}), (["--lspci-file"], {"default": ""}))
    command("switch", cmd_switch, (["--from"], {"dest": "from_ns", "type": int, "required": True}),
            (["--until"], {"type": int, "required": True}),
            (["--cause"], {"choices": ["keyboard", "pointer"], "default": ""}), sources=True)
    command("login", cmd_login, sources=True)
    command("xwayland", cmd_xwayland, (["--after"], {"type": int, "required": True}), (["--app"], {"required": True}), sources=True)
    command("dialog-open", cmd_dialog_open, (["--token"], {"required": True}))
    command("apps", cmd_apps, (["--file"], {"required": True}), (["--only"], {"default": ""}),
            (["--share-dirs"], {"default": None}), (["--path"], {"default": None}), (["--os-release"], {"default": "/etc/os-release"}))
    command("summarize", cmd_summarize, (["--raw"], {"required": True}), (["--previous"], {"default": ""}), (["--answers"], {"default": ""}))
    return parser


def main(argv):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (OSError, ValueError, KeyError, tomllib.TOMLDecodeError) as error:
        print(f"timing.py {args.command}: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
