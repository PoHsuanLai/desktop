#!/usr/bin/env python3
"""The helper behind workflow/w1-blender.sh (designer workflow W1): the pure parts.

Standard library only; run it as `python3 -I workflow/lib/w1.py <command> ...`. Nothing here starts a
program except `serve` (a loopback web server for the fixture page). w1-selftest.sh runs the rest on
canned input, with no session.

Commands:
  hint WHAT                         how to install blender, firefox or zen on this distribution
  loopback URL                      "host port" of a loopback http URL; exit 1 for anything else
  served                            stdin: a /v1/models answer -> the model names it lists, one per line
  catalog --src F --out F ...       a catalogue entry as an engine on another computer (attached)
  inferd-config ...                 the text of inferd's configuration for this run
  cuad-settings ...                 the text of the computer-use settings for this run
  sentence --outdir DIR             the sentence the person says to the assistant
  serve --dir D --port-file F       serve D on 127.0.0.1 (free port, written to F) until stopped;
                                    --mount /PREFIX/=FOLDER (repeatable) serves a folder under a path instead
  blender-expr                      the Python Blender runs, in the background, to read the exported file
  glb-compare --line L --expected F compare Blender's reading of the file with the page's sizes
  guard --text-file F ...           the guard's words found in the assistant's last words
  report --run DIR --expected F     write DIR/report.md; exit 0 when every checked criterion passes

Exit codes: 0 done; 1 a check failed or nothing found; 2 bad usage or an unreadable input.
"""
import argparse
import functools
import http.server
import importlib.util
import json
import os
import re
import sys
import tomllib
from pathlib import Path
from urllib.parse import urlparse

HERE = Path(__file__).resolve().parent

# What the assistant's guard says when a turn ends badly (workflow-designer.md section 7).
GUARD_WORDS = ["Couldn't do that", "I keep getting the same answer", "stopped:", "That is done"]

# Stage marks the script records (stamps.tsv), in the order they happen, with their plain names.
STAGES = [
    ("start", "run started"),
    ("casement_up", "desktop window up"),
    ("stack_up", "assistant services up"),
    ("page_open", "product page shown"),
    ("asked", "request given to the assistant"),
    ("first_turn", "assistant's first answer"),
    ("first_screen_step", "first look at the screen"),
    ("blender_open", "Blender window shown"),
    ("glb_seen", "file saved"),
    ("finished", "run finished"),
]


