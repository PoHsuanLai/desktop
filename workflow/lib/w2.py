#!/usr/bin/env python3
"""The helper behind scenarios/w2-excalidraw.sh (designer workflow W2): the pure parts.

Standard library only; run it as `python3 -I workflow/lib/w2.py <command> ...`. Nothing here starts a
program or opens a socket. w2-selftest.sh runs it all on canned input, with no session. The parts W1 already has
(model lists, catalogue rewrite, inferd and cuad settings, the guard's words, the file server, stage times) are
w1.py's; a command this file does not know is handed to it.

Commands:
  sentence                         the sentence the person says to the assistant
  browser-prefs --download-dir D   the browser profile's user.js: downloads go to D with no dialog, no first-run pages
  check --run DIR --expected F     the drawing checks, one line each: PASS|FAIL <TAB> check <TAB> detail
  sheet-info --bus F --id ID       what the sheet ID is: "brief|step <TAB> press|hold_to_confirm <TAB> app <TAB> action"
  sheet-answer --bus F --id ID     exit 0 when the bus carried the sheet's reply (prints its kind), 1 when not (yet)
  sheets --bus F                   every confirmation the recorded bus carried and how it was answered, as JSON lines
  report --run DIR --expected F    write DIR/report.md; exit 0 when every checked criterion passes

Exit codes: 0 done; 1 a check failed or nothing found; 2 bad usage or an unreadable input.
"""
import argparse
import importlib.util
import json
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_w1():
    """workflow/lib/w1.py, loaded by path (python -I does not put this folder on the path)."""
    spec = importlib.util.spec_from_file_location("w1", HERE / "w1.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


w1 = load_w1()

SENTENCE = ("Get the specs of the lamp on this page, then draw its front view with sizes in the drawing app "
            "with a few helpers, and save the drawing.")

# Stage marks the scenario records (stamps.tsv), in the order they happen, with their plain names.
STAGES = [
    ("start", "run started"),
    ("casement_up", "desktop window up"),
    ("stack_up", "assistant services up"),
    ("page_open", "lamp page and drawing app shown"),
    ("asked", "request given to the assistant"),
    ("first_turn", "assistant's first answer"),
    ("first_screen_step", "first look at the screen"),
    ("drawing_saved", "drawing file saved"),
    ("svg_saved", "picture file saved"),
    ("finished", "run finished"),
]


# ---------------------------------------------------------------- the request and the browser

def cmd_sentence(_args):
    print(SENTENCE)
    return 0


def browser_prefs(download_dir, homepage=None):
    """user.js for the browser's profile: saved files go to download_dir without a question, and no first-run pages.

    homepage ("URL|URL") is what a start with no address opens; the addresses on the command line still open as tabs.
    """
    prefs = [
        ("browser.download.dir", str(download_dir)),
        ("browser.download.folderList", 2),
        ("browser.download.useDownloadDir", True),
        ("browser.download.always_ask_before_handling_new_types", False),
        ("browser.download.manager.showWhenStarting", False),
        ("browser.download.panel.shown", True),
        ("browser.helperApps.neverAsk.saveToDisk",
         "application/json,application/octet-stream,application/vnd.excalidraw+json,image/svg+xml,text/plain"),
        ("browser.shell.checkDefaultBrowser", False),
        ("browser.startup.homepage_override.mstone", "ignore"),
        ("browser.aboutwelcome.enabled", False),
        ("browser.preonboarding.enabled", False),
        # Zen's own first-run page ("Welcome to a calmer internet") is shown until this is set.
        ("zen.welcome-screen.seen", True),
        ("zen.updates.show-update-notification", False),
        # The bar that says the content sandbox is off (it is, in the jail) only covers the page.
        ("security.sandbox.warn_unprivileged_namespaces", False),
        ("browser.startup.page", 1),
        ("browser.startup.firstrunSkipsHomepage", True),
        ("browser.startup.couldRestoreSession.count", 0),
        ("trailhead.firstrun.didSeeAboutWelcome", True),
        ("browser.tabs.warnOnClose", False),
        ("browser.warnOnQuit", False),
        ("datareporting.policy.dataSubmissionEnabled", False),
        ("datareporting.healthreport.uploadEnabled", False),
        ("app.update.auto", False),
        ("app.update.enabled", False),
        ("network.captive-portal-service.enabled", False),
        ("extensions.autoDisableScopes", 15),
        # No GPU in the test jail: draw by software, with few processes.
        ("gfx.webrender.software", True),
        ("layers.acceleration.disabled", True),
        ("media.hardware-video-decoding.enabled", False),
        ("dom.ipc.processCount", 1),
        ("toolkit.telemetry.reportingpolicy.firstRun", False),
    ]
    if homepage:
        prefs.append(("browser.startup.homepage", homepage))
    lines = ["// Written by scenarios/w2-excalidraw.sh for this run only."]
    lines += [f"user_pref({json.dumps(k)}, {json.dumps(v)});" for k, v in prefs]
    return "\n".join(lines) + "\n"


def cmd_browser_prefs(args):
    print(browser_prefs(args.download_dir, args.homepage), end="")
    return 0


# ---------------------------------------------------------------- reading the saved drawing

SHAPE_TYPES = {"rectangle", "ellipse", "diamond", "line", "freedraw"}
SIZE = re.compile(r"(\d+(?:[.,]\d+)?)\s*(mm|cm|m)\b", re.IGNORECASE)
UNIT_MM = {"mm": 1.0, "cm": 10.0, "m": 1000.0}


def read_drawing(path):
    """(document, None) for a readable Excalidraw file, else (None, why)."""
    try:
        doc = json.loads(Path(path).read_text(errors="replace"))
    except (OSError, ValueError) as error:
        return None, f"cannot be read as JSON ({error})"
    if not isinstance(doc, dict) or doc.get("type") != "excalidraw":
        return None, f'its type is {doc.get("type")!r}, not "excalidraw"' if isinstance(doc, dict) else "it is not an object"
    if not isinstance(doc.get("elements"), list):
        return None, "it has no list of elements"
    return doc, None


def live(doc):
    return [e for e in doc["elements"] if isinstance(e, dict) and not e.get("isDeleted")]


def shapes_of(doc):
    """The drawn parts: rectangles, ellipses, diamonds, lines and freehand strokes (arrows and text are annotation)."""
    return [e for e in live(doc) if e.get("type") in SHAPE_TYPES]


def bodies_of(doc):
    """The shapes that fill space: both sides at least 2 units, which leaves out dimension lines and bare strokes."""
    return [e for e in shapes_of(doc) if min(abs(float(e.get("width") or 0)), abs(float(e.get("height") or 0))) >= 2]


def texts_of(doc):
    return [str(e.get("text") or e.get("originalText") or "") for e in live(doc) if e.get("type") == "text"]


def sizes_in(texts):
    """Every size the texts write, in millimetres (mm, cm and m are read; 28,5 cm is 285)."""
    found = []
    for text in texts:
        for number, unit in SIZE.findall(text):
            found.append(float(number.replace(",", ".")) * UNIT_MM[unit.lower()])
    return found


def judge_sizes(doc, wanted):
    """(ok, detail): each wanted size (mm) is written in some text, to within 1 mm or 0.5%."""
    written = sizes_in(texts_of(doc))
    missing = [w for w in wanted if not any(abs(v - w) <= max(1.0, 0.005 * w) for v in written)]
    if not written:
        return False, "no text with a size in mm was found"
    shown = ", ".join(f"{v:g}" for v in sorted(set(written)))
    if missing:
        return False, f"missing {', '.join(f'{m:g}' for m in missing)} mm; the texts write {shown} mm"
    return True, f"all of {', '.join(f'{w:g}' for w in wanted)} mm are written ({shown} mm in the texts)"


def box(e):
    x, y = float(e.get("x") or 0), float(e.get("y") or 0)
    w, h = float(e.get("width") or 0), float(e.get("height") or 0)
    return min(x, x + w), min(y, y + h), abs(w), abs(h)


def judge_proportions(doc, drawing):
    """(ok, detail): base width, total height and shade width stand in the page's proportions to within the tolerance.

    The drawing has no known scale, so each candidate scale comes from one known dimension (the total height, or the
    width of some part taken as the base or as the shade); the best scale is the one whose worst of the three errors
    is smallest. The total height is the height of all the space-filling shapes together; the base is a shape that
    stands on the bottom of the drawing (within 15% of the height), the shade any other.
    """
    tolerance = drawing["tolerance"]
    bodies = [box(e) for e in bodies_of(doc)]
    if len(bodies) < 2:
        return False, f"{len(bodies)} space-filling shape(s); need at least 2 to compare"
    top = min(b[1] for b in bodies)
    bottom = max(b[1] + b[3] for b in bodies)
    height = bottom - top
    widths = [b[2] for b in bodies]
    # The base stands on the bottom of the drawing; the shade is any other part.
    on_bottom = {i for i, b in enumerate(bodies) if b[1] + b[3] >= bottom - 0.15 * height}
    base_mm, high_mm, shade_mm = drawing["base_width_mm"], drawing["total_height_mm"], drawing["shade_width_mm"]
    scales = {height / high_mm} | {w / base_mm for w in widths} | {w / shade_mm for w in widths}
    best = None
    for scale in (s for s in scales if s > 0):
        high_err = abs(height / (high_mm * scale) - 1)
        base_errs = sorted(((abs(w / (base_mm * scale) - 1), i) for i, w in enumerate(widths) if i in on_bottom))
        shade_errs = sorted(((abs(w / (shade_mm * scale) - 1), i) for i, w in enumerate(widths)))
        pick = None
        for be, bi in base_errs:
            for se, si in shade_errs:
                if si != bi:
                    pick = (max(be, se), be, se, bi, si)
                    break
            if pick:
                break
        if pick is None:
            continue
        worst = max(high_err, pick[0])
        if best is None or worst < best[0]:
            best = (worst, high_err, pick[1], pick[2], scale, widths[pick[3]], widths[pick[4]])
    if best is None:
        return False, "no pair of shapes to compare"
    worst, high_err, base_err, shade_err, scale, base_w, shade_w = best
    detail = (f"at {scale:.3f} drawing units per mm: base {base_w:.0f} wide ({base_err * 100:.0f}% off {base_mm} mm), "
              f"height {height:.0f} ({high_err * 100:.0f}% off {high_mm} mm), "
              f"shade {shade_w:.0f} wide ({shade_err * 100:.0f}% off {shade_mm} mm); worst {worst * 100:.0f}%")
    return worst <= tolerance, detail


def overall_width_note(doc, drawing):
    """Information only: the shapes' overall width against the page's overall width, at the same scale as the height."""
    bodies = [box(e) for e in bodies_of(doc)]
    if not bodies:
        return "no space-filling shapes"
    left, right = min(b[0] for b in bodies), max(b[0] + b[2] for b in bodies)
    top, bottom = min(b[1] for b in bodies), max(b[1] + b[3] for b in bodies)
    if bottom <= top:
        return "no height"
    want = drawing["overall_width_mm"] / drawing["total_height_mm"]
    got = (right - left) / (bottom - top)
    return f"overall width/height {got:.2f} against the page's {want:.2f}"


def newest(folder, suffix):
    found = sorted(Path(folder).glob(f"*{suffix}"), key=lambda p: p.stat().st_mtime) if Path(folder).is_dir() else []
    return found[-1] if found else None


def drawing_rows(out_dir, expected):
    """The criterion rows (name, ok, detail) for the drawing file in out_dir."""
    drawing = expected["drawing"]
    path = newest(out_dir, ".excalidraw")
    if path is None:
        return [("a drawing file (.excalidraw) was saved in the run folder", False, "none found")]
    rows = [("a drawing file (.excalidraw) was saved in the run folder", True, path.name)]
    doc, why = read_drawing(path)
    if doc is None:
        return rows + [("the file is a drawing file", False, why)]
    rows.append(("the file is a drawing file", True, f"type excalidraw, {len(live(doc))} elements"))
    shapes = shapes_of(doc)
    kinds = {}
    for e in shapes:
        kinds[e["type"]] = kinds.get(e["type"], 0) + 1
    rows.append((f"at least {drawing['min_shapes']} shapes", len(shapes) >= drawing["min_shapes"],
                 f"found {len(shapes)} (" + (", ".join(f"{n} {k}" for k, n in sorted(kinds.items())) or "none") + ")"))
    ok, detail = judge_sizes(doc, drawing["key_sizes_mm"])
    rows.append(("the lamp's sizes are written on the drawing", ok, detail))
    ok, detail = judge_proportions(doc, drawing)
    rows.append((f"base, height and shade stand in the page's proportions (within {drawing['tolerance'] * 100:.0f}%)", ok, detail))
    return rows


def svg_note(out_dir):
    """Information: whether an exported picture was saved, and what is in it."""
    path = newest(out_dir, ".svg")
    if path is None:
        return "no .svg picture was saved (optional)"
    text = path.read_text(errors="replace")
    if "<svg" not in text[:2000]:
        return f"{path.name} is not an svg picture"
    return f"{path.name}, {len(text)} bytes, {text.count('<path')} paths"


def cmd_check(args):
    expected = json.loads(Path(args.expected).read_text())
    rows = drawing_rows(Path(args.run) / "out", expected)
    for name, ok, detail in rows:
        print("\t".join(["PASS" if ok else "FAIL", name, detail]))
    return 0 if all(ok for _, ok, _ in rows) else 1


# ---------------------------------------------------------------- the confirmation sheets, from the recorded bus

def bus_messages(path):
    try:
        lines = Path(path).read_text(errors="replace").splitlines()
    except OSError:
        return
    for line in lines:
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if isinstance(m, dict):
            yield m


def data_of(m):
    return (m.get("payload") or {}).get("data") or []


def confirm_traffic(path):
    """[(request, answer or None)] in bus order for org.quire.Confirm1.Confirm calls.

    A call is paired with its answer through the object path the call returns: the Response signal on that path is the
    sheet's answer. (The router's own Response signals, to its callers, have other paths and are not mixed in.)
    """
    calls, paths, answers = {}, {}, {}
    order = []
    for m in bus_messages(path):
        data = data_of(m)
        if not data:
            continue
        kind, interface, member = m.get("type"), str(m.get("interface", "")), m.get("member")
        try:
            if kind == "method_call" and interface == "org.quire.Confirm1" and member == "Confirm":
                calls[m.get("cookie")] = json.loads(data[0])
                order.append(m.get("cookie"))
            elif kind == "method_return" and m.get("reply_cookie") in calls and isinstance(data[0], str):
                paths[m["reply_cookie"]] = data[0]
            elif kind == "signal" and interface.startswith("org.quire.Intents1") and member == "Response":
                answers[m.get("path")] = json.loads(data[-1])
        except (ValueError, TypeError):
            continue
    return [(calls[c], answers.get(paths.get(c))) for c in order]


def request_row(request, answer):
    brief = request.get("brief")
    brief_text = brief.get("text") if isinstance(brief, dict) else None
    value = (answer or {}).get("v") if isinstance((answer or {}).get("v"), dict) else {}
    written = value.get("written")
    row = {
        "id": str(request.get("id")),
        "app": str(request.get("app")),
        "action": str(request.get("action")),
        "effect": str(request.get("effect")),
        "gesture": str(request.get("gesture", "press")),
        "kind": "brief" if brief_text is not None else "step",
        "answer": (answer or {}).get("kind", "none"),
        "scope": str(value.get("scope", "")),
    }
    if brief_text is not None:
        row["brief"] = brief_text
        row["written"] = "missing" if written is None else ("unchanged" if written == brief_text else "edited")
    return row


def sheet_rows(path):
    return [request_row(r, a) for r, a in confirm_traffic(path)]


def cmd_sheets(args):
    for row in sheet_rows(args.bus):
        print(json.dumps(row))
    return 0


def cmd_sheet_info(args):
    for request, _ in confirm_traffic(args.bus):
        if str(request.get("id")) == args.id:
            row = request_row(request, None)
            print("\t".join([row["kind"], row["gesture"], row["app"], row["action"]]))
            return 0
    return 1


def cmd_sheet_answer(args):
    """Exit 0 and print the answer's kind when the bus carried a reply for sheet ID; 1 when it did not (yet)."""
    for request, answer in confirm_traffic(args.bus):
        if str(request.get("id")) == args.id and answer is not None:
            print(answer.get("kind", "none"))
            return 0
    return 1


# A task's answer phase that is over: nothing more comes from it.
CLOSED_PHASES = {"done", "cancelled", "failed"}


def task_phases(path):
    """({task: its latest answer phase}, the bus time in seconds of the last assistant or sheet message, or None)."""
    phases, last = {}, None
    for m in bus_messages(path):
        interface = str(m.get("interface", ""))
        if not (interface.startswith("org.quire.Companion1") or interface.startswith("org.quire.Confirm1")):
            continue
        last = m.get("timestamp-realtime", 0) / 1e6
        data = data_of(m)
        if m.get("member") != "Updated" or not data or not isinstance(data[0], str):
            continue
        try:
            answer = json.loads(data[0])
        except ValueError:
            continue
        if isinstance(answer, dict) and answer.get("task") and isinstance(answer.get("phase"), dict):
            phases[answer["task"]] = answer["phase"]
    return phases, last


def open_question(phase):
    """The words of a question or form the task waits on (the person's, never a sheet), else None."""
    if phase.get("kind") != "needs_you" or not isinstance(phase.get("v"), dict):
        return None
    needs = phase["v"]
    if needs.get("kind") == "confirm":
        return None
    v = needs.get("v")
    text = v.get("text") if isinstance(v, dict) else None
    return str(text or needs.get("kind"))


def screen_waits(path):
    """([the question of each screen run whose latest state is waiting_for_user], the bus time in seconds of the last
    screen-run message, or None). A screen run's question goes to the person, not through the assistant's answer."""
    state, asked, last = {}, {}, None
    for m in bus_messages(path):
        if not str(m.get("interface", "")).startswith("org.quire.Cua1.Run"):
            continue
        last = m.get("timestamp-realtime", 0) / 1e6
        run, data = m.get("path"), data_of(m)
        if m.get("member") == "StateChanged" and data:
            state[run] = str(data[0])
        elif m.get("member") == "AskUser" and len(data) > 1:
            try:
                asked[run] = json.loads(data[1])["body"]["question"]["value"]
            except (ValueError, KeyError, TypeError):
                asked[run] = "a question"
    return [asked.get(r, "a question") for r, st in state.items() if st == "waiting_for_user"], last


def cmd_stalled(args):
    """Exit 0 and print "task: question" lines when every task still open waits on a question (not a sheet) and nothing
    has moved on the bus for --quiet seconds; 1 otherwise. A sheet (a confirmation) is never a stall: it is answered."""
    waits, screen_last = screen_waits(args.bus)
    if waits and screen_last is not None and time.time() - screen_last >= args.quiet:
        for question in waits:
            print(f"screen run: {short(question, 200)}")
        return 0
    phases, last = task_phases(args.bus)
    if last is None or time.time() - last < args.quiet:
        return 1
    open_tasks = {t: p for t, p in phases.items() if p.get("kind") not in CLOSED_PHASES}
    questions = {t: open_question(p) for t, p in open_tasks.items()}
    if not questions or any(q is None for q in questions.values()):
        return 1
    for task, question in sorted(questions.items()):
        print(f"{task}: {short(question, 200)}")
    return 0


# ---------------------------------------------------------------- the report

def read_tsv(path):
    try:
        return [line.split("\t") for line in Path(path).read_text().splitlines() if line.strip()]
    except OSError:
        return []


def short(text, limit):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "..."


def turn_lines(rows):
    """One line per model turn: who, how long, the tool calls with short arguments, and any words."""
    lines = []
    for row in rows:
        answer = (row.get("answer") or {}).get("v") or {}
        calls = answer.get("calls", []) if isinstance(answer, dict) else []
        said = answer.get("text", "") if isinstance(answer, dict) else ""
        what = "; ".join(f"{c.get('name', '?')}({short(c.get('args', ''), 80)})" for c in calls) or "no tool call"
        words = f" says: {short(said, 160)}" if said else ""
        lines.append(f"- {row.get('n', '?')}. {w1.conversation_label(row)} ({int(row.get('took_ms') or 0)} ms): {what}{words}")
    return lines


STOP_WORDS = ("fatal runtime error", "panicked", "overflowed its stack")


def services_stopped(run):
    """[(log file, last line that says it stopped)] for the logs of services that ended badly."""
    run = Path(run)
    found = []
    logs = sorted((run / "agent-logs").glob("*.log")) if (run / "agent-logs").is_dir() else []
    logs += [run / n for n in ("cuad.log", "daemon.log", "casement-up.log") if (run / n).is_file()]
    for log in logs:
        hits = [l.strip() for l in log.read_text(errors="replace").splitlines() if any(w in l for w in STOP_WORDS)]
        if hits:
            found.append((log.name, short(hits[-1], 160)))
    return found


def build_report(run, expected):
    """(text, all_passed) for the run folder `run`."""
    run = Path(run)
    stamps = w1.read_stamps(run / "stamps.tsv")
    trace = w1.read_jsonl(run / "trace.jsonl")
    audit = w1.read_jsonl(run / "agents/.local/state/quire/inferd/audit.jsonl")
    started = stamps.get("start", (0, 0))[1]
    steps = [s for s in w1.screen_steps(audit) if s[0] >= started]

    checks = drawing_rows(run / "out", expected)
    briefs = [r for r in sheet_rows(run / "bus.jsonl") if r["kind"] == "brief"]
    if briefs:
        unchanged = [r for r in briefs if r.get("written") == "unchanged"]
        checks.append(("every brief sheet was answered with its words unchanged", len(unchanged) == len(briefs),
                       f"{len(unchanged)} of {len(briefs)} brief sheet(s) came back with the written text"))
    stopped = services_stopped(run)
    checks.append(("no service stopped on its own", not stopped,
                   "; ".join(f"{n}: {l}" for n, l in stopped) or "none seen"))
    texts = w1.last_words(trace)
    turn = run / "turn.txt"
    if turn.is_file():
        texts.append(turn.read_text(errors="replace"))
    hits = w1.guard_hits(texts)
    checks.append(("the turn did not end in the guard's words", not hits, ", ".join(f'"{h}"' for h in hits) or "none seen"))
    stall = run / "stalled.txt"
    stalled = stall.read_text(errors="replace").strip() if stall.is_file() else ""
    checks.append(("the run did not stop on a question nobody here answers", not stalled,
                   short(stalled.replace("\n", "; "), 300) or "none seen"))
    ok_all = all(ok for _, ok, _ in checks)

    lines = [f"# Workflow W2 (lamp page to a drawing): {'PASS' if ok_all else 'FAIL'}", "", f"Run folder: {run}", ""]
    lines += ["## Checks", ""] + w1.table(["", "Check", "Detail"], [("PASS" if ok else "FAIL", n, d) for n, ok, d in checks]) + [""]

    lines += ["## Information (not a pass or fail)", ""]
    drawing = expected["drawing"]
    path = newest(run / "out", ".excalidraw")
    doc = read_drawing(path)[0] if path else None
    lines += [f"- Exported picture: {svg_note(run / 'out')}"]
    if doc is not None:
        lines += [f"- {overall_width_note(doc, drawing)}"]
    if not briefs:
        lines += ["- No brief sheet appeared (the assistant may not have needed one)."]
    lines += ["- Not checked by the script: that the drawing looks like the lamp, and that the assistant used the screen only "
              "(no calls to the drawing app). Look at the pictures.", ""]

    lines += ["## Sheets answered", ""]
    mine = read_tsv(run / "sheets.tsv")
    if mine:
        lines += w1.table(["Time (s after start)", "Kind", "What it asked", "Answer given", "Keys", "Result"],
                          [(_since(r[0], started), r[2], r[3], r[4], r[5] if len(r) > 5 else "", r[6] if len(r) > 6 else "")
                           for r in mine if len(r) >= 5])
    else:
        lines += ["No sheet was answered."]
    seen = sheet_rows(run / "bus.jsonl")
    if seen:
        lines += ["", "As the bus carried them:", ""]
        lines += w1.table(["Kind", "App", "Action", "Effect", "Gesture", "Reply", "Scope", "Brief words"],
                          [(r["kind"], r["app"], r["action"], r["effect"], r["gesture"], r["answer"], r["scope"],
                            r.get("written", "")) for r in seen])
    lines += [""]

    seen_files = run / "files-made.txt"
    made = [l for l in seen_files.read_text().splitlines() if l] if seen_files.is_file() else []
    lines += ["## Files made during the run", ""] + ([f"- {m}" for m in made[:30]] or ["None listed."]) + [""]

    lines += ["## Stage times (seconds)", ""]
    rows = w1.stage_rows(stamps, STAGES)
    lines += w1.table(["Stage", "Since the previous", "Since the start"],
                      [(a, w1.fmt_s(b), w1.fmt_s(c)) for a, b, c in rows]) if rows else ["No stage marks were recorded."]
    lines += [""]

    lines += ["## Assistant and helper turns", ""]
    groups = w1.summarize_turns(trace)
    if groups:
        lines += w1.table(["Who", "Turns", "Model time (s)", "Words in", "Words out", "Actions chosen"],
                          [(label, g["turns"], f"{g['ms'] / 1000:.1f}", g["in"], g["out"],
                            ", ".join(f"{n} x{c}" for n, c in sorted(g["calls"].items())) or "none")
                           for label, g in sorted(groups.items())])
    else:
        lines += ["No model log was recorded."]
    lines += [""]

    lines += ["## Turn by turn", ""] + (turn_lines(trace) or ["No model log was recorded."]) + [""]

    lines += ["## Services that stopped", ""]
    lines += [f"- {n}: {l}" for n, l in stopped] or ["None seen."]
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


def _since(epoch, started):
    try:
        return f"{int(epoch) - started}"
    except ValueError:
        return epoch


def cmd_report(args):
    expected = json.loads(Path(args.expected).read_text())
    text, ok = build_report(args.run, expected)
    (Path(args.run) / "report.md").write_text(text)
    print(text)
    return 0 if ok else 1


# ---------------------------------------------------------------- the command line

OWN = {"sentence", "browser-prefs", "check", "sheet-info", "sheet-answer", "sheets", "stalled", "report"}


def build_parser():
    parser = argparse.ArgumentParser(description="the helper behind scenarios/w2-excalidraw.sh")
    sub = parser.add_subparsers(dest="command", required=True)

    def command(name, func, *options):
        p = sub.add_parser(name)
        p.set_defaults(func=func)
        for flags, kwargs in options:
            p.add_argument(*flags, **kwargs)

    command("sentence", cmd_sentence)
    command("browser-prefs", cmd_browser_prefs, (["--download-dir"], {"required": True}), (["--homepage"], {"default": ""}))
    command("check", cmd_check, (["--run"], {"required": True}), (["--expected"], {"required": True}))
    command("sheet-info", cmd_sheet_info, (["--bus"], {"required": True}), (["--id"], {"required": True}))
    command("sheet-answer", cmd_sheet_answer, (["--bus"], {"required": True}), (["--id"], {"required": True}))
    command("sheets", cmd_sheets, (["--bus"], {"required": True}))
    command("stalled", cmd_stalled, (["--bus"], {"required": True}), (["--quiet"], {"type": float, "default": 120.0}))
    command("report", cmd_report, (["--run"], {"required": True}), (["--expected"], {"required": True}))
    return parser


def main(argv):
    if argv and argv[0] not in OWN and not argv[0].startswith("-"):
        return w1.main(argv)
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (OSError, ValueError, KeyError) as error:
        print(f"w2.py {args.command}: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
