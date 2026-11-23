#!/usr/bin/env python3
"""A stand-in engine for screenshots and tests: a made-up meeting, live levels
and an interim line, with the real engine's /events, /listen and /meeting/new."""
import asyncio
import json
import math
import sys
import time
from pathlib import Path

from aiohttp import web

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "engine"))
import insights  # noqa: E402  (the real counting, over a made-up month)

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
    "mine": [{"text": "Chase the stuck Lumen port with the carrier", "due": "this afternoon", "at": 1, "flagged": True},
             {"text": "Send the beta testers the softphone build notes", "due": "Thursday", "at": 2, "done": True}],
    "theirs": [{"who": "Dana", "text": "Escalate the second stuck port with the losing carrier", "due": "tomorrow", "at": 0}],
    "decisions": [{"text": "The softphone build goes to beta on Thursday", "due": "", "at": 2}],
    "questions": [{"text": "Do the stuck ports need a new LOA?", "due": "", "at": 0}],
    "met_with": ["Internal"], "tags": ["Operations", "VoIP"], "format": "Video"}
wrapups = {
    "past-0": {"state": "ready", "error": None, "draft": WRAPUP, "edited": None, "drafted": NOW - 3 * 3600 + 40 * 60,
               "email": {"state": "ready", "to": ["dana@harbor.example", "ops@harbor.example"], "subject": "Ports and the softphone beta",
                         "body": "Hey all -\n\nThanks for the time today! Quick recap:\n- Six ports left, two stuck with the losing carrier\n- Softphone build goes to beta Thursday\n\nNext steps:\n- Me: chase the Lumen port this afternoon\n- Dana: escalate the second stuck port tomorrow\n\nOpen question: do the stuck ports need a new LOA?\n\nChris"}},
    "past-1": {"state": "ready", "error": None, "draft": {**WRAPUP, "title": "Harbor Logistics Porting Review"}, "edited": None,
               "drafted": NOW - 25 * 3600},
    "past-2": {"state": "drafting", "error": None, "draft": None, "edited": None, "started": NOW - 42},
}
notion = {"past-1": {"id": "abc", "url": "https://www.notion.so/abc", "state": "sent", "sent": NOW - 24 * 3600}}
skipped = set()
PEOPLE = {current_id: ["Amy Reed", "Sam Ortiz"], "past-0": ["Dana Park"], "past-1": ["Luis Ortega", "Kim Hale", "Dana Park"]}


def meta(mid, title, started, ended, st, lines, event=None):
    w = wrapups.get(mid)
    return {"id": mid, "title": title, "started": started, "ended": ended, "state": st, "event": event,
            "people": PEOPLE.get(mid, []), "voices": {"1": {"name": (PEOPLE.get(mid) or ["Them"])[0].split()[0], "by": "guess"}}, "notion": notion.get(mid), "lines": lines, "skipped": mid in skipped,
            "wrapup": w["state"] if w else None, "edited": bool(w and w.get("edited"))}


def segs(lines, t0, gap=40):
    # The other side told apart: two voices, the first one named.
    return [{"id": i, "speaker": who, "start": t0 + i * gap, "end": t0 + i * gap + 6, "text": text,
             **({"voice": 1 if i % 4 else 2} if who == "Them" else {})}
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
    # Turns talking: the other side for a few seconds, then Chris, with the
    # rise and fall of speech, so the meters and the trace have something to show.
    t = time.time()
    them_turn = int(t / 4) % 3 != 2
    wave = abs(math.sin(t * 7)) * (0.6 + 0.4 * abs(math.sin(t * 1.3)))
    them = 0.035 * wave if them_turn else 0.001
    me = 0.002 if them_turn else 0.03 * wave
    return [{"label": "Mic", "speaker": "Chris", "level": me, "alive": True, "speaking": not them_turn},
            {"label": "Laptop", "speaker": "Them", "level": them, "alive": True, "speaking": them_turn},
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
                        "done": bool(item.get("done")), "flagged": bool(item.get("flagged")),
                        "inNotion": mid in notion, "syncError": None})
    return sorted(out, key=lambda f: (-f["started"], f["index"]))


