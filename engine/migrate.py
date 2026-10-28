#!/usr/bin/env python3
"""One-off: turns the prototype's flat meetings/*.jsonl files into meeting
folders. A file that ran through several calendar meetings (the prototype
listened all day) is split at the midpoints between them, using the
meetings the calendar helper knows about for that day. Originals are kept as
*.jsonl.migrated.

    migrate.py [--calendar events.json] [--dry-run]
"""
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

MEETINGS = Path.home() / ".local/share/aloi-sidecar/meetings"
HELPER = Path(__file__).resolve().parent.parent / "plugin/bin/aloi-meetings"


def calendar(day, override):
    if override:
        return json.loads(Path(override).read_text())["events"]
    if not HELPER.exists():
        return []
    out = subprocess.run([str(HELPER), "day", day] if day != datetime.now().strftime("%Y-%m-%d") else [str(HELPER), "today"],
                         capture_output=True, text=True, timeout=30)
    try:
        return json.loads(out.stdout)["events"]
    except (json.JSONDecodeError, KeyError):
        return []


def ts(iso):
    return datetime.fromisoformat(iso).timestamp()


def split(segments, events):
    """[(title, event, segments)]: one piece per calendar meeting the talk ran through."""
    first, last = segments[0]["start"], segments[-1]["end"]
    talks = [e for e in events if not e.get("cancelled") and not e.get("allDay")
             and ts(e["start"]) < last and ts(e["end"]) > first - 15 * 60]
    talks.sort(key=lambda e: ts(e["start"]))
    # Overlapping invitations: keep the first of any that start within 10 minutes of another.
    kept = []
    for e in talks:
        if not kept or ts(e["start"]) - ts(kept[-1]["start"]) > 10 * 60:
            kept.append(e)
    if len(kept) < 2:
        title = kept[0]["subject"] if kept else None
        return [(title, kept[0] if kept else None, segments)]
    cuts = [(ts(a["end"]) + ts(b["start"])) / 2 for a, b in zip(kept, kept[1:])]
    pieces = [[] for _ in kept]
    for s in segments:
        i = sum(1 for c in cuts if s["start"] >= c)
        pieces[i].append(s)
    return [(e["subject"], e, p) for e, p in zip(kept, pieces) if p]


def event_meta(e):
    if not e:
        return None
    return {k: e.get(k) for k in ("id", "subject", "start", "end", "joinUrl", "organizer", "webLink")}


def main():
    dry = "--dry-run" in sys.argv
    override = sys.argv[sys.argv.index("--calendar") + 1] if "--calendar" in sys.argv else None
    for path in sorted(MEETINGS.glob("*.jsonl")):
        with path.open() as f:
            segments = [json.loads(line) for line in f if line.strip()]
        if not segments:
            print(f"{path.name}: empty, removed" + (" (dry run)" if dry else ""))
            if not dry:
                path.unlink()
            continue
        day = datetime.fromtimestamp(segments[0]["start"]).strftime("%Y-%m-%d")
        pieces = split(segments, calendar(day, override))
        for title, event, segs in pieces:
            start = segs[0]["start"]
            mid = datetime.fromtimestamp(start).strftime("%Y-%m-%d_%H%M%S")
            title = title or "Call at " + datetime.fromtimestamp(start).strftime("%-H:%M")
            print(f"{path.name} -> {mid}  {len(segs):5d} lines  {title}")
            if dry:
                continue
            folder = MEETINGS / mid
            folder.mkdir(exist_ok=False)
            with (folder / "transcript.jsonl").open("w") as f:
                for i, s in enumerate(segs):
                    f.write(json.dumps({**s, "id": i}) + "\n")
            meta = {"id": mid, "title": title, "started": start, "ended": segs[-1]["end"], "state": "ended",
                    "event": event_meta(event), "people": [], "notion": None}
            (folder / "meta.json").write_text(json.dumps(meta, indent=1))
        if not dry:
            path.rename(path.with_suffix(".jsonl.migrated"))


if __name__ == "__main__":
    main()
