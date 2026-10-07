#!/usr/bin/env python3
"""An app calling accountd's sheet methods (AddAccount, Reauthenticate) and waiting for the Request
object's Response: porter-rig-client has no add-account command (an interface ask against porter, see the
scenarios' report), so this does the one call it lacks. It names itself a Flatpak app the way
porter-rig-client does (the daemons' test-proc-root builds read $PROC/<pid>/cgroup).

  accounts-app.py --bus ADDR --proc DIR --app ID add-account [HINT]
  accounts-app.py --bus ADDR --proc DIR --app ID reauthenticate ACCOUNT-ID

Prints one JSON line: {"response": 0|1|2, "results": {...}} or {"error": "..."}; exit 0 when the response is 0.
Run with -I; needs dbus_next (python3-dbus-next)."""
import argparse
import asyncio
import json
import os
import sys

from dbus_next import Variant
from dbus_next.aio import MessageBus


def escape(text):
    out = []
    for b in text.encode():
        c = chr(b)
        if c == "-":
            out.append("\\x2d")
        elif c.isalnum() or c in "._":
            out.append(c)
        else:
            out.append("\\x%02x" % b)
    return "".join(out)


def plain(value):
    if isinstance(value, Variant):
        return plain(value.value)
    if isinstance(value, dict):
        return {k: plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain(v) for v in value]
    return value


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bus", required=True)
    ap.add_argument("--proc", required=True)
    ap.add_argument("--app", required=True)
    ap.add_argument("--timeout", type=float, default=120)
    ap.add_argument("what", choices=["add-account", "reauthenticate"])
    ap.add_argument("arg", nargs="?", default="")
    a = ap.parse_args()

    pid = os.getpid()
    d = os.path.join(a.proc, str(pid))
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "cgroup"), "w") as f:
        f.write("0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-flatpak-%s-%d.scope\n" % (escape(a.app), pid))
    try:
        bus = await MessageBus(bus_address=a.bus).connect()
        if a.what == "add-account":
            path, iface, method, sig, args = "/org/quire/Accounts1", "org.quire.Accounts1.Manager", "AddAccount", "ssa{sv}", [a.arg, "", {}]
        else:
            # The account's object path is under /org/quire/Accounts1/account/<id> (see Manager.List).
            path, iface, method, sig, args = "/org/quire/Accounts1/account/" + a.arg.replace("-", "_"), "org.quire.Accounts1.Account", "Reauthenticate", "sa{sv}", ["", {}]
        intro = await bus.introspect("org.quire.Accounts1", "/org/quire/Accounts1")
        from dbus_next import Message, MessageType
        got = asyncio.get_event_loop().create_future()
        request_path = {}

        def on_message(msg):
            if msg.message_type == MessageType.SIGNAL and msg.interface == "org.quire.Accounts1.Request" and msg.member == "Response":
                if request_path.get("p") in (None, msg.path):
                    if not got.done():
                        got.set_result({"response": msg.body[0], "results": plain(msg.body[1])})
            return False

        bus.add_message_handler(on_message)
        await bus.call(Message(
            destination="org.freedesktop.DBus", path="/org/freedesktop/DBus", interface="org.freedesktop.DBus",
            member="AddMatch", signature="s",
            body=["type='signal',interface='org.quire.Accounts1.Request',member='Response'"]))
        reply = await bus.call(Message(destination="org.quire.Accounts1", path=path, interface=iface, member=method, signature=sig, body=args))
        if reply.message_type == MessageType.ERROR:
            print(json.dumps({"error": "%s: %s" % (reply.error_name, reply.body)}))
            return 1
        request_path["p"] = reply.body[0] if reply.body else None
        print(json.dumps({"request": request_path["p"]}), flush=True)
        result = await asyncio.wait_for(got, a.timeout)
        print(json.dumps(result))
        return 0 if result["response"] == 0 else 1
    except asyncio.TimeoutError:
        print(json.dumps({"error": "no Response within the timeout"}))
        return 1
    finally:
        try:
            os.remove(os.path.join(d, "cgroup"))
            os.rmdir(d)
        except OSError:
            pass


sys.exit(asyncio.run(main()))