# A made-up month behind the three meetings in the list, so Home's map and
# digest have something to say. Each line: title, its topics, the gist, a
# decision, a question, and who was invited.
HISTORY = [
    ("Harbor Logistics, porting review", ["Porting", "Carriers", "Harbor Logistics"],
     "Four numbers left to port, all on the old carrier. Dana escalates the second stuck one.",
     "Port the last four numbers in one batch", "Does the losing carrier need a fresh LOA?", ["Luis Ortega", "Dana Park"]),
    ("Northwind Dental, kickoff", ["Onboarding", "Northwind Dental", "E911"],
     "Northwind moves offices on the fourteenth; the main number and E911 address change that night.",
     "Cut the main number over the night of the 13th", "Who updates the E911 address?", ["Amy Reed", "Sam Ortiz"]),
    ("Spam-likely labels on outbound", ["Number Reputation", "Caller ID", "Carriers"],
     "Three customers report outbound calls labeled spam likely. Registration is missing on the newer numbers.",
     "Register every new outbound number before it's used", "Which analytics vendor flags us most?", ["Dana Park", "Kim Hale"]),
    ("Softphone beta check-in", ["Softphone", "Support"],
     "The beta build is stable on desktop; mobile still drops audio on a network change.",
     "Hold the mobile release a week", "Is the audio drop ours or the carrier's?", ["Kim Hale", "Raj Patel"]),
    ("Weekly operations", ["Porting", "Support", "Softphone"],
     "Porting queue down to six, tickets steady, softphone beta on track for Thursday.",
     "The softphone build goes to beta on Thursday", "Do the stuck ports need a new LOA?", ["Dana Park"]),
    ("Pricing review", ["Pricing", "Sales", "Billing"],
     "Seat pricing holds; conference phones move to a monthly rental with a two-year term.",
     "Offer conference phones as a rental", "What's the buyout at month twelve?", ["Luis Ortega", "Mia Chen"]),
    ("Caller ID registration with the carrier", ["Number Reputation", "Carriers", "Caller ID", "Compliance"],
     "The carrier will bulk-register our outbound numbers if we send them weekly.",
     "Send the carrier a weekly file of new numbers", "Does registration carry over on a port?", ["Raj Patel"]),
    ("Texting campaign rules", ["Texting", "Compliance"],
     "New campaigns need a registered brand first; two customers are sending without one.",
     "Pause sending for unregistered brands", "How long does brand vetting take now?", ["Mia Chen", "Kim Hale"]),
    ("Harbor Logistics, invoice questions", ["Billing", "Harbor Logistics"],
     "Their October invoice doubled the port fees. A credit goes out with November's.",
     "Credit the duplicate port fees", "Why did the fee post twice?", ["Luis Ortega"]),
    ("Sales pipeline", ["Sales", "Pricing", "Onboarding"],
     "Two dental groups close this month. Both want the cutover done on a weekend.",
     "Weekend cutovers for both dental groups", "Do we have weekend coverage on the 21st?", ["Mia Chen", "Sam Ortiz"]),
]
EARLIER = []  # (meta, notes), as insights reads them
for i in range(26):
    title, tags, tldr, decided, asked, people = HISTORY[(i * 3) % len(HISTORY)]
    back = 1 + i + i // 5 * 2  # days ago, with the weekends left out
    start = NOW - back * 86400 - (i % 4) * 5400
    EARLIER.append((
        {"id": f"earlier-{i}", "title": title, "started": start, "ended": start + (18 + i % 5 * 9) * 60,
         "state": "ended", "people": people, "notion": {"state": "sent"}, "skipped": False},
        {"tldr": tldr, "tags": tags, "topics": [{"title": t + ", where it stands", "points": []} for t in tags[:2]],
         "mine": [{"text": "Follow up", "done": i % 3 == 0}],
         "decisions": [{"text": decided, "at": 1}], "questions": [{"text": asked, "at": 0}]}))


def library():
    """The listed meetings and the made-up month, as insights reads them."""
    listed = []
    for m in meetings():
        w = wrapups.get(m["id"])
        listed.append((m, (w.get("edited") or w.get("draft")) if w else None))
    return listed + EARLIER


def learned(days):
    return insights.learned(library(), time.time(), days)


async def get_topic(request):
    found = insights.topic(library(), request.query.get("name", ""), time.time())
    if not found:
        raise web.HTTPNotFound()
    return web.json_response({"topic": found})


async def get_learned(request):
    return web.json_response({"learned": learned(int(request.query.get("days", 30)))})


bulk = {"running": False}


async def send_all(request):
    """Send all, as the real engine reports it: one at a time, each said as it goes."""
    ids = [i for i in (await request.json()).get("ids", []) if i in wrapups and i not in notion]
    if ids and not bulk.get("running"):
        asyncio.create_task(_send_all(ids))
    return web.json_response({"taken": len(ids)})


