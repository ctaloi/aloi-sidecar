"""What the meetings have come to, taken together: Home's "learned" half.

No model call: it's only what the wrap-ups already say, counted and joined.
The topics are the wrap-ups' tags (Notion's own list, so the same word means
the same thing every time); two topics are linked when meetings carry both.
Each topic keeps what was said under it lately: the gist of its meetings,
what was decided and what's still open.
"""
import collections
from datetime import datetime, timedelta

TOPICS = 22  # as many as the map can show without turning into a hairball
MAX_DAYS = 126  # the activity strip never goes back further than 18 weeks


def minutes(meta):
    return max(0, ((meta.get("ended") or meta["started"]) - meta["started"]) / 60)


def day(t):
    return datetime.fromtimestamp(t).strftime("%Y-%m-%d")


def learned(meetings, now, days=30, topics=TOPICS):
    """meetings: (meta, notes) pairs, notes the wrap-up as it stands or None.
    days: how far back to look, 0 for everything."""
    since = now - days * 86400 if days else 0
    kept = sorted(((m, n) for m, n in meetings
                   if m.get("state") == "ended" and not m.get("skipped") and m["started"] >= since),
                  key=lambda p: p[0]["started"], reverse=True)
    wrapped = [(m, n) for m, n in kept if n]

    def ref(m, item):
        return {"text": item["text"], "meeting": m["id"], "title": m["title"], "started": m["started"],
                "at": item.get("at", -1)}

    def gist(m, n):
        return {"id": m["id"], "title": m["title"], "started": m["started"], "minutes": round(minutes(m)),
                "tldr": n.get("tldr", ""), "tags": n.get("tags", []),
                "sent": (m.get("notion") or {}).get("state") == "sent"}

    # Topics: every tag, with what its meetings came to, newest first.
    by_tag = collections.defaultdict(list)
    for m, n in wrapped:
        for tag in dict.fromkeys(n.get("tags", [])):
            by_tag[tag].append((m, n))
    ranked = sorted(by_tag, key=lambda t: (-len(by_tag[t]), -by_tag[t][0][0]["started"], t))[:topics]
    week = now - 7 * 86400
    out_topics = []
    for tag in ranked:
        held = by_tag[tag]
        out_topics.append({
            "name": tag, "count": len(held), "minutes": round(sum(minutes(m) for m, _ in held)),
            "last": held[0][0]["started"], "first": held[-1][0]["started"],
            "recent": sum(1 for m, _ in held if m["started"] >= week),
            "meetings": [gist(m, n) for m, n in held[:5]],
            "threads": list(dict.fromkeys(t["title"] for _, n in held for t in n.get("topics", []) if t.get("title")))[:6],
            "decisions": [ref(m, i) for m, n in held for i in n.get("decisions", []) if i.get("text")][:4],
            "questions": [ref(m, i) for m, n in held for i in n.get("questions", []) if i.get("text")][:4],
        })

    # Links: how many meetings carry both. A topic keeps its three strongest,
    # and a single shared meeting only counts when nothing is stronger.
    names = set(ranked)
    pairs = collections.Counter()
    for _, n in wrapped:
        tags = sorted(t for t in dict.fromkeys(n.get("tags", [])) if t in names)
        pairs.update((a, b) for i, a in enumerate(tags) for b in tags[i + 1:])
    floor = 2 if any(c >= 2 for c in pairs.values()) else 1
    strongest = collections.defaultdict(list)
    for (a, b), c in sorted(pairs.items(), key=lambda p: (-p[1], p[0])):
        if c >= floor:
            strongest[a].append((a, b))
            strongest[b].append((a, b))
    keep = {p for tag in strongest for p in strongest[tag][:3]}
    links = [{"a": a, "b": b, "n": pairs[(a, b)]} for a, b in sorted(keep, key=lambda p: (-pairs[p], p))]

    # The days, oldest first, with nothing left out: the strip's bars.
    counts, lengths = collections.Counter(), collections.Counter()
    for m, _ in kept:
        counts[day(m["started"])] += 1
        lengths[day(m["started"])] += minutes(m)
    span = days or (int((now - kept[-1][0]["started"]) // 86400) + 1 if kept else 1)
    today = datetime.fromtimestamp(now).replace(hour=12, minute=0, second=0, microsecond=0)
    daily = []
    for back in range(min(span, MAX_DAYS) - 1, -1, -1):
        d = today - timedelta(days=back)
        key = d.strftime("%Y-%m-%d")
        daily.append({"day": key, "t": d.timestamp(), "weekday": d.weekday(),
                      "meetings": counts[key], "minutes": round(lengths[key])})

    people = collections.Counter()
    latest = {}
    for m, _ in kept:
        for p in dict.fromkeys(m.get("people") or []):
            people[p] += 1
            latest.setdefault(p, m["started"])
    mine = [i for _, n in wrapped for i in n.get("mine", []) if (i.get("text") or "").strip()]
    return {
        "days": days,
        "totals": {
            "meetings": len(kept), "wrapped": len(wrapped), "minutes": round(sum(minutes(m) for m, _ in kept)),
            "topics": len(by_tag), "people": len(people),
            "decisions": sum(len(n.get("decisions", [])) for _, n in wrapped),
            "questions": sum(len(n.get("questions", [])) for _, n in wrapped),
            "followups": len(mine), "done": sum(1 for i in mine if i.get("done")),
        },
        "daily": daily,
        "topics": out_topics,
        "links": links,
        "people": [{"name": p, "count": c, "last": latest[p]} for p, c in
                   sorted(people.items(), key=lambda x: (-x[1], x[0]))[:8]],
        "recent": [gist(m, n) for m, n in wrapped[:6]],
        "decisions": [ref(m, i) for m, n in wrapped for i in n.get("decisions", []) if i.get("text")][:6],
        "questions": [ref(m, i) for m, n in wrapped for i in n.get("questions", []) if i.get("text")][:6],
    }


def topic(meetings, name, now):
    """Everything on file under one topic, all the way back: its meetings
    (newest first) with what each came to, what was decided and left open,
    what was promised either way, the topics it comes up with, and who was
    there. None if no wrap-up carries it."""
    held = sorted(((m, n) for m, n in meetings
                   if n and m.get("state") == "ended" and not m.get("skipped") and name in n.get("tags", [])),
                  key=lambda p: p[0]["started"], reverse=True)
    if not held:
        return None

    def ref(m, item, **more):
        return {"text": item["text"], "meeting": m["id"], "title": m["title"], "started": m["started"],
                "at": item.get("at", -1), "due": item.get("due", ""), **more}

    def said(key):
        return [ref(m, i) for m, n in held for i in n.get(key, []) if (i.get("text") or "").strip()]

    related, people = collections.Counter(), collections.Counter()
    for m, n in held:
        related.update(t for t in dict.fromkeys(n.get("tags", [])) if t != name)
        people.update(list(dict.fromkeys(m.get("people") or [])))
    return {
        "name": name, "count": len(held), "minutes": round(sum(minutes(m) for m, _ in held)),
        "first": held[-1][0]["started"], "last": held[0][0]["started"],
        "recent": sum(1 for m, _ in held if m["started"] >= now - 7 * 86400),
        "related": [{"name": t, "n": c} for t, c in sorted(related.items(), key=lambda x: (-x[1], x[0]))[:12]],
        "people": [{"name": p, "count": c} for p, c in sorted(people.items(), key=lambda x: (-x[1], x[0]))[:8]],
        "meetings": [{"id": m["id"], "title": m["title"], "started": m["started"], "minutes": round(minutes(m)),
                      "tldr": n.get("tldr", ""), "tags": [t for t in n.get("tags", []) if t != name],
                      "threads": [t["title"] for t in n.get("topics", []) if t.get("title")],
                      "sent": (m.get("notion") or {}).get("state") == "sent"} for m, n in held],
        "decisions": said("decisions"), "questions": said("questions"),
        "mine": [ref(m, i, index=k, done=bool(i.get("done"))) for m, n in held
                 for k, i in enumerate(n.get("mine", [])) if (i.get("text") or "").strip()],
        "theirs": [ref(m, i, who=i.get("who", "")) for m, n in held for i in n.get("theirs", [])
                   if (i.get("text") or "").strip()],
    }
