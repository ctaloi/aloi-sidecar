#!/usr/bin/env python3
"""The engine's wrap-up and Send, end to end, against stand-ins: the real
engine on its own port and its own meetings folder, a fake Claude and a fake
Notion. Nothing touches Chris's meetings or his Notion.

    engine/.venv/bin/python tests/engine_wrapup.py
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = str(ROOT / "engine/.venv/bin/python")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def call(base, method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if r.headers.get_content_type() == "application/json" else raw.decode())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def wait(what, check, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        result = check()
        if result:
            return result
        time.sleep(0.2)
    raise AssertionError(f"timed out waiting for {what}")


def make_meeting(folder, mid, title, lines, started):
    d = folder / mid
    d.mkdir(parents=True)
    (d / "meta.json").write_text(json.dumps({
        "id": mid, "title": title, "started": started, "ended": started + 25 * 60, "state": "ended",
        "event": None, "people": [], "notion": None}))
    with (d / "transcript.jsonl").open("w") as f:
        for i in range(lines):
            who = "Chris" if i % 3 == 0 else "Them"
            f.write(json.dumps({"id": i, "speaker": who, "start": started + i * 2, "end": started + i * 2 + 1.5,
                                "text": f"Line {i}: " + "we talked about the cutover plan and the numbers " * 3}) + "\n")


def main():
    failures = []

    def check(name, ok, detail=""):
        print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  {detail}"))
        if not ok:
            failures.append(name)

    tmp = Path(tempfile.mkdtemp(prefix="sidecar-test-"))
    check_tools_found_from_a_bare_path(tmp, check)
    meetings = tmp / "meetings"
    started = time.time() - 3 * 3600
    make_meeting(meetings, "2026-10-26_100000", "Call at 10:00", 1500, started)
    make_meeting(meetings, "2026-10-26_120000", "Northwind", 12, started + 7200)
    make_meeting(meetings, "2026-10-26_140000", "Harbor", 12, started + 14400)
    make_meeting(meetings, "2026-10-26_160000", "Belmont", 12, started + 21600)
    make_meeting(meetings, "2026-10-26_170000", "Call at 5:00", 3, started + 25200)  # too short to be one

    engine_port, notion_port = free_port(), free_port()
    procs = [subprocess.Popen([PY, str(ROOT / "tests/fake/notion.py"), str(notion_port)])]
    env = {**os.environ, "SIDECAR_PORT": str(engine_port), "SIDECAR_MEETINGS": str(meetings),
           "SIDECAR_NOTION_API": f"http://127.0.0.1:{notion_port}", "SIDECAR_NOTION_TOKEN": "test",
           "SIDECAR_NOTION_FOLLOWUPS": "", "SIDECAR_NOTION_DATABASE": "f011ca00-0000-4000-8000-000000000000",
           "SIDECAR_WRAPUP_CLAUDE": str(ROOT / "tests/fake/claude-wrapup"), "SIDECAR_CALL_WATCH": "0",
           "SIDECAR_CALENDAR": "", "SIDECAR_SETTINGS": str(tmp / "settings.json"),
           "SIDECAR_VMAIL": str(ROOT / "tests/fake/vmail"), "FAKE_VMAIL_OUT": str(tmp / "vmail.txt")}
    procs.append(subprocess.Popen([PY, str(ROOT / "engine/engine.py")], env=env, cwd=ROOT / "engine"))
    base, fake = f"http://127.0.0.1:{engine_port}", f"http://127.0.0.1:{notion_port}"
    try:
        wait("engine", lambda: _up(base), 60)
        mid = "2026-10-26_100000"

        # A few lines and nothing done with them isn't a meeting.
        _, listed = call(base, "GET", "/meetings")
        check("a meeting of a few lines is taken off the list", "2026-10-26_170000" not in [m["id"] for m in listed], listed)
        check("and kept in the trash folder", (tmp / "trash/2026-10-26_170000/transcript.jsonl").exists())
        check("one with enough lines stays", "2026-10-26_120000" in [m["id"] for m in listed])

        # Recovered meetings never draft by themselves.
        status, w = call(base, "GET", f"/meeting/{mid}/wrapup")
        check("no draft for a meeting that was already over", w["wrapup"] is None, w)

        call(base, "POST", f"/meeting/{mid}/wrapup")
        w = wait("draft", lambda: _ready(base, mid))
        draft = w["wrapup"]["draft"]
        check("draft is ready", w["wrapup"]["state"] == "ready", w)
        check("names and tags kept only if the database has them",
              draft["met_with"] == ["Belmont"] and draft["tags"] == ["Migration"], draft)
        check("listing says a wrap-up is ready", w["meeting"]["wrapup"] == "ready")

        # Edits are kept apart and survive a redraft that doesn't replace them.
        edited = {**draft, "title": "Northwind Dental Cutover", "mine": draft["mine"]}
        call(base, "PUT", f"/meeting/{mid}/wrapup", {"edited": edited})
        call(base, "POST", f"/meeting/{mid}/wrapup")
        w = wait("redraft", lambda: _ready(base, mid))
        check("edits survive a redraft", w["wrapup"]["edited"]["title"] == "Northwind Dental Cutover", w["wrapup"])
        check("listing says it was edited", w["meeting"]["edited"] is True)

        status, md = call(base, "GET", f"/meeting/{mid}/markdown")
        check("markdown uses the edits", "# Northwind Dental Cutover" in md and md.count("- [ ]") == 2, md[:300])

        # A send that fails part way resumes on the same page.
        call(fake, "POST", "/_fail", {"after": 1})
        status, _ = call(base, "POST", f"/meeting/{mid}/notion", {})
        check("send starts", status == 200, _)
        m = wait("failure", lambda: _notion(base, mid, "failed"))
        check("a failure is reported", "Bad gateway" in (m["notion"].get("error") or ""), m["notion"])
        call(base, "POST", f"/meeting/{mid}/notion", {})
        m = wait("sent", lambda: _notion(base, mid, "sent"))
        _, log = call(fake, "GET", "/_log")
        creates = [r for r in log["log"] if r["path"] == "/pages" and r["method"] == "POST"]
        check("one page, even after a retry", len(creates) == 1, len(creates))
        page = creates[0]["body"]["properties"]
        check("title from the edits", page["Meeting Title"]["title"][0]["text"]["content"] == "Northwind Dental Cutover")
        check("only existing tags are sent", page["Tags"]["multi_select"] == [{"name": "Migration"}])
        check("people fields left alone", not any(k in page for k in ("Attendees", "Organizer", "Internal Attendees")))
        pid = m["notion"]["id"]
        toggle = m["notion"]["toggle"]
        check("all 1,500 lines went into the toggle", log["blocks"].get(toggle, 0) == m["notion"]["lines"] > 1,
              (log["blocks"].get(toggle), m["notion"]))
        check("sections not repeated after the retry", log["blocks"][pid] == m["notion"]["total"] + 1,
              (log["blocks"][pid], m["notion"]["total"]))
        status, _ = call(base, "POST", f"/meeting/{mid}/notion", {})
        check("a sent meeting can't be sent twice", status == 409)

        # Follow-ups: each knows its to-do on the page; ticking one ticks it in Notion, and back.
        _, w = call(base, "GET", f"/meeting/{mid}/wrapup")
        mine = w["wrapup"]["edited"]["mine"]
        check("follow-ups know their Notion to-do", mine and all(i.get("notion") for i in mine), mine)
        _, fl = call(base, "GET", "/followups")
        ours = [f for f in fl["followups"] if f["meeting"] == mid]
        check("follow-ups are listed, in Notion", len(ours) == len(mine) and all(f["inNotion"] for f in ours), ours)
        call(base, "POST", "/followups/done", {"meeting": mid, "index": 0, "done": True})
        block = mine[0]["notion"]
        def ticked():
            _, b = call(fake, "GET", f"/blocks/{block}")
            return b.get("to_do", {}).get("checked") is True
        wait("tick in Notion", ticked, 10)
        check("ticking in Sidecar ticks the Notion to-do", ticked())
        call(fake, "PATCH", f"/blocks/{block}", {"to_do": {"checked": False}})
        _, synced = call(base, "POST", "/followups/sync", {})
        first = [f for f in synced["followups"] if f["meeting"] == mid and f["index"] == 0][0]
        check("unticking in Notion comes back", synced["changed"] == 1 and first["done"] is False, synced)
        status, st = call(base, "GET", "/status")
        check("the open count is in the state", st["followups_open"] >= 1, st)

        # A window with a stale copy (no block ids) saves: the ids survive, and
        # a tick made in the wrap-up itself reaches Notion.
        stale = json.loads(json.dumps(w["wrapup"]["edited"]))
        for item in stale["mine"]:
            item.pop("notion", None)
        stale["mine"][0]["done"] = True
        call(base, "PUT", f"/meeting/{mid}/wrapup", {"edited": stale})
        _, w2 = call(base, "GET", f"/meeting/{mid}/wrapup")
        check("block ids survive a stale save", w2["wrapup"]["edited"]["mine"][0].get("notion") == block, w2["wrapup"]["edited"]["mine"])
        wait("tick from the wrap-up", ticked, 10)
        check("a tick in the wrap-up reaches Notion", ticked())

        # Editing a follow-up's words keeps it tied to its to-do.
        reworded = json.loads(json.dumps(w2["wrapup"]["edited"]))
        reworded["mine"][0]["text"] = "Chase the Lumen port (reworded)"
        call(base, "PUT", f"/meeting/{mid}/wrapup", {"edited": reworded})
        _, w3 = call(base, "GET", f"/meeting/{mid}/wrapup")
        check("rewording keeps the Notion to-do", w3["wrapup"]["edited"]["mine"][0].get("notion") == block)

        # One deleted in Notion goes from Sidecar; removing one here takes it
        # off the Notion page.
        mine3 = w3["wrapup"]["edited"]["mine"]
        n = len(mine3)
        call(fake, "DELETE", f"/blocks/{block}")
        _, synced = call(base, "POST", "/followups/sync", {})
        left = [f for f in synced["followups"] if f["meeting"] == mid]
        check("a to-do deleted in Notion goes from Sidecar", len(left) == n - 1 and synced["changed"] >= 1, (n, synced))
        if left:
            _, w4 = call(base, "GET", f"/meeting/{mid}/wrapup")
            last = w4["wrapup"]["edited"]["mine"][-1]["notion"]
            _, after = call(base, "POST", "/followups/remove", {"meeting": mid, "index": len(left) - 1})
            check("a removed follow-up is gone from the list", len([f for f in after["followups"] if f["meeting"] == mid]) == n - 2)
            def trashed():
                _, b = call(fake, "GET", f"/blocks/{last}")
                return b.get("in_trash") is True
            wait("removed in Notion", trashed, 10)
            check("removing it removes the Notion to-do", trashed())
        _, fl2 = call(base, "GET", "/followups")
        starts = [f["started"] for f in fl2["followups"]]
        check("follow-ups come newest meeting first", starts == sorted(starts, reverse=True))

        # A note and a mark land in the transcript, at its end for a meeting that's over.
        status, seg = call(base, "POST", f"/meeting/{mid}/note", {"kind": "note", "text": "check the contract end date"})
        check("a note is a transcript line", status == 200 and seg["speaker"] == "Note" and seg["id"] == 1500, seg)
        status, seg = call(base, "POST", f"/meeting/{mid}/note", {"kind": "mark"})
        check("a mark is a transcript line", status == 200 and seg["speaker"] == "Mark", seg)
        status, _ = call(base, "POST", f"/meeting/{mid}/note", {"kind": "note", "text": "  "})
        check("an empty note is refused", status == 400)

        # The follow-up email: written, edited, saved to Drafts through vmail.
        status, _ = call(base, "POST", f"/meeting/{mid}/email")
        check("email writing starts", status == 200, _)
        def email_state(want):
            _, w = call(base, "GET", f"/meeting/{mid}/wrapup")
            e = w["wrapup"].get("email") or {}
            return e if e.get("state") == want else None
        e = wait("email", lambda: email_state("ready") or email_state("failed"))
        check("an email is written", e["state"] == "ready" and e["subject"] == "Cutover next steps", e)
        call(base, "PUT", f"/meeting/{mid}/email", {"to": ["amy@northwind.example"], "body": "Edited body"})
        call(base, "POST", f"/meeting/{mid}/email/save")
        e = wait("saved", lambda: email_state("saved"))
        made = (tmp / "vmail.txt").read_text()
        check("vmail makes a draft with the edits", "draft new" in made and "amy@northwind.example" in made
              and "Edited body" in made and "--send" not in made, made)

        # Filling in a page someone else made: only empty properties, our part under its own heading.
        _, seeded = call(fake, "POST", "/_page", {"title": "Northwind (from elsewhere)"})
        other = "2026-10-26_120000"
        call(base, "POST", f"/meeting/{other}/wrapup")
        wait("draft 2", lambda: _ready(base, other))
        _, cands = call(base, "GET", f"/meeting/{other}/notion")
        check("candidates include the seeded page", any(p["id"] == seeded["id"] for p in cands["pages"]), cands)
        check("candidates leave out Sidecar's own pages", all(p["id"] != pid for p in cands["pages"]), cands)
        call(base, "POST", f"/meeting/{other}/notion", {"target": seeded["id"]})
        m = wait("filled", lambda: _notion(base, other, "sent"))
        _, log = call(fake, "GET", "/_log")
        patch = [r for r in log["log"] if r["path"] == f"/pages/{seeded['id']}" and r["method"] == "PATCH"][0]["body"]
        check("their summary and title stay", "Summary" not in patch["properties"] and "Meeting Title" not in patch["properties"], patch)
        check("empty properties filled", "Date" in patch["properties"] and "Duration" in patch["properties"])
        first = [r for r in log["log"] if r["path"] == f"/blocks/{seeded['id']}/children"][0]["body"]["children"]
        check("our part sits under its own heading", first[1]["type"] == "heading_1"
              and first[1]["heading_1"]["rich_text"][0]["text"]["content"] == "Sidecar notes")

        # Do it all: a new page in Notion and the email saved to Drafts, in one go.
        third = "2026-10-26_140000"
        call(base, "POST", f"/meeting/{third}/wrapup")
        wait("draft 3", lambda: _ready(base, third))
        before = (tmp / "vmail.txt").read_text()
        status, done = call(base, "POST", f"/meeting/{third}/finish")
        check("do it all starts both", status == 200 and done["started"] == {"notion": True, "email": True}, done)
        wait("finished in Notion", lambda: _notion(base, third, "sent"))
        def drafted():
            _, w = call(base, "GET", f"/meeting/{third}/wrapup")
            return ((w["wrapup"].get("email") or {}).get("state") == "saved") or None
        wait("email drafted", drafted)
        made = (tmp / "vmail.txt").read_text()
        check("do it all files it and drafts the email", made != before and "draft new" in made and "--send" not in made, made)
        status, again = call(base, "POST", f"/meeting/{third}/finish")
        check("doing it again does nothing twice", again["started"] == {"notion": False, "email": False}, again)

        # With a page from that day already there to fill in, Do it all leaves
        # the page to Chris and still drafts the email.
        fourth = "2026-10-26_160000"
        call(base, "POST", f"/meeting/{fourth}/wrapup")
        wait("draft 4", lambda: _ready(base, fourth))
        call(fake, "POST", "/_page", {"title": "Belmont (from elsewhere)"})
        status, done = call(base, "POST", f"/meeting/{fourth}/finish")
        check("with a page to fill in, Do it all asks which", done["started"] == {"notion": "choose", "email": True}, done)

        # Notion's the default: a new page and no email.
        call(base, "POST", f"/meeting/{fourth}/finish", {"email": False})

        check_send_all_and_rows(tmp, fake, env, check, wait)

        # A failed draft says why; delete moves the folder to the trash.
        check("skipping is saved", call(base, "PATCH", f"/meeting/{other}", {"skipped": True})[1]["skipped"] is True)
        status, _ = call(base, "DELETE", f"/meeting/{other}")
        check("delete works", status == 200 and not (meetings / other).exists() and (tmp / "trash" / other).exists())
    finally:
        for p in procs:
            p.terminate()
        for p in procs:
            p.wait(5)
    print(f"\n{'All passed' if not failures else str(len(failures)) + ' failed'}  ({tmp})")
    sys.exit(1 if failures else 0)


ROWS = "f011ca00-0000-4000-8000-000000000001"


def check_send_all_and_rows(tmp, fake, env, check, wait):
    """Send all and the Follow-ups database, on an engine of their own."""
    folder = tmp / "bulk"
    started = time.time() - 3 * 3600
    ids = [f"2026-10-27_{h}0000" for h in (10, 11, 12)]
    for i, mid in enumerate(ids):
        make_meeting(folder, mid, f"Bulk {i}", 12, started - 5 * 86400 + i * 3600)
    port = free_port()
    proc = subprocess.Popen([PY, str(ROOT / "engine/engine.py")], cwd=ROOT / "engine", env={
        **env, "SIDECAR_PORT": str(port), "SIDECAR_MEETINGS": str(folder), "SIDECAR_NOTION_FOLLOWUPS": ROWS,
        "SIDECAR_SETTINGS": str(tmp / "settings2.json")})
    base = f"http://127.0.0.1:{port}"
    try:
        wait("second engine", lambda: _up(base), 60)
        for mid in ids[:2]:
            call(base, "POST", f"/meeting/{mid}/wrapup")
            wait("draft", lambda: _ready(base, mid))
        pages_before = len(call(fake, "GET", "/_log")[1]["pages"])
        # Pages from that day are already there: nothing is filed by guessing.
        status, sent = call(base, "POST", "/notion/bulk", {"ids": ids})
        check("send all takes only what's ready", status == 200 and sent["taken"] == 2, sent)
        held = wait("held back", lambda: (lambda b: b if not b["running"] else None)(call(base, "GET", "/status")[1]["bulk"]))
        check("a meeting with a page from that day waits to be picked",
              sorted(held["choose"]) == ids[:2] and held["done"] == 0, held)
        check("and nothing was filed", len(call(fake, "GET", "/_log")[1]["pages"]) == pages_before)

        # Nothing else on that day: both go, in turn.
        call(fake, "POST", "/_clear", {})
        pages_before = len(call(fake, "GET", "/_log")[1]["pages"])
        status, sent = call(base, "POST", "/notion/bulk", {"ids": ids})
        wait("both filed", lambda: _notion(base, ids[1], "sent"))
        done = wait("bulk done", lambda: (lambda b: b if not b["running"] else None)(call(base, "GET", "/status")[1]["bulk"]))
        check("send all reports what it did", done["done"] == 2 and not done["failed"] and not done["choose"], done)
        check("the third, with no wrap-up, is left alone", _meeting(base, ids[2]).get("notion") is None)

        log = call(fake, "GET", "/_log")[1]
        rows = {k: p for k, p in log["pages"].items() if p.get("parent") == ROWS}
        wrote = [e for e in log["log"] if e["path"].endswith("/children") and e["method"] == "PATCH"]
        check("follow-ups become rows", len(rows) >= 2, list(rows))
        check("a row points at its meeting", all(p["properties"]["Meeting"]["relation"] for p in rows.values()))
        check("no to-dos on the new pages", not any(c["type"] == "to_do" for e in wrote[-6:] for c in e["body"]["children"]))
        check("only meeting pages and rows were made", len(log["pages"]) == pages_before + 2 + len(rows))

        _, fl = call(base, "GET", "/followups")
        one = next(f for f in fl["followups"] if f["meeting"] == ids[0])
        check("a filed follow-up shows as in Notion", one["inNotion"] and not one["flagged"], one)

        # A flag goes up, and comes back.
        call(base, "POST", "/followups/flag", {"meeting": ids[0], "index": one["index"], "flagged": True})
        row = _row(base, ids[0], one["index"], folder)
        wait("the flag reaches the row", lambda: _prop(fake, row, "Flagged"))
        _, fl = call(base, "GET", "/followups")
        check("the flag sticks", next(f for f in fl["followups"] if f["meeting"] == ids[0])["flagged"])
        call(fake, "POST", "/_row", {"id": row, "Flagged": False, "Done": True})
        _, synced = call(base, "POST", "/followups/sync", {})
        back = next(f for f in synced["followups"] if f["meeting"] == ids[0] and f["index"] == one["index"])
        check("a flag and tick made in Notion come back", back["done"] and not back["flagged"], back)

        # Syncing again makes no second row, and a save from a window that
        # hadn't heard of the row or flag keeps them.
        count = len([p for p in call(fake, "GET", "/_log")[1]["pages"].values() if p.get("parent") == ROWS])
        call(base, "POST", "/followups/sync", {})
        again = len([p for p in call(fake, "GET", "/_log")[1]["pages"].values() if p.get("parent") == ROWS])
        check("syncing makes no second row", count == again, (count, again))
        _, w = call(base, "GET", f"/meeting/{ids[0]}/wrapup")
        stale = json.loads(json.dumps(w["wrapup"]["edited"]))
        for item in stale["mine"]:
            item.pop("row", None)
        call(base, "PUT", f"/meeting/{ids[0]}/wrapup", {"edited": stale})
        check("a stale save keeps the row", _row(base, ids[0], one["index"], folder) == row)

        # Deleted in Notion: gone from Sidecar. A removal here reaches the row.
        call(fake, "POST", "/_row", {"id": row, "archived": True})
        _, synced = call(base, "POST", "/followups/sync", {})
        check("a row deleted in Notion goes from Sidecar", not any(f["meeting"] == ids[0] and f["index"] == one["index"] and f["text"] == one["text"] for f in synced["followups"]))
        _, fl = call(base, "GET", "/followups")
        two = next(f for f in fl["followups"] if f["meeting"] == ids[1])
        row2 = _row(base, ids[1], two["index"], folder)
        call(base, "POST", "/followups/remove", {"meeting": ids[1], "index": two["index"]})
        wait("the row is removed", lambda: call(fake, "GET", "/_log")[1]["pages"][row2].get("archived"))

        # Sent before the database was shared: to-dos, then a row beside each
        # that keeps in step with its to-do, whichever is ticked.
        old = ids[2]
        call(base, "POST", f"/meeting/{old}/wrapup")
        wait("draft", lambda: _ready(base, old))
        call(fake, "POST", "/_clear", {})
        call(fake, "POST", "/_fail", {"rows_off": True})
        call(base, "POST", f"/meeting/{old}/notion", {})
        wait("filed with to-dos", lambda: _notion(base, old, "sent"))
        item = _item(folder, old, 0)
        check("not shared yet, follow-ups stay to-dos", item.get("notion") and not item.get("row"), item)
        call(fake, "POST", "/_fail", {"rows_off": False})
        call(base, "POST", "/followups/sync", {})
        item = _item(folder, old, 0)
        check("once shared, the follow-up gets a row and keeps its to-do", item.get("notion") and item.get("row"), item)
        call(fake, "PATCH", f"/blocks/{item['notion']}", {"to_do": {"checked": True}})
        _, synced = call(base, "POST", "/followups/sync", {})
        check("a tick on the old to-do comes back", next(f for f in synced["followups"] if f["meeting"] == old and f["index"] == 0)["done"], synced)
        wait("and reaches the row", lambda: _prop(fake, item["row"], "Done"))
        call(fake, "POST", "/_row", {"id": item["row"], "Done": False})
        _, synced = call(base, "POST", "/followups/sync", {})
        check("unticking the row wins over the to-do that hasn't caught up",
              not next(f for f in synced["followups"] if f["meeting"] == old and f["index"] == 0)["done"], synced)
        wait("and reaches the to-do", lambda: not _checked(fake, base, item["notion"]))

    finally:
        proc.terminate()
        proc.wait(5)


def _item(folder, mid, index):
    w = json.loads((folder / mid / "wrapup.json").read_text())
    return (w.get("edited") or w["draft"])["mine"][index]


def _checked(fake, base, block):
    return call(fake, "GET", f"/blocks/{block}")[1]["to_do"]["checked"]


def _meeting(base, mid):
    return call(base, "GET", f"/meeting/{mid}/wrapup")[1]["meeting"]


def _row(base, mid, index, folder):
    w = json.loads((folder / mid / "wrapup.json").read_text())
    return (w.get("edited") or w["draft"])["mine"][index].get("row")


def _prop(fake, row, name):
    return call(fake, "GET", "/_log")[1]["pages"][row]["properties"][name]["checkbox"]


def _up(base):
    try:
        return call(base, "GET", "/status")[0] == 200
    except OSError:
        return False


def check_tools_found_from_a_bare_path(tmp, check):
    """systemd hands the engine a bare PATH; claude must still be found."""
    wrappers = tmp / ".local/share/mise/command-wrappers/bin"
    wrappers.mkdir(parents=True)
    (wrappers / "claude").write_text("#!/bin/sh\n")
    (wrappers / "claude").chmod(0o755)
    env = {**os.environ, "HOME": str(tmp), "PATH": "/usr/local/bin:/usr/bin"}
    out = subprocess.run([PY, "-c", "import shutil, tools; tools.extend_path(); print(shutil.which('claude'))"],
                         env=env, cwd=ROOT / "engine", capture_output=True, text=True).stdout.strip()
    check("claude is found from systemd's bare PATH", out == str(wrappers / "claude"), out)


def _ready(base, mid):
    status, w = call(base, "GET", f"/meeting/{mid}/wrapup")
    return w if w["wrapup"] and w["wrapup"]["state"] in ("ready", "failed") else None


def _notion(base, mid, state):
    _, w = call(base, "GET", f"/meeting/{mid}")
    n = w["meeting"].get("notion") or {}
    return w["meeting"] if n.get("state") == state else None


if __name__ == "__main__":
    main()