def timing_module():
    """workflow/lib/timing.py, loaded by path (python -I does not put this folder on the path)."""
    spec = importlib.util.spec_from_file_location("w1_timing", HERE / "timing.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------- installing what is missing

PACKAGES = {
    "blender": {"dnf": "blender", "apt": "blender", "pacman": "blender"},
    "firefox": {"dnf": "firefox", "apt": "firefox", "pacman": "firefox"},
}
VERBS = {"dnf": "sudo dnf install", "apt": "sudo apt install", "pacman": "sudo pacman -S"}
ZEN = "flatpak install flathub app.zen_browser.zen"


def hint_text(what, manager):
    if what == "zen":
        return ZEN
    package = PACKAGES[what].get(manager)
    verb = VERBS.get(manager)
    return f"{verb} {package}" if verb and package else f"install {what} with your package manager"


def cmd_hint(args):
    timing = timing_module()
    ids = timing.os_release_ids(args.os_release)
    manager = timing.package_manager(ids, args.path if args.path is not None else os.environ.get("PATH", ""))
    print(hint_text(args.what, manager))
    return 0


# ---------------------------------------------------------------- the models

def loopback(url):
    """(host, port) of an http URL on this computer, else None."""
    parts = urlparse(url)
    if parts.scheme != "http" or parts.hostname not in ("127.0.0.1", "localhost") or not parts.port:
        return None
    return parts.hostname, parts.port


def cmd_loopback(args):
    found = loopback(args.url)
    if not found:
        return 1
    print(*found)
    return 0


def cmd_served(_args):
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 1
    names = [m.get("id", "") for m in data.get("data", []) if isinstance(m, dict)]
    print("\n".join(n for n in names if n))
    return 0 if names else 1


def engine_parsers(text):
    """(tool parser, reasoning parser or "") from the entry's vllm `[[engine]]` args.

    The engine on the other computer is started with the entry's own line, so the parsers it named
    there are the ones the attached entry must say; a model is added as catalogue data alone.
    """
    def flag(args, name):
        return next((args[i + 1] for i, arg in enumerate(args[:-1]) if arg == name), "")

    for engine in tomllib.loads(text).get("engine", []):
        args = engine.get("args", []) if engine.get("kind") == "vllm" else []
        tool = flag(args, "--tool-call-parser")
        if tool:
            return tool, flag(args, "--reasoning-parser")
    raise ValueError("the catalogue entry has no vllm engine line naming a --tool-call-parser")


def attached_catalog(text, served, tool_parser="", reasoning_parser=""):
    """A catalogue entry that is served somewhere else: its engine rows go, `serving` comes in.

    The shipped entries describe an engine the desktop would start itself; an engine on another
    computer needs the entry to say it is attached (porter: a launched entry cannot be attached).
    The parsers are the entry's own engine line's (`engine_parsers`) unless a tool parser is given.
    """
    if not tool_parser:
        tool_parser, reasoning_parser = engine_parsers(text)
    lines = text.splitlines()
    out, skipping = [], False
    for line in lines:
        if re.match(r"\s*\[\[?engine[\].]", line):
            skipping = True
            continue
        if skipping and re.match(r"\s*\[", line):
            skipping = False
        if skipping or re.match(r"\s*serving\s*=", line):
            continue
        out.append(line)
    parsers = f'tool_parser = "{tool_parser}"'
    if reasoning_parser:
        parsers += f', reasoning_parser = "{reasoning_parser}"'
    serving = f'serving = {{ kind = "attached", v = {{ engine = "vllm", served_name = "{served}", {parsers} }} }}'
    for i, line in enumerate(out):
        if re.match(r"\s*id\s*=", line):
            out.insert(i + 1, serving)
            break
    else:
        raise ValueError("the catalogue entry has no id line")
    return "\n".join(out).rstrip("\n") + "\n"


def cmd_catalog(args):
    text = attached_catalog(Path(args.src).read_text(), args.served, args.tool_parser, args.reasoning_parser)
    Path(args.out).write_text(text)
    return 0


def inferd_config_text(planner, screen):
    """inferd's configuration for the run: two engines on other computers, nothing started here.

    planner and screen are (catalogue id, loopback URL) pairs.
    """
    def engine(model, url):
        return f'[engines.attached."{model}"]\nurl = "{url}"\nwhere = "my-network"\n'

    models = "".join(
        f'[ai.model.{slot}]\nfast = "local/{model}"\nbalanced = "local/{model}"\nbest = "local/{model}"\n\n'
        for slot, model in (("text", planner[0]), ("computer_use", screen[0]))
    )
    return (
        "# Written by workflow/w1-blender.sh for this run only.\n"
        "[ai]\nlocal_only = \"off\"\n\n"
        "[ai.attached]\nmy_network = \"on\"\n\n"
        "[ai.floor]\nprompt = \"local_network\"\nmail = \"on_device\"\nscreen = \"local_network\"\n\n"
        "[ai.spend]\naccount_daily_cents = 0\napp_daily_cents = 0\n\n"
        + models
        + "\n".join(engine(m, u) for m, u in dict((p[0], p[1]) for p in (screen, planner)).items()) + "\n"
        "[probe]\nollama = []\nllama_cpp = []\nlm_studio = []\n"
    )


def cmd_inferd_config(args):
    print(inferd_config_text((args.planner_id, args.planner_url), (args.screen_id, args.screen_url)), end="")
    return 0


def cuad_settings_text(apps, steps, active_s):
    rows = "".join(f'\n[[cua.apps]]\napp = "{app}"\nallow = "{allow}"\n' for app, allow in apps)
    return f'[cua]\nenabled = "on"\n\n[cua.budget]\nsteps = {steps}\nactive_s = {active_s}\n{rows}'


def cmd_cuad_settings(args):
    apps = [tuple(a.split("=", 1)) for a in args.app]
    print(cuad_settings_text(apps, args.steps, args.active_s), end="")
    return 0


# ---------------------------------------------------------------- the request and the page

def sentence_text(outdir):
    return (
        "Get the specs of the lamp on this page, then build it in Blender with a few helpers "
        f"and save it as a .glb file in {outdir}"
    )


def cmd_sentence(args):
    print(sentence_text(args.outdir))
    return 0


def mounted_handler(default_dir, mounts):
    """A static-file handler that serves each PREFIX/ from its own folder, the longest prefix first.

    mounts is a list of (prefix, folder), a prefix like "/lamp/". A path under no prefix falls to default_dir
    (and is a 404 when there is none).
    """
    ordered = sorted(mounts, key=lambda m: len(m[0]), reverse=True)

    class Handler(http.server.SimpleHTTPRequestHandler):
        def translate_path(self, path):
            clean = path.split("?", 1)[0].split("#", 1)[0]
            for prefix, folder in ordered:
                if clean == prefix.rstrip("/"):  # /lamp -> /lamp/
                    return str(Path(folder) / "index.html")
                if clean.startswith(prefix):
                    self.directory = folder
                    return super().translate_path("/" + clean[len(prefix):])
            if default_dir is None:
                return str(Path("/nonexistent-w1-mount"))
            self.directory = default_dir
            return super().translate_path(path)

        def log_message(self, *a, **k):
            pass

    return Handler


def parse_mounts(items):
    """[(prefix, folder)] from PREFIX=FOLDER words; a prefix starts and ends with a slash."""
    mounts = []
    for item in items:
        prefix, _, folder = item.partition("=")
        if not (prefix.startswith("/") and prefix.endswith("/") and folder):
            raise ValueError(f"a mount is /PREFIX/=FOLDER, not {item!r}")
        mounts.append((prefix, folder))
    return mounts


def cmd_serve(args):
    mounts = parse_mounts(args.mount)
    if not args.dir and not mounts:
        raise ValueError("serve wants --dir or at least one --mount")
    if mounts:
        handler = mounted_handler(args.dir or None, mounts)
    else:
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=args.dir)
        handler.log_message = lambda *a, **k: None
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    Path(args.port_file).write_text(f"{server.server_address[1]}\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


# ---------------------------------------------------------------- reading the exported file

BLENDER_EXPR = r"""
import os, sys
import bpy
from mathutils import Vector
path = os.environ["W1_GLB"]
try:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not meshes:
        print("W1GLB error=no-meshes objects=%d" % len(bpy.context.scene.objects))
    else:
        low = Vector((1e30, 1e30, 1e30))
        high = Vector((-1e30, -1e30, -1e30))
        for o in meshes:
            for corner in o.bound_box:
                p = o.matrix_world @ Vector(corner)
                for i in range(3):
                    low[i] = min(low[i], p[i])
                    high[i] = max(high[i], p[i])
        size = high - low
        print("W1GLB meshes=%d objects=%d bbox=%.6f,%.6f,%.6f" % (len(meshes), len(bpy.context.scene.objects), size.x, size.y, size.z))
except Exception as error:
    print("W1GLB error=%s" % str(error).replace("\n", " ")[:200])
"""


def cmd_blender_expr(_args):
    print(BLENDER_EXPR)
    return 0


LINE = re.compile(r"W1GLB\s+(.*)")


def parse_glb_line(text):
    """{'meshes': int, 'objects': int, 'bbox': [x, y, z]} from Blender's output, or {'error': why}."""
    found = [m.group(1) for m in LINE.finditer(text)]
    if not found:
        return {"error": "Blender printed no reading of the file"}
    fields = dict(re.findall(r"(\w+)=(\S*)", found[-1]))
    if "error" in fields:
        return {"error": fields["error"], "objects": int(fields.get("objects", 0))}
    try:
        return {
            "meshes": int(fields["meshes"]),
            "objects": int(fields["objects"]),
            "bbox": [float(v) for v in fields["bbox"].split(",")],
        }
    except (KeyError, ValueError):
        return {"error": "Blender's reading of the file could not be understood"}


def compare_size(found, want, tolerance, units):
    """Whether the sorted sizes agree within the tolerance for some unit; (ok, unit used, ratios)."""
    want = sorted(want, reverse=True)
    best = None
    for unit in units:
        mine = sorted((v * unit for v in found), reverse=True)
        ratios = [m / w for m, w in zip(mine, want)]
        worst = max(abs(r - 1) for r in ratios)
        if best is None or worst < best[0]:
            best = (worst, unit, ratios)
        if worst <= tolerance:
            return True, unit, ratios
    return False, best[1], best[2]


UNIT_WORD = {1: "1 unit = 1 mm", 10: "1 unit = 1 cm", 1000: "1 unit = 1 m"}


def judge_glb(reading, expected):
    """The criterion rows (name, ok, detail) for Blender's reading of the file."""
    if "error" in reading:
        return [("the file opens in Blender", False, reading["error"])]
    rows = [("the file opens in Blender", True, f"{reading['meshes']} shapes, {reading['objects']} objects")]
    rows.append((
        f"at least {expected['min_objects']} separate shapes (the page lists that many parts)",
        reading["meshes"] >= expected["min_objects"],
        f"found {reading['meshes']}",
    ))
    ok, unit, ratios = compare_size(reading["bbox"], expected["bbox_mm"], expected["tolerance"], expected["units"])
    size = " x ".join(f"{v:.3f}" for v in reading["bbox"])
    detail = (f"read {size} (" + UNIT_WORD.get(unit, f"x{unit}") + "), "
              "against the page's " + " x ".join(str(v) for v in sorted(expected["bbox_mm"], reverse=True)) + " mm: "
              + ", ".join(f"{r * 100:.0f}%" for r in ratios))
    rows.append((f"overall size within {expected['tolerance'] * 100:.0f}% of the page", ok, detail))
    return rows


def cmd_glb_compare(args):
    expected = json.loads(Path(args.expected).read_text())
    text = args.line if args.line else Path(args.file).read_text(errors="replace")
    rows = judge_glb(parse_glb_line(text), expected)
    for name, ok, detail in rows:
        print("\t".join(["PASS" if ok else "FAIL", name, detail]))
    return 0 if all(ok for _, ok, _ in rows) else 1


# ---------------------------------------------------------------- the model log and the audit

def read_jsonl(path):
    rows = []
    try:
        for line in Path(path).read_text(errors="replace").splitlines():
            try:
                rows.append(json.loads(line))
            except ValueError:
                continue
    except OSError:
        pass
    return rows


def conversation_label(row):
    """A short name for who a model turn belongs to, from the start of its first instruction."""
    for message in row.get("messages", []):
        if message.get("role") == "system":
            text = message.get("text", "")
            found = re.search(r"You are ([^.\n]{1,60})", text)
            return found.group(1).strip() if found else text[:40]
    return "unknown"


def summarize_turns(rows):
    """Per conversation: turns, time, tokens, tool calls. Pure, on the model-log rows."""
    groups = {}
    for row in rows:
        g = groups.setdefault(conversation_label(row), {"turns": 0, "ms": 0, "in": 0, "out": 0, "calls": {}})
        g["turns"] += 1
        g["ms"] += int(row.get("took_ms") or 0)
        g["in"] += int(row.get("input_tokens") or 0)
        g["out"] += int(row.get("output_tokens") or 0)
        answer = (row.get("answer") or {}).get("v") or {}
        for call in answer.get("calls", []) if isinstance(answer, dict) else []:
            g["calls"][call.get("name", "?")] = g["calls"].get(call.get("name", "?"), 0) + 1
    return groups


def last_words(rows):
    """The text of every answer that ended a turn (no tool call in it), oldest first."""
    words = []
    for row in rows:
        answer = (row.get("answer") or {}).get("v") or {}
        if isinstance(answer, dict) and not answer.get("calls") and answer.get("text"):
            words.append(answer["text"])
    return words


def guard_hits(texts):
    return sorted({w for t in texts for w in GUARD_WORDS if w.lower() in t.lower()})


def cmd_guard(args):
    texts = [Path(f).read_text(errors="replace") for f in args.text_file]
    for trace in args.trace:
        texts += last_words(read_jsonl(trace))
    hits = guard_hits(texts)
    print("\n".join(hits))
    return 1 if hits else 0


def screen_steps(audit):
    """Audit rows that carried a picture of the screen: (epoch seconds, model)."""
    return [(int(r.get("at", 0)), r.get("model", "?")) for r in audit
            if r.get("class") == "screen" or int(r.get("images") or 0) > 0]


# ---------------------------------------------------------------- the report

def read_stamps(path):
    stamps = {}
    try:
        for line in Path(path).read_text().splitlines():
            parts = line.split("\t")
            if len(parts) >= 3 and parts[1].isdigit() and parts[2].isdigit():
                stamps[parts[0]] = (int(parts[1]), int(parts[2]))
    except OSError:
        pass
    return stamps


def stage_rows(stamps, stages=None):
    """(plain name, seconds since the previous mark, seconds since the start) for the marks present."""
    rows, previous = [], None
    start = stamps.get("start")
    for key, label in (stages or STAGES):
        if key not in stamps:
            continue
        now = stamps[key][0]
        rows.append((label, None if previous is None else (now - previous) / 1e9,
                     None if start is None else (now - start[0]) / 1e9))
        previous = now
    return rows


def fmt_s(value):
    return "" if value is None else f"{value:.1f}"


def table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return out


def build_report(run, expected):
    """(text, all_passed) for the run folder `run`."""
    run = Path(run)
    stamps = read_stamps(run / "stamps.tsv")
    trace = read_jsonl(run / "trace.jsonl")
    audit = read_jsonl(run / "agents/.local/state/quire/inferd/audit.jsonl")
    started = stamps.get("start", (0, 0))[1]
    steps = [s for s in screen_steps(audit) if s[0] >= started]
    glbs = sorted((run / "out").glob("*.glb")) if (run / "out").is_dir() else []

    checks = [("a .glb file was saved in the run folder", bool(glbs), ", ".join(g.name for g in glbs) or "none found")]
    reading = run / "glb-reading.txt"
    if glbs and reading.is_file():
        for name, ok, detail in judge_glb(parse_glb_line(reading.read_text(errors="replace")), expected):
            checks.append((name, ok, detail))
    elif glbs:
        checks.append(("the file opens in Blender", False, "Blender was not run on it"))
    texts = last_words(trace)
    turn = run / "turn.txt"
    if turn.is_file():
        texts.append(turn.read_text(errors="replace"))
    hits = guard_hits(texts)
    checks.append(("the turn did not end in the guard's words", not hits, ", ".join(f'"{h}"' for h in hits) or "none seen"))
    ok_all = all(ok for _, ok, _ in checks)

    lines = [f"# Workflow W1 (product page to a Blender model): {'PASS' if ok_all else 'FAIL'}", "", f"Run folder: {run}", ""]
    lines += ["## Checks", ""] + table(["", "Check", "Detail"], [("PASS" if ok else "FAIL", n, d) for n, ok, d in checks]) + [""]

    seen = run / "files-made.txt"
    made = [l for l in seen.read_text().splitlines() if l] if seen.is_file() else []
    parts = [m for m in made if not m.endswith(".glb")]
    lines += ["## Information (not a pass or fail)", ""]
    lines += [f"- Files made during the run besides the saved file: {len(parts)}"
              + (" (at least two, as the page's parts would give)" if len(parts) >= 2 else " (fewer than two seen; helpers may keep parts elsewhere)")]
    lines += [f"  - {p}" for p in parts[:20]]
    lines += ["- Not checked by the script: that every install or first run of a new tool was asked about first, that nothing "
              "was written outside the run folder, and that you could still use the computer without delay during the run. "
              "Answer those by hand from what you saw.", ""]

    lines += ["## Stage times (seconds)", ""]
    rows = stage_rows(stamps)
    lines += table(["Stage", "Since the previous", "Since the start"], [(a, fmt_s(b), fmt_s(c)) for a, b, c in rows]) if rows else ["No stage marks were recorded."]
    lines += [""]

    lines += ["## Assistant and helper turns", ""]
    groups = summarize_turns(trace)
    if groups:
        lines += table(["Who", "Turns", "Model time (s)", "Words in", "Words out", "Actions chosen"],
                       [(label, g["turns"], f"{g['ms'] / 1000:.1f}", g["in"], g["out"],
                         ", ".join(f"{n} x{c}" for n, c in sorted(g["calls"].items())) or "none")
                        for label, g in sorted(groups.items())])
    else:
        lines += ["No model log was recorded."]
    lines += [""]

    lines += ["## Looks at the screen", ""]
    if steps:
        first, last = steps[0][0], steps[-1][0]
        models = sorted({m for _, m in steps})
        lines += [f"- {len(steps)} looks at the screen by {', '.join(models)}",
                  f"- first at +{first - started} s, last at +{last - started} s after the start"]
    else:
        lines += ["No look at the screen was recorded."]
    lines += [""]

    shots = sorted((run / "shots").glob("*.png")) if (run / "shots").is_dir() else []
    lines += ["## Pictures", ""] + ([f"- {s.relative_to(run)}" for s in shots] or ["None were taken."]) + [""]
    return "\n".join(lines), ok_all


def cmd_report(args):
    expected = json.loads(Path(args.expected).read_text())
    text, ok = build_report(args.run, expected)
    (Path(args.run) / "report.md").write_text(text)
    print(text)
    return 0 if ok else 1


# ---------------------------------------------------------------- stage times from the logs

def cmd_first_turn(args):
    """The first moment (epoch seconds from the audit) the assistant's model answered after --since."""
    audit = read_jsonl(args.audit)
    times = [int(r.get("at", 0)) for r in audit if int(r.get("at", 0)) >= args.since and r.get("class") != "screen"]
    if not times:
        return 1
    print(min(times))
    return 0


def cmd_first_screen(args):
    steps = [s for s in screen_steps(read_jsonl(args.audit)) if s[0] >= args.since]
    if not steps:
        return 1
    print(steps[0][0])
    return 0


# ---------------------------------------------------------------- the command line

def build_parser():
    parser = argparse.ArgumentParser(description="the helper behind workflow/w1-blender.sh")
    sub = parser.add_subparsers(dest="command", required=True)

    def command(name, func, *options):
        p = sub.add_parser(name)
        p.set_defaults(func=func)
        for flags, kwargs in options:
            p.add_argument(*flags, **kwargs)

    command("hint", cmd_hint, (["what"], {"choices": ["blender", "firefox", "zen"]}),
            (["--os-release"], {"default": "/etc/os-release"}), (["--path"], {"default": None}))
    command("loopback", cmd_loopback, (["url"], {}))
    command("served", cmd_served)
    command("catalog", cmd_catalog, (["--src"], {"required": True}), (["--out"], {"required": True}),
            (["--served"], {"required": True}),
            (["--tool-parser"], {"default": "", "help": "default: the entry's own engine line"}),
            (["--reasoning-parser"], {"default": ""}))
    command("inferd-config", cmd_inferd_config, (["--planner-id"], {"required": True}), (["--planner-url"], {"required": True}),
            (["--screen-id"], {"required": True}), (["--screen-url"], {"required": True}))
    command("cuad-settings", cmd_cuad_settings, (["--app"], {"action": "append", "default": [], "help": "APP=ask|always"}),
            (["--steps"], {"type": int, "default": 400}), (["--active-s"], {"type": int, "default": 3600}))
    command("sentence", cmd_sentence, (["--outdir"], {"required": True}))
    command("serve", cmd_serve, (["--dir"], {"default": ""}), (["--mount"], {"action": "append", "default": [], "help": "/PREFIX/=FOLDER"}),
            (["--port-file"], {"required": True}))
    command("blender-expr", cmd_blender_expr)
    command("glb-compare", cmd_glb_compare, (["--line"], {"default": ""}), (["--file"], {"default": ""}),
            (["--expected"], {"required": True}))
    command("guard", cmd_guard, (["--text-file"], {"action": "append", "default": []}),
            (["--trace"], {"action": "append", "default": []}))
    command("report", cmd_report, (["--run"], {"required": True}), (["--expected"], {"required": True}))
    command("first-turn", cmd_first_turn, (["--audit"], {"required": True}), (["--since"], {"type": int, "default": 0}))
    command("first-screen", cmd_first_screen, (["--audit"], {"required": True}), (["--since"], {"type": int, "default": 0}))
    return parser


def main(argv):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (OSError, ValueError, KeyError) as error:
        print(f"w1.py {args.command}: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
