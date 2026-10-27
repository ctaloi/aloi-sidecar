#!/usr/bin/env python3
"""The calendar side of the engine, against a stand-in Aloi Meetings helper:
which meeting a call is, what's about to start, and what a meeting keeps.

    engine/.venv/bin/python tests/engine_agenda.py
"""
import asyncio
import json
import os
import stat
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))


def iso(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    now = time.time()
    events = [
        {"id": "a", "subject": "Standup", "start": iso(now - 3600), "end": iso(now - 1800), "showAs": "busy", "response": "organizer"},
        {"id": "b", "subject": "Northwind weekly", "start": iso(now - 120), "end": iso(now + 1680), "showAs": "busy",
         "response": "accepted", "organizer": "Amy Reed", "joinUrl": "https://teams.microsoft.com/l/meetup-join/x",
         "attendees": [{"name": "Amy Reed", "email": "amy@northwind.example"}, {"name": "Chris Aloi", "email": "c@x"}]},
        {"id": "c", "subject": "Declined thing", "start": iso(now + 60), "end": iso(now + 600), "showAs": "busy", "response": "declined"},
        {"id": "d", "subject": "Harbor review", "start": iso(now + 90), "end": iso(now + 1800), "showAs": "busy", "response": "accepted"},
        {"id": "e", "subject": "Lunch", "start": iso(now + 100), "end": iso(now + 3600), "showAs": "free", "response": "accepted"},
        {"id": "g", "subject": "Late call", "start": iso(now + 4000), "end": iso(now + 5000), "showAs": "busy", "response": "accepted"},
        {"id": "f", "subject": "Holiday", "start": iso(now - 9999), "end": iso(now + 9999), "allDay": True},
    ]
    tmp = Path(tempfile.mkdtemp(prefix="sidecar-agenda-"))
    fake = tmp / "aloi-meetings"
    fake.write_text("#!/bin/sh\ncat <<'JSON'\n" + json.dumps({"day": "x", "events": events}) + "\nJSON\n")
    fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
    os.environ["SIDECAR_CALENDAR"] = str(fake)
    import agenda

    failures = []

    def check(name, ok, detail=""):
        print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  {detail}"))
        if not ok:
            failures.append(name)

    cal = agenda.Calendar()
    asyncio.run(cal.refresh())
    ids = [e["id"] for e in cal.events]
    check("declined, free and all-day meetings don't count", ids == ["a", "b", "d", "g"], ids)
    on = cal.happening(now)
    check("a call now is the meeting that's on", on and on["id"] == "b", on)
    check("a meeting under way wins over one about to start", cal.happening(now + 85)["id"] == "b")
    check("near the end of one, a call is the next", cal.happening(now + 1500)["id"] == "d")
    check("a call just before a meeting is that meeting", cal.happening(now + 3900)["id"] == "g")
    check("nothing on, nothing named", cal.happening(now + 6000) is None)
    check("what's about to start", [e["id"] for e in cal.starting(now)] == ["d"])
    check("what just began", [e["id"] for e in cal.begun(now + 95)] == ["d"])
    meta = agenda.event_meta(on)
    check("a meeting keeps its subject, times and join link",
          meta["subject"] == "Northwind weekly" and abs(meta["start"] - (now - 120)) < 2 and meta["joinUrl"].startswith("https://"))
    check("people leave out Chris", agenda.people(meta, "Chris") == ["Amy Reed"])
    check("normalizing twice changes nothing", agenda.normalize(agenda.normalize(events[1])) == agenda.normalize(events[1]))
    os.environ["SIDECAR_CALENDAR"] = ""
    check("an empty setting turns the calendar off", agenda.Calendar().program is None)
    print(f"\n{'All passed' if not failures else str(len(failures)) + ' failed'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
