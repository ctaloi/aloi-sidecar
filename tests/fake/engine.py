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
    ("Mark", "Marked this moment"),
    ("Them", "Perfect. Can you also send over pricing for two more conference phones?"),
    ("Chris", "Sure, I'll get that to you today."),
    ("Note", "Check their contract end date before quoting"),
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
state = {"listening": True, "call": None, "settings": {"watch_calls": True}}
clients = set()

# What the past meetings came to: the first has a draft to check, the
# second is in Notion, the third is being drafted.
WRAPUP = {
    "title": "Weekly Operations",
    "tldr": "Porting is down to six; two are stuck with the losing carrier. Chris is chasing the Lumen port himself, and the softphone build goes to beta Thursday.",
    "summary": "The porting queue is down to six. Two are waiting on the losing carrier, one of them Lumen, which Chris will chase this afternoon.\n\nThe new softphone build is on track for beta on Thursday.",
    "topics": [{"title": "Porting queue", "points": ["Six ports left", "Two waiting on the losing carrier"]},
               {"title": "Softphone beta", "points": ["Build goes to beta Thursday"]}],
    "mine": [{"text": "Chase the stuck Lumen port with the carrier", "due": "this afternoon", "at": 1},
             {"text": "Send the beta testers the softphone build notes", "due": "Thursday", "at": 2, "done": True}],
    "theirs": [{"who": "Dana", "text": "Escalate the second stuck port with the losing carrier", "due": "tomorrow", "at": 0}],
    "decisions": [{"text": "The softphone build goes to beta on Thursday", "due": "", "at": 2}],
    "questions": [{"text": "Do the stuck ports need a new LOA?", "due": "", "at": 0}],
    "met_with": ["Internal"], "tags": ["Operations", "VoIP"], "format": "Video"}
wrapups = {
    "past-0": {"state": "ready", "error": None, "draft": WRAPUP, "edited": None, "drafted": NOW - 3 * 3600 + 40 * 60},
    "past-1": {"state": "ready", "error": None, "draft": {**WRAPUP, "title": "Harbor Logistics Porting Review"}, "edited": None,
               "drafted": NOW - 25 * 3600},
    "past-2": {"state": "drafting", "error": None, "draft": None, "edited": None, "started": NOW - 42},
}
notion = {"past-1": {"id": "abc", "url": "https://www.notion.so/abc", "state": "sent", "sent": NOW - 24 * 3600}}
skipped = set()


def meta(mid, title, started, ended, st, lines, event=None):
    w = wrapups.get(mid)
    return {"id": mid, "title": title, "started": started, "ended": ended, "state": st, "event": event,
            "people": [], "notion": notion.get(mid), "lines": lines, "skipped": mid in skipped,
            "wrapup": w["state"] if w else None, "edited": bool(w and w.get("edited"))}


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


def followups():
    out = []
    titles = {m["id"]: m for m in meetings()}
    for mid, w in wrapups.items():
        notes = (w.get("edited") or w.get("draft")) if w else None
        if not notes:
            continue
        for i, item in enumerate(notes["mine"]):
            out.append({"meeting": mid, "title": titles[mid]["title"], "started": titles[mid]["started"], "index": i,
                        "text": item["text"], "due": item.get("due", ""), "at": item.get("at", -1),
                        "done": bool(item.get("done")), "inNotion": mid in notion, "syncError": None})
    return sorted(out, key=lambda f: (f["started"], f["index"]))


def state_event():
    return {"type": "state", "listening": state["listening"], "current": current_id, "channels": [],
            "call": state["call"], "settings": state["settings"],
            "followups_open": sum(1 for f in followups() if not f["done"])}


async def get_followups(request):
    return web.json_response({"followups": followups()})


async def sync_followups(request):
    return web.json_response({"changed": 0, "followups": followups()})


def announce():
    for q in clients:
        q.put_nowait({"type": "meetings", "meetings": meetings()})
        q.put_nowait(state_event())


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


TAKEAWAYS = {"updated": NOW - 50, "lines": 9,
             "asked": [{"text": "Does the auto attendant need holiday hours?", "at": 10}],
             "mine": [{"text": "Send pricing for two conference phones today", "at": 9},
                      {"text": "Check caller ID registration on outbound numbers", "at": 5}],
             "decisions": [{"text": "Number change the night of the 13th", "at": 4}],
             "questions": []}


async def get_wrapup(request):
    mid = request.match_info["id"]
    return web.json_response({"wrapup": wrapups.get(mid), "takeaways": TAKEAWAYS if mid == current_id else None})


async def put_wrapup(request):
    mid = request.match_info["id"]
    body = await request.json()
    if mid in wrapups:
        wrapups[mid]["edited"] = body.get("edited")
    announce()
    return web.json_response({"wrapup": wrapups.get(mid)})


async def candidates(request):
    return web.json_response({"pages": [
        {"id": "p1", "title": "Weekly ops sync", "url": "", "created": "2026-10-26T14:05:00.000Z",
         "summary": "Ports, softphone beta and the stuck Lumen order."}]})


async def update(request):
    mid = request.match_info["id"]
    body = await request.json()
    if "skipped" in body:
        (skipped.add if body["skipped"] else skipped.discard)(mid)
    announce()
    return web.json_response({})


async def set_call(request):
    """For screenshots: pretend an app has the mic."""
    body = await request.json()
    state["call"] = body.get("call")
    state["listening"] = body.get("listening", state["listening"])
    announce()
    return web.json_response(state)


app = web.Application()
app.router.add_get("/events", events)
app.router.add_get("/meeting/{id}", meeting)
app.router.add_post("/listen", listen)
app.router.add_post("/meeting/start", ok)
app.router.add_post("/meeting/end", ok)
app.router.add_patch("/meeting/{id}", update)
app.router.add_get("/meeting/{id}/wrapup", get_wrapup)
app.router.add_put("/meeting/{id}/wrapup", put_wrapup)
app.router.add_post("/meeting/{id}/wrapup", ok)
app.router.add_get("/meeting/{id}/notion", candidates)
app.router.add_post("/meeting/{id}/notion", ok)
app.router.add_post("/meeting/{id}/resume", ok)
app.router.add_post("/meeting/{id}/note", ok)
app.router.add_delete("/meeting/{id}", ok)
app.router.add_patch("/settings", ok)
app.router.add_post("/_call", set_call)
app.router.add_get("/followups", get_followups)
app.router.add_post("/followups/sync", sync_followups)
app.router.add_post("/followups/done", ok)
web.run_app(app, host="127.0.0.1", port=PORT, print=None)
