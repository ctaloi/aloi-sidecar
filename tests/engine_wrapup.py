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
    meetings = tmp / "meetings"
    started = time.time() - 3 * 3600
    make_meeting(meetings, "2026-10-26_100000", "Call at 10:00", 1500, started)
    make_meeting(meetings, "2026-10-26_120000", "Northwind", 12, started + 7200)

    engine_port, notion_port = free_port(), free_port()
    procs = [subprocess.Popen([PY, str(ROOT / "tests/fake/notion.py"), str(notion_port)])]
    env = {**os.environ, "SIDECAR_PORT": str(engine_port), "SIDECAR_MEETINGS": str(meetings),
           "SIDECAR_NOTION_API": f"http://127.0.0.1:{notion_port}", "SIDECAR_NOTION_TOKEN": "test",
           "SIDECAR_WRAPUP_CLAUDE": str(ROOT / "tests/fake/claude-wrapup"), "SIDECAR_CALL_WATCH": "0",
           "SIDECAR_CALENDAR": "", "SIDECAR_SETTINGS": str(tmp / "settings.json"),
           "SIDECAR_VMAIL": str(ROOT / "tests/fake/vmail"), "FAKE_VMAIL_OUT": str(tmp / "vmail.txt")}
    procs.append(subprocess.Popen([PY, str(ROOT / "engine/engine.py")], env=env, cwd=ROOT / "engine"))
    base, fake = f"http://127.0.0.1:{engine_port}", f"http://127.0.0.1:{notion_port}"
    try:
        wait("engine", lambda: _up(base), 60)
        mid = "2026-10-26_100000"

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
        edited = {**draft, "title": "Northwind Dental Cutover", "mine": draft["mine"][:1]}
        call(base, "PUT", f"/meeting/{mid}/wrapup", {"edited": edited})
        call(base, "POST", f"/meeting/{mid}/wrapup")
        w = wait("redraft", lambda: _ready(base, mid))
        check("edits survive a redraft", w["wrapup"]["edited"]["title"] == "Northwind Dental Cutover", w["wrapup"])
        check("listing says it was edited", w["meeting"]["edited"] is True)

        status, md = call(base, "GET", f"/meeting/{mid}/markdown")
        check("markdown uses the edits", "# Northwind Dental Cutover" in md and md.count("- [ ]") == 1, md[:300])

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


def _up(base):
    try:
        return call(base, "GET", "/status")[0] == 200
    except OSError:
        return False


def _ready(base, mid):
    status, w = call(base, "GET", f"/meeting/{mid}/wrapup")
    return w if w["wrapup"] and w["wrapup"]["state"] in ("ready", "failed") else None


def _notion(base, mid, state):
    _, w = call(base, "GET", f"/meeting/{mid}")
    n = w["meeting"].get("notion") or {}
    return w["meeting"] if n.get("state") == state else None


if __name__ == "__main__":
    main()
