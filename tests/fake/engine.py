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
state = {"listening": True}
clients = set()


def segments():
    t0 = time.time() - 600
    for i, (who, text) in enumerate(LINES):
        start = t0 + i * 40
        yield {"type": "segment", "id": i, "speaker": who, "start": start, "end": start + 6, "text": text,
               "time": time.strftime("%H:%M:%S", time.localtime(start))}


def channels():
    return [{"label": "Mic", "speaker": "Chris", "level": 0.004, "alive": True, "speaking": False},
            {"label": "Laptop", "speaker": "Them", "level": 0.03, "alive": True, "speaking": True},
            {"label": "Display A", "speaker": "Them", "level": 0.0, "alive": True, "speaking": False}]


async def events(request):
    resp = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
    await resp.prepare(request)
    q = asyncio.Queue()
    clients.add(q)
    hello = [{"type": "meeting", "meeting": "2026-10-26_093000", "path": "/tmp/2026-10-26_093000.jsonl", "lines": len(LINES)},
             {"type": "state", "listening": state["listening"], "channels": []}, *segments(),
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


async def listen(request):
    body = await request.json()
    state["listening"] = bool(body.get("on"))
    for q in clients:
        q.put_nowait({"type": "state", "listening": state["listening"], "channels": []})
    return web.json_response(state)


async def new_meeting(request):
    return web.json_response({})


app = web.Application()
app.router.add_get("/events", events)
app.router.add_post("/listen", listen)
app.router.add_post("/meeting/new", new_meeting)
web.run_app(app, host="127.0.0.1", port=PORT, print=None)
