"""Chris's calendar, from Aloi Calendar's engine. (Named agenda.py so it
doesn't shadow the standard library's calendar module.)

Aloi Calendar keeps the one copy of Outlook (through vmail's sign-in), so
Sidecar asks it for today's meetings rather than signing in to Microsoft
itself. From those Sidecar knows what a call is called and who's in it,
offers to listen a couple of minutes before a meeting, and notices when the
next one begins. Without Aloi Calendar, calls are named by their window.
"""
import asyncio
import difflib
import json
import os
import shutil
import time
from datetime import datetime
from pathlib import Path

REFRESH = 60  # seconds between asking Aloi Calendar (a local read; it keeps Outlook current)
LEAD = 2 * 60  # how long before a meeting the "about to start" offer comes
SLACK = 5 * 60  # a call this close to a meeting's start counts as that meeting
JOIN = 10 * 60  # a call starting later than this into a slot is something else (the window's name still matches)


def helper():
    """Aloi Calendar's engine, or SIDECAR_CALENDAR (a stand-in for tests;
    empty turns the calendar off)."""
    override = os.environ.get("SIDECAR_CALENDAR")
    if override is not None:
        return override or None
    return shutil.which("aloi-calendar-engine")


def from_engine(o):
    """One of Aloi Calendar's Outlook occurrences as Sidecar keeps a
    calendar event (the shape Microsoft's own fields had)."""
    if o.get("all_day"):
        start, end = o.get("start_date", "") + "T00:00:00Z", o.get("end_date", "") + "T00:00:00Z"
    else:
        start, end = o.get("start", ""), o.get("end", "")
    return {
        "id": (o.get("id") or "").removeprefix("outlook:"),
        "subject": (o.get("title") or "").strip(),
        "start": start, "end": end,
        "allDay": bool(o.get("all_day")),
        "cancelled": False,  # Aloi Calendar leaves cancelled meetings out
        "showAs": (o.get("show_as") or "").lower(),
        "response": (o.get("response") or "").lower(),
        "organizer": o.get("organizer") or "",
        "attendees": [{"name": a.get("name") or a.get("email", ""), "email": a.get("email", "")}
                      for a in o.get("attendees") or []],
        "joinUrl": o.get("join_url") or "",
        "webLink": o.get("web_link") or "",
        "location": (o.get("location") or "").strip(),
    }


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
        day = datetime.now().date().isoformat()
        try:
            proc = await asyncio.create_subprocess_exec(
                self.program, "query", "--from", day, "--days", "1", "--calendar", "outlook", "--json",
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            out, err = await asyncio.wait_for(proc.communicate(), 60)
            reply = json.loads(out or b"null")
        except (OSError, asyncio.TimeoutError, json.JSONDecodeError) as e:
            self.error = str(e) or type(e).__name__
            return
        if not isinstance(reply, list):
            self.error = (err or b"").decode(errors="replace").strip() or "no events"  # keep the last good day
            return
        events = []
        for e in map(from_engine, reply):
            e = {**e, "t0": epoch(e.get("start")), "t1": epoch(e.get("end"))}
            if counts(e):
                events.append(e)
        self.events = sorted(events, key=lambda e: e["t0"])
        self.fetched = time.time()
        self.error = None

    def due(self):
        return self.program and time.time() - self.fetched > REFRESH

    def happening(self, t=None, used=()):
        """The meeting a call starting now most likely is. Meetings in used
        were already had (an earlier call ended under that name) and aren't
        it: a second call in the same slot is a different conversation."""
        t = t or time.time()
        on = [e for e in self.events if e["t0"] - SLACK <= t < min(e["t1"], e["t0"] + JOIN) and e["id"] not in used]
        # One under way wins, unless it's nearly over (then the call is
        # more likely the next one); otherwise the one about to start. A call
        # well into a slot isn't taken for it: by then it's usually another
        # conversation, and a late join still matches by the call window.
        running = [e for e in on if e["t0"] <= t and e["t1"] - t > SLACK]
        if running:
            return max(running, key=lambda e: e["t0"])
        return min(on, key=lambda e: abs(e["t0"] - t)) if on else None

    def matching(self, name, t=None, used=()):
        """Today's meeting a call app's window names, if one's near enough in
        time: a call can start early or run into the next slot."""
        if not name:
            return None
        t = t or time.time()
        key = name.lower()
        near = [e for e in self.events if e["t0"] - 30 * 60 <= t < e["t1"] + 15 * 60 and e["id"] not in used]
        scored = [(difflib.SequenceMatcher(None, key, e["subject"].lower()).ratio()
                   + (0.5 if key in e["subject"].lower() or e["subject"].lower() in key else 0), e) for e in near]
        scored = [x for x in scored if x[0] >= 0.6]
        return max(scored, key=lambda x: x[0])[1] if scored else None

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
    """Opens the meeting the way the bar plugin does: Teams and Meet as
    Omarchy web apps, anything else in the default handler."""
    if not url.startswith("https://"):
        return
    command = ["omarchy-launch-webapp", url] if ("teams." in url or "meet.google." in url) else ["xdg-open", url]
    try:
        await asyncio.create_subprocess_exec(*command, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
    except FileNotFoundError:
        pass
