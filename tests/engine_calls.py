#!/usr/bin/env python3
"""What a call does on its own: the mic going hot starts a meeting named from
the call app's window and the calendar, Not now throws it away, and the call
ending ends the meeting unless Not now keeps it. Nothing is recorded: the
recorders and notifications are stand-ins.

    engine/.venv/bin/python tests/engine_calls.py
"""
import asyncio
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TMP = Path(tempfile.mkdtemp(prefix="sidecar-calls-"))
os.environ.update(SIDECAR_MEETINGS=str(TMP / "meetings"), SIDECAR_SETTINGS=str(TMP / "settings.json"),
                  SIDECAR_CALENDAR="", SIDECAR_CALL_WATCH="0")
sys.path.insert(0, str(ROOT / "engine"))
import calls  # noqa: E402
import engine  # noqa: E402

failures = []


def check(name, ok):
    print(("PASS " if ok else "FAIL ") + name)
    if not ok:
        failures.append(name)


async def main():
    answers = []  # what each notification gets: an action name, or None for no answer
    shown = []

    async def notify(title, body, actions, timeout=60):
        shown.append((title, body, [a for a, _ in actions]))
        return answers.pop(0) if answers else None

    async def context():
        return {"app": "Teams", "title": "Weekly sync"}

    calls.notify, calls.context = notify, context
    engine.END_AFTER = 0.2
    app = engine.Sidecar()

    async def set_listening(on):  # no recorders: nothing is heard
        if on and not app.current:
            await app.start_meeting()
            return
        app.listening = on
    app.set_listening = set_listening

    # Mic goes hot, nobody answers: it's recording, named from the window.
    answers[:] = [None]
    await app.call_started("Teams")
    await app.prompt
    check("a hot mic starts a meeting by itself", app.listening and app.current is not None)
    check("named from the Teams window", app.current.meta["title"] == "Weekly sync")
    check("the notification offers Not now", "discard" in shown[-1][2] and "Recording" in shown[-1][0])

    # The call ends, nobody answers: it ends by itself.
    m = app.current
    m.append({"speaker": "Them", "start": 1, "end": 2, "text": "Thanks, bye."})
    answers[:] = [None]
    await app.call_ended("Teams")
    await app.prompt
    check("the call ending ends the meeting by itself", app.current is None and m.meta["state"] == "ended")

    # Not now on the end notification keeps it going.
    answers[:] = [None]
    await app.call_started("Teams")
    await app.prompt
    m2 = app.current
    answers[:] = ["keep"]
    await app.call_ended("Teams")
    await app.prompt
    await asyncio.sleep(0.3)
    check("Not now keeps the meeting going", app.current is m2 and app.listening)
    await app.end_meeting()

    # Not now on the start notification throws the recording away.
    answers[:] = ["discard"]
    await app.call_started("Teams")
    await app.prompt
    check("Not now on a new call stops it", app.current is None and not app.listening)
    kept = [x for x in app.meetings.values() if x.meta["title"] == "Weekly sync"]
    check("and keeps nothing of it", len(kept) == 1)  # only the first one, which was heard and ended

    # Turned off in settings: nothing starts.
    app.set_settings({"watch_calls": False})
    await app.call_ended("Teams")
    await app.call_started("Teams")
    check("with the setting off, a hot mic starts nothing", app.current is None)

    print(f"\n{'All passed' if not failures else str(len(failures)) + ' failed'}  ({TMP})")
    sys.exit(1 if failures else 0)


asyncio.run(main())
