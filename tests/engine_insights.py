#!/usr/bin/env python3
"""What Home's "learned" half is counted from: topics and how they're joined,
the days, and what was decided and left open, over made-up wrap-ups.

    engine/.venv/bin/python tests/engine_insights.py
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import insights  # noqa: E402

failures = []
NOW = 1_800_000_000.0
DAY = 86400


def check(name, ok, got=None):
    print(("PASS " if ok else "FAIL ") + name + ("" if ok or got is None else f": {got!r}"))
    if not ok:
        failures.append(name)


def meeting(mid, back, tags=None, minutes=30, people=(), **more):
    meta = {"id": mid, "title": mid.title(), "started": NOW - back * DAY, "ended": NOW - back * DAY + minutes * 60,
            "state": "ended", "people": list(people), "notion": None, "skipped": False, **more}
    notes = None if tags is None else {
        "tldr": f"What {mid} came to.", "tags": tags, "topics": [{"title": f"{mid} thread", "points": []}],
        "mine": [{"text": "Do it", "done": mid == "a"}, {"text": "  "}],
        "decisions": [{"text": f"{mid} decided", "at": 3}], "questions": [{"text": f"{mid} asked", "at": 5}]}
    return meta, notes


LIBRARY = [
    meeting("a", 1, ["Porting", "Carriers"], people=["Dana", "Luis"]),
    meeting("b", 2, ["Porting", "Carriers", "Billing"], people=["Dana"]),
    meeting("c", 3, ["Porting", "Billing"]),
    meeting("d", 10, ["Texting"], minutes=90),
    meeting("e", 4),                                   # no wrap-up yet
    meeting("f", 5, ["Porting"], skipped=True),        # set aside: a test call
    meeting("g", 40, ["Old"]),                         # before the 30 days
    ({**meeting("h", 0, ["Porting"])[0], "state": "live", "ended": None}, None),
]

r = insights.learned(LIBRARY, NOW, 30)
t = r["totals"]
check("counts the meetings in range, not skipped or live", t["meetings"] == 5, t)
check("counts the wrap-ups among them", t["wrapped"] == 4, t)
check("adds up the time", t["minutes"] == 30 * 4 + 90, t)
check("follow-ups done, blank ones left out", (t["done"], t["followups"]) == (1, 4), t)
check("decisions and questions", (t["decisions"], t["questions"]) == (4, 4), t)

names = [x["name"] for x in r["topics"]]
check("topics most-discussed first", names == ["Porting", "Carriers", "Billing", "Texting"], names)
porting = r["topics"][0]
check("a topic's count and its meetings, newest first",
      porting["count"] == 3 and [m["id"] for m in porting["meetings"]] == ["a", "b", "c"], porting)
check("a topic's week", porting["recent"] == 3 and r["topics"][3]["recent"] == 0)
check("a topic carries what was decided, with where", porting["decisions"][0] ==
      {"text": "a decided", "meeting": "a", "title": "A", "started": NOW - DAY, "at": 3}, porting["decisions"][0])
check("and what came up", porting["threads"] == ["a thread", "b thread", "c thread"], porting["threads"])

links = {(link["a"], link["b"]): link["n"] for link in r["links"]}
check("topics that share two meetings are joined", links == {("Carriers", "Porting"): 2, ("Billing", "Porting"): 2}, links)
one = insights.learned(LIBRARY[1:2], NOW, 30)
check("a single shared meeting joins them when nothing is stronger", len(one["links"]) == 3, one["links"])

check("a bar for every day, oldest first", len(r["daily"]) == 30 and r["daily"][-1]["meetings"] == 0
      and r["daily"][-2]["meetings"] == 1 and r["daily"][-11]["minutes"] == 90, r["daily"][-11:])
check("people by how often", r["people"][0]["name"] == "Dana" and r["people"][0]["count"] == 2, r["people"])
check("the latest decisions, newest first", [d["meeting"] for d in r["decisions"]] == ["a", "b", "c", "d"])
check("the last conversations", [m["id"] for m in r["recent"]] == ["a", "b", "c", "d"])

everything = insights.learned(LIBRARY, NOW, 0)
check("all of them reaches back", everything["totals"]["meetings"] == 6 and len(everything["daily"]) == 41, everything["totals"])
check("only so many topics on the map", len(insights.learned(
    [meeting(f"m{i}", 1, [f"T{i}"]) for i in range(40)], NOW, 30)["topics"]) == insights.TOPICS)
empty = insights.learned([], NOW, 30)
check("nothing at all is still a shape", empty["totals"]["meetings"] == 0 and empty["topics"] == [] and len(empty["daily"]) == 30)

# One topic, all the way back.
LIBRARY.append(meeting("i", 60, ["Porting", "Old"], people=["Dana"]))
p = insights.topic(LIBRARY, "Porting", NOW)
check("a topic's page reaches back past the month, newest first",
      [m["id"] for m in p["meetings"]] == ["a", "b", "c", "i"] and p["count"] == 4, [m["id"] for m in p["meetings"]])
check("what it comes up with, by how often", p["related"][:2] == [{"name": "Billing", "n": 2}, {"name": "Carriers", "n": 2}], p["related"])
check("a meeting lists its other topics and what came up", p["meetings"][1]["tags"] == ["Carriers", "Billing"]
      and p["meetings"][1]["threads"] == ["b thread"], p["meetings"][1])
check("every decision under it, with where", [d["meeting"] for d in p["decisions"]] == ["a", "b", "c", "i"])
check("follow-ups keep their place in the wrap-up", p["mine"][0]["index"] == 0 and p["mine"][0]["done"] and not p["mine"][1]["done"], p["mine"])
check("who was there", p["people"][0] == {"name": "Dana", "count": 3}, p["people"])
check("this week's share", p["recent"] == 3)
check("a topic nobody tagged is nothing", insights.topic(LIBRARY, "Nope", NOW) is None)

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
