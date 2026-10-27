"""Chris's calendar, from the Aloi Meetings helper. (Named agenda.py so it
doesn't shadow the standard library's calendar module.)

The helper (bin/aloi-meetings in the Aloi Meetings bar plugin) already
signs in to Microsoft 365 and shapes today's meetings; Sidecar asks it, so
there's one sign-in and one idea of what "today" holds. From that Sidecar
knows what a call is called and who's in it, offers to listen a couple of
minutes before a meeting, and notices when the next one begins.
"""
import asyncio
import json
import os
import time
from datetime import datetime
from pathlib import Path

REFRESH = 5 * 60  # seconds between asking Microsoft 365
LEAD = 2 * 60  # how long before a meeting the "about to start" offer comes
SLACK = 5 * 60  # a call this close to a meeting's start counts as that meeting
CANDIDATES = [
    Path.home() / ".config/omarchy/plugins/aloi.meetings/bin/aloi-meetings",
    Path.home() / "Work/meetings/bin/aloi-meetings",
]


def helper():
    override = os.environ.get("SIDECAR_CALENDAR")
    if override is not None:
        return override or None  # empty turns the calendar off (tests)
    return next((str(p) for p in CANDIDATES if p.exists()), None)


def epoch(iso):
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return 0


def counts(e):
    """A meeting Chris is actually going to: timed, on, not declined or free."""
    return (not e.get("allDay") and not e.get("cancelled") and e.get("showAs") != "free"
            and e.get("response") != "declined" and e["t0"] < e["t1"])


def event_meta(e):
    """What a Sidecar meeting keeps of its calendar event."""
    return {"id": e["id"], "subject": e.get("subject") or "Meeting", "start": e["t0"], "end": e["t1"],
            "organizer": e.get("organizer", ""), "attendees": e.get("attendees", []),
            "joinUrl": e.get("joinUrl", ""), "webLink": e.get("webLink", ""), "location": e.get("location", "")}


class Calendar:
    def __init__(self):
        self.program = helper()
        self.events = []
        self.fetched = 0
        self.error = None

    async def refresh(self):
        if not self.program:
            return
        try:
            proc = await asyncio.create_subprocess_exec(self.program, "today", stdout=asyncio.subprocess.PIPE,
                                                        stderr=asyncio.subprocess.DEVNULL)
            out, _ = await asyncio.wait_for(proc.communicate(), 60)
            reply = json.loads(out or b"{}")
        except (OSError, asyncio.TimeoutError, json.JSONDecodeError) as e:
            self.error = str(e) or type(e).__name__
            return
        if "events" not in reply:
            self.error = reply.get("error", "no events")  # signed out, offline: keep the last good day
            return
        events = []
        for e in reply["events"]:
            e = {**e, "t0": epoch(e.get("start")), "t1": epoch(e.get("end"))}
            if counts(e):
                events.append(e)
        self.events = sorted(events, key=lambda e: e["t0"])
        self.fetched = time.time()
        self.error = None

    def due(self):
        return self.program and time.time() - self.fetched > REFRESH

    def happening(self, t=None):
        """The meeting a call starting now most likely is."""
        t = t or time.time()
        on = [e for e in self.events if e["t0"] - SLACK <= t < e["t1"]]
        # One under way wins, unless it's nearly over (then the call is
        # more likely the next one); otherwise the one about to start.
        running = [e for e in on if e["t0"] <= t and e["t1"] - t > SLACK]
        if running:
            return max(running, key=lambda e: e["t0"])
        return min(on, key=lambda e: abs(e["t0"] - t)) if on else None

    def starting(self, t=None, within=LEAD):
        """Meetings that begin within the next couple of minutes."""
        t = t or time.time()
        return [e for e in self.events if 0 < e["t0"] - t <= within]

    def begun(self, t=None, window=90):
        """Meetings that began in the last minute and a half."""
        t = t or time.time()
        return [e for e in self.events if 0 <= t - e["t0"] < window]


def normalize(e):
    """A calendar event as Sidecar keeps it, whether it came from the helper
    (ISO times) or is already Sidecar's own shape (epoch seconds)."""
    if not e or not e.get("id"):
        return e or None
    t0 = e.get("t0") or (e["start"] if isinstance(e.get("start"), (int, float)) else epoch(e.get("start")))
    t1 = e.get("t1") or (e["end"] if isinstance(e.get("end"), (int, float)) else epoch(e.get("end")))
    return event_meta({**e, "t0": t0, "t1": t1})


def people(event, me):
    """Who's in the meeting, by name, without Chris himself."""
    names = [a.get("name") or a.get("email", "") for a in (event or {}).get("attendees", [])]
    return [n for n in names if n and not n.lower().startswith(me.lower())]


async def join(url):
    """Opens the meeting the way the Aloi Meetings bar does: Teams and Meet as
    Omarchy web apps, anything else in the default handler."""
    if not url.startswith("https://"):
        return
    command = ["omarchy-launch-webapp", url] if ("teams." in url or "meet.google." in url) else ["xdg-open", url]
    try:
        await asyncio.create_subprocess_exec(*command, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
    except FileNotFoundError:
        pass
