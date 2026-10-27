#!/usr/bin/env python3
"""What a call does on its own: the mic going hot starts a meeting named from
the call app's window and the calendar, Not now throws it away, and the call
ending ends the meeting unless Not now keeps it. Nothing is recorded: the
recorders and notifications are stand-ins.

    engine/.venv/bin/python tests/engine_calls.py
"""
import asyncio
import os
import time
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

    # The other side still talking after the mic lets go (a mute, a headset
    # switch): the call isn't over, so it keeps going.
    answers[:] = [None]
    await app.call_started("Teams")
    await app.prompt
    m4 = app.current
    answers[:] = [None]
    await app.call_ended("Teams")
    await asyncio.sleep(0.05)
    m4.append({"speaker": "Them", "start": time.time(), "end": time.time() + 1, "text": "Sorry, I was on mute."})
    await asyncio.sleep(0.3)
    check("someone still talking keeps it going", app.current is m4 and app.listening)
    await app.prompt
    check("and it ends once they've gone quiet", app.current is None)

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
    before = set(app.meetings)
    answers[:] = ["discard"]
    await app.call_started("Teams")
    await app.prompt
    check("Not now on a new call stops it", app.current is None and not app.listening)
    check("and keeps nothing of it", set(app.meetings) == before)

    # The engine restarted mid-call: the call carries on in the same meeting.
    answers[:] = [None]
    await app.call_started("Teams")
    await app.prompt
    m5 = app.current
    app.listening = False
    m5.meta["state"] = "paused"
    m5.meta["recovered"] = True
    app.call = None
    answers[:] = [None]
    await app.call_started("Teams")
    await app.prompt
    check("after a restart mid-call, the same meeting carries on", app.current is m5 and app.listening)
    await app.end_meeting()

    # Two meetings that were one call merge into the earlier one.
    import engine as E
    first = E.Meeting.create("Dialer review")
    first.meta.update(state="ended", started=100, ended=200, people=["Ali"])
    first._segments = []
    for t, text in ((110, "First half."), (190, "Still first.")):
        first.append({"speaker": "Them", "start": t, "end": t + 1, "text": text})
    first.close(); first.save()
    first.save_wrapup({"state": "ready", "draft": {"mine": [{"text": "x", "at": 1}]}, "edited": None})
    second = E.Meeting.create("(3) Chat")
    second.meta.update(state="ended", started=300, ended=400, people=["Greg"])
    second._segments = []
    second.append({"speaker": "Them", "start": 150, "end": 151, "text": "In between."})
    second.append({"speaker": "Them", "start": 310, "end": 311, "text": "Second half."})
    second.close(); second.save()
    app.meetings[first.id], app.meetings[second.id] = first, second
    kept = app.merge_meetings(second, first)
    check("merging keeps the earlier meeting and its title", kept is first and kept.meta["title"] == "Dialer review")
    check("the lines interleave in time", [s["text"] for s in kept.segments] == ["First half.", "In between.", "Still first.", "Second half."])
    check("the other meeting goes to the trash", second.id not in app.meetings and not second.folder.exists())
    check("people from both, end from the later", kept.meta["people"] == ["Ali", "Greg"] and kept.meta["ended"] == 400)
    check("wrap-up line numbers follow their lines", kept.wrapup()["draft"]["mine"][0]["at"] == 2)
    check("a merged transcript survives a reload", [s["text"] for s in E.Meeting.load(kept.folder).segments][-1] == "Second half.")

    # Joined muted: only the call app's sound. It counts when the engine
    # agrees it's a call, and the call ends when the sound does.
    calls.HOLD, calls.RELEASE = 0.05, 0.1
    mic, sound, asked, events = {}, {}, [], []

    class Watch(calls.CallWatch):
        async def users(self): return dict(mic)
        async def players(self): return dict(sound)

    async def start(app): events.append(("start", app))
    async def end(app): events.append(("end", app))
    verdict = [False]
    async def is_call(app):
        asked.append(app)
        return verdict[0]
    calls.window_name = lambda: asyncio.sleep(0, result=None)
    w = Watch(lambda: [], start, end, is_call)
    sound[1] = "Chromium"
    await w.check(); await asyncio.sleep(0.08); await w.check()
    check("sound alone that isn't a call starts nothing", events == [] and asked == ["Chromium"])
    await asyncio.sleep(0.08); await w.check()
    check("and it isn't asked about again", asked == ["Chromium"])
    sound.clear(); await w.check()
    verdict[0] = True
    sound[2] = "Chromium"
    await w.check(); await asyncio.sleep(0.08); await w.check()
    check("a call app's sound the engine calls a call starts one", events == [("start", "Chromium")] and w.by_sound)
    sound.clear(); await w.check(); await asyncio.sleep(0.15); await w.check()
    check("and it ends when the sound does", events[-1] == ("end", "Chromium"))

    # Takeaways bring lookups: concrete things to check, gathered over the call.
    import takeaways
    import wrapup as W
    W.WORKSPACE.mkdir(parents=True, exist_ok=True)
    t = await takeaways.update("Chris", {"title": "Cutover"}, [{"id": 0, "speaker": "Them", "start": 1, "end": 2, "text": "Northwind's main number"}],
                               program=str(ROOT / "tests/fake/claude-wrapup"))
    check("takeaways bring lookups, blank ones dropped", [x["query"] for x in t["lookups"]] == ["Northwind Dental", "716 555 0100"])
    merged = takeaways.merge_lookups(t["lookups"], [{"kind": "customer", "query": "northwind  dental", "why": "again", "at": 5},
                                                    {"kind": "ticket", "query": "INC-42", "why": "open?", "at": 6}])
    check("lookups gather without repeats", [x["query"] for x in merged] == ["Northwind Dental", "716 555 0100", "INC-42"])

    # Going in: what's on file from earlier meetings with the same people.
    nxt = E.Meeting.create("Dialer follow-up")
    nxt.meta.update(state="ended", started=1000, ended=1100, people=["Greg", "Someone new"])
    app.meetings[nxt.id] = nxt
    b = app.brief(nxt)
    check("the brief finds the earlier meeting with the same people", [r["title"] for r in b["related"]] == ["Dialer review"] and b["related"][0]["shared"] == ["Greg"])
    check("and what's still owed from it", [i["text"] for i in b["mine"]] == ["x"])
    alone = E.Meeting.create("Unrelated")
    alone.meta.update(state="ended", started=1000, ended=1100, people=["Nobody"])
    check("a meeting with new people has no brief", app.brief(alone)["related"] == [])

    # A restart part way through a draft picks it back up.
    half = E.Meeting.create("Half drafted")
    half.meta.update(state="ended", ended=500)
    half._segments = []
    half.append({"speaker": "Them", "start": 1, "end": 2, "text": "Hello."})
    half.close(); half.save()
    half.save_wrapup({"state": "drafting", "draft": None, "edited": None})
    again = E.Sidecar()
    check("an interrupted draft is lined up to draft again", [x.meta["title"] for x in again.interrupted] == ["Half drafted"])

    # Voices: lines alike enough are one voice; names by hand beat guesses.
    import numpy as np
    import voices as V
    vm = E.Meeting.create("Voices")
    vm.meta.update(state="ended", started=2000, ended=2100)
    vs = V.Voices(vm.folder)
    a, b = np.zeros(192, np.float32), np.zeros(192, np.float32)
    a[0], b[1] = 1, 1
    near_a = a.copy(); near_a[2] = 0.3; near_a /= np.linalg.norm(near_a)
    check("a new voiceprint is voice 1", vs.assign(a)[0] == 1)
    check("one like it is the same voice", vs.assign(near_a)[0] == 1)
    check("one unlike it is voice 2", vs.assign(b)[0] == 2)
    check("voices outlast a restart", len(V.Voices(vm.folder).centroids) == 2)
    vm._segments = []
    vm.append({"speaker": "Them", "start": 1, "end": 2, "text": "Hi, it's Hector.", "voice": 1})
    vm.append({"speaker": "Them", "start": 3, "end": 4, "text": "And I'm here too.", "voice": 2})
    vm.append({"speaker": "Them", "start": 5, "end": 6, "text": "Okay.", })
    vm.close(); vm.save()
    app.meetings[vm.id] = vm
    app.guess_names(vm, [{"voice": 1, "name": "Hector"}])
    app.update_meeting(vm, {"voices": {"2": "Courtney"}})
    app.guess_names(vm, [{"voice": 2, "name": "Someone else"}])
    check("a guessed name and a hand-given one, and the hand wins", [s["speaker"] for s in app.labelled(vm)] == ["Hector", "Courtney", "Them"])
    check("the lines themselves still say Them", all(s["speaker"] == "Them" for s in vm.segments))
    vm2 = E.Meeting.create("Voices, part two")
    vm2.meta.update(state="ended", started=2200, ended=2300, voices={"1": {"name": "Greg", "by": "hand"}})
    vm2._segments = []
    vm2.append({"speaker": "Them", "start": 2210, "end": 2211, "text": "Greg here.", "voice": 1})
    vm2.close(); vm2.save()
    app.meetings[vm2.id] = vm2
    joined = app.merge_meetings(vm, vm2)
    check("merging numbers the other meeting's voices after this one's", [s.get("voice") for s in joined.segments] == [1, 2, None, 3]
          and joined.meta["voices"]["3"]["name"] == "Greg")
    check("voices are off unless turned on", not app.voices_on())

    # Search finds what was said, in any meeting.
    found = app.search("thanks BYE")
    check("search finds a line by its words, any case", len(found) == 1 and found[0]["hits"][0]["text"] == "Thanks, bye.")
    check("search finds a meeting by its title", any(r["title"] for r in app.search("weekly")))
    check("search with nothing finds nothing", app.search("  ") == [])

    # Turned off in settings: nothing starts.
    app.set_settings({"watch_calls": False})
    await app.call_ended("Teams")
    await app.call_started("Teams")
    check("with the setting off, a hot mic starts nothing", app.current is None)

    print(f"\n{'All passed' if not failures else str(len(failures)) + ' failed'}  ({TMP})")
    sys.exit(1 if failures else 0)


asyncio.run(main())
