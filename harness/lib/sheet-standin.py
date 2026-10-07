#!/usr/bin/env python3
"""A stand-in sheet host: owns org.quire.AccountsSheet1 the way sill does, logs every view accountd opens or updates,
and sends the Input signals a script gives it. For the one accounts scenario sill cannot draw yet (the typed mail
server form: sill's pin maps neither the new FieldKind variants nor ProblemKind::Invalid), so the porter side is proven
through the bus, as sill's own accept script drives accountd's sheet with its accountd stand-in.

  sheet-standin.py --bus ADDR --proc DIR --log FILE --commands FIFO

It names itself `sill-shell.scope` (the caller table's sheet_host unit) in $PROC/<pid>/cgroup before it takes the name.
LOG: one JSON line per Open/Update/Close: {"op","handle","view"}.
FIFO: one command per line: `send <input json>` sends Input(<current handle>, json); `quit` ends it.
Run with -I; needs dbus_next."""
import argparse
import asyncio
import json
import os
import sys

from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method, signal


class Sheet(ServiceInterface):
    def __init__(self, log):
        super().__init__("org.quire.AccountsSheet1")
        self.log = log
        self.handle = None

    def _log(self, op, handle, view=None):
        self.handle = handle if op != "close" else self.handle
        with open(self.log, "a") as f:
            f.write(json.dumps({"op": op, "handle": handle, "view": json.loads(view) if view else None}) + "\n")

    @method()
    def Open(self, handle: "s", parent: "s", view: "s"):
        self._log("open", handle, view)

    @method()
    def Update(self, handle: "s", view: "s"):
        self._log("update", handle, view)

    @method()
    def Close(self, handle: "s"):
        self._log("close", handle)

    @signal()
    def Input(self, handle: "s", input: "s") -> "ss":
        return [handle, input]


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bus", required=True)
    ap.add_argument("--proc", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--commands", required=True)
    a = ap.parse_args()
    pid = os.getpid()
    d = os.path.join(a.proc, str(pid))
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "cgroup"), "w") as f:
        f.write("0::/user.slice/user-1000.slice/user@1000.service/app.slice/sill-shell.scope\n")
    bus = await MessageBus(bus_address=a.bus).connect()
    sheet = Sheet(a.log)
    bus.export("/org/quire/AccountsSheet1", sheet)
    await bus.request_name("org.quire.AccountsSheet1")
    print("ready", flush=True)
    loop = asyncio.get_event_loop()
    fd = os.open(a.commands, os.O_RDWR)
    reader = asyncio.StreamReader()
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), os.fdopen(fd, "rb", 0))
    while True:
        line = (await reader.readline()).decode().strip()
        if not line:
            continue
        if line == "quit":
            return 0
        if line.startswith("send "):
            sheet.Input(sheet.handle, line[5:])
            print("sent", line[5:80], flush=True)


sys.exit(asyncio.run(main()))
