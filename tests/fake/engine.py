#!/usr/bin/env python3
"""A stand-in engine for screenshots and tests: a made-up meeting, live levels
and an interim line, with the real engine's /events, /listen and /meeting/new."""
import asyncio
import json
import sys
import time

from aiohttp import web

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8779
LINES = [
    ("Them", "Morning! Thanks for making time. We wanted to go over the new office cutover."),
    ("Chris", "Of course. Where are you with the move date?"),
    ("Them", "We're targeting the fourteenth. The circuit is in, but the main number still rings the old site."),
    ("Them", "And the front desk says some outbound calls show up as spam likely on cell phones."),
    ("Chris", "Okay, two things then. We'll schedule the number change for the night of the thirteenth."),
    ("Chris", "And I'll have the team look at the caller ID registration on your outbound numbers."),
    ("Them", "Perfect. Can you also send over pricing for two more conference phones?"),
    ("Chris", "Sure, I'll get that to you today."),
    ("Them", "One more thing, does the auto attendant need to change for the holiday hours?"),
]
NOW = time.time()
PAST = [
    ("Weekly operations", 3 * 3600, 34 * 60, [("Them", "Porting queue is down to six. The two stuck ones are waiting on the losing carrier."),
                                             ("Chris", "Okay. I'll chase the Lumen one myself this afternoon."),
                                             ("Them", "And the new softphone build goes to beta on Thursday.")]),
    ("Harbor Logistics, porting review", 26 * 3600, 22 * 60, [("Them", "We have four numbers left to port, all on the old carrier."),
                                                             ("Chris", "I'll send the LOA over today.")]),
    ("Call at 9:12", 4 * 86400, 8 * 60, [("Them", "Just checking whether the invoice went out."),
                                         ("Chris", "It did, Friday. I'll forward it again.")]),
]
current_id = "2026-10-26_093000"
state = {"listening": True}
clients = set()


def meta(mid, title, started, ended, st, lines, event=None):
    return {"id": mid, "title": title, "started": started, "ended": ended, "state": st, "event": event,
            "people": [], "notion": None, "lines": lines}


def segs(lines, t0, gap=40):
    return [{"id": i, "speaker": who, "start": t0 + i * gap, "end": t0 + i * gap + 6, "text": text}
            for i, (who, text) in enumerate(lines)]


def meetings():
    out = [meta(current_id, "Northwind Dental, office cutover", NOW - 600, None,
                "live" if state["listening"] else "paused", len(LINES), {"id": "x", "subject": "Northwind Dental, office cutover"})]
    for i, (title, ago, length, lines) in enumerate(PAST):
        out.append(meta(f"past-{i}", title, NOW - ago, NOW - ago + length, "ended", len(lines)))
    return out


def segments():
    for s in segs(LINES, NOW - 600):
        yield {"type": "segment", "meeting": current_id, **s, "time": time.strftime("%H:%M:%S", time.localtime(s["start"]))}


def channels():
    return [{"label": "Mic", "speaker": "Chris", "level": 0.004, "alive": True, "speaking": False},
            {"label": "Laptop", "speaker": "Them", "level": 0.03, "alive": True, "speaking": True},
            {"label": "Display A", "speaker": "Them", "level": 0.0, "alive": True, "speaking": False}]


def state_event():
    return {"type": "state", "listening": state["listening"], "current": current_id, "channels": []}


async def events(request):
    resp = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
    await resp.prepare(request)
    q = asyncio.Queue()
    clients.add(q)
    hello = [{"type": "meetings", "meetings": meetings()}, state_event(), *segments(),
             {"type": "interim", "label": "Laptop", "speaker": "Them", "text": "Right now it plays the regular greeting all day, so we'd want"}]
    try:
        for m in hello:
            await resp.write(f"data: {json.dumps(m)}\n\n".encode())
        while True:
            try:
                m = await asyncio.wait_for(q.get(), 0.3)
            except asyncio.TimeoutError:
                m = {"type": "levels", "channels": channels()} if state["listening"] else None
            if m:
                await resp.write(f"data: {json.dumps(m)}\n\n".encode())
    except (ConnectionResetError, asyncio.CancelledError):
        pass
    finally:
        clients.discard(q)
    return resp


async def meeting(request):
    mid = request.match_info["id"]
    for m in meetings():
        if m["id"] == mid:
            if mid == current_id:
                return web.json_response({"meeting": m, "segments": segs(LINES, NOW - 600)})
            i = int(mid.split("-")[1])
            return web.json_response({"meeting": m, "segments": segs(PAST[i][3], m["started"])})
    raise web.HTTPNotFound()


async def listen(request):
    body = await request.json()
    state["listening"] = bool(body.get("on"))
    for q in clients:
        q.put_nowait({"type": "meeting", "meeting": meetings()[0]})
        q.put_nowait(state_event())
    return web.json_response(state)


async def ok(request):
    return web.json_response({})


app = web.Application()
app.router.add_get("/events", events)
app.router.add_get("/meeting/{id}", meeting)
app.router.add_post("/listen", listen)
app.router.add_post("/meeting/start", ok)
app.router.add_post("/meeting/end", ok)
app.router.add_patch("/meeting/{id}", ok)
web.run_app(app, host="127.0.0.1", port=PORT, print=None)