async def _send_all(ids):
    def say(**changes):
        bulk.update(changes)
        for q in clients:
            q.put_nowait({"type": "bulk", "bulk": dict(bulk)})
    say(running=True, total=len(ids), done=0, failed=0, choose=[], ids=ids, current=None, sent=[], failures=[], finished=None)
    for i in ids:
        say(current=i)
        await asyncio.sleep(1.2)
        notion[i] = {"id": "n-" + i, "url": "https://www.notion.so/" + i, "state": "sent", "sent": time.time()}
        announce()
        say(done=bulk["done"] + 1, sent=bulk["sent"] + [i])
    say(running=False, current=None, finished=time.time())


def state_event():
    return {"type": "state", "listening": state["listening"], "current": current_id, "channels": [],
            "call": state["call"], "settings": state["settings"],
            "followups_open": sum(1 for f in followups() if not f["done"]), "bulk": dict(bulk)}


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


async def search(request):
    words = request.query.get("q", "").lower().split()
    out = []
    for m in meetings():
        lines = segs(LINES, NOW - 600) if m["id"] == current_id else segs(PAST[int(m["id"].split("-")[1])][3], m["started"])
        hits = [x for x in lines if all(w in x["text"].lower() for w in words)]
        title = all(w in m["title"].lower() for w in words)
        if words and (hits or title):
            out.append({"id": m["id"], "title": title, "count": len(hits),
                        "hits": [{"at": x["id"], "speaker": x["speaker"], "text": x["text"],
                                  "time": time.strftime("%H:%M:%S", time.localtime(x["start"]))} for x in hits[:3]]})
    return web.json_response({"results": out})


async def listen(request):
    body = await request.json()
    state["listening"] = bool(body.get("on"))
    for q in clients:
        q.put_nowait({"type": "meeting", "meeting": meetings()[0]})
        q.put_nowait(state_event())
    return web.json_response(state)


async def ok(request):
    return web.json_response({})


noted = [0]


async def note(request):
    """A note lands as a line, the way the real engine's does."""
    body = await request.json()
    noted[0] += 1
    t = time.time()
    seg = {"id": len(LINES) + noted[0], "speaker": "Note", "start": t, "end": t, "text": body.get("text", "")}
    for q in clients:
        q.put_nowait({"type": "segment", "meeting": request.match_info["id"], **seg, "time": time.strftime("%H:%M:%S")})
    return web.json_response(seg)


TAKEAWAYS = {"updated": NOW - 50, "lines": 9,
             "asked": [{"text": "Does the auto attendant need holiday hours?", "at": 10}],
             "mine": [{"text": "Send pricing for two conference phones today", "at": 9},
                      {"text": "Check caller ID registration on outbound numbers", "at": 5}],
             "decisions": [{"text": "Number change the night of the 13th", "at": 4}],
             "questions": [],
             "lookups": [{"kind": "customer", "query": "Northwind Dental", "why": "which carrier has the main number", "at": 2},
                         {"kind": "number", "query": "716 555 0142", "why": "is the port scheduled", "at": 3},
                         {"kind": "ticket", "query": "INC-20417", "why": "spam likely complaint, still open?", "at": 5}]}


async def get_wrapup(request):
    mid = request.match_info["id"]
    brief = {"related": [{"id": "past-1", "title": "Harbor Logistics, porting review", "started": NOW - 26 * 3600,
                          "tldr": "Four numbers left to port, all on the old carrier; Dana escalates the second stuck one.",
                          "series": False, "shared": ["Dana Park"]}],
             "mine": [{"meeting": "past-1", "index": 0, "text": "Chase the stuck Lumen port with the carrier", "due": "this afternoon"}],
             "theirs": [{"meeting": "past-1", "who": "Dana", "text": "Escalate the second stuck port", "due": "tomorrow"}]} if mid == current_id else {}
    return web.json_response({"wrapup": wrapups.get(mid), "takeaways": TAKEAWAYS if mid == current_id else None, "brief": brief})


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
app.router.add_post("/meeting/{id}/merge", ok)
app.router.add_post("/meeting/{id}/finish", ok)
app.router.add_post("/meeting/{id}/note", note)
app.router.add_delete("/meeting/{id}", ok)
app.router.add_patch("/settings", ok)
app.router.add_post("/_call", set_call)
app.router.add_get("/followups", get_followups)
app.router.add_get("/learned", get_learned)
app.router.add_get("/topic", get_topic)
app.router.add_get("/search", search)
app.router.add_post("/followups/sync", sync_followups)
app.router.add_post("/followups/done", ok)
app.router.add_post("/followups/flag", ok)
app.router.add_post("/notion/bulk", send_all)
app.router.add_post("/followups/remove", get_followups)
app.router.add_post("/meeting/{id}/email", ok)
app.router.add_put("/meeting/{id}/email", ok)
app.router.add_post("/meeting/{id}/email/save", ok)
web.run_app(app, host="127.0.0.1", port=PORT, print=None)
