"""Sending a meeting to a private "My Meetings" database in Notion.

The token is an internal integration's, kept in the keyring and shared with
that database and the Follow-ups database beside it. Sending is built to survive being interrupted: the
page id is saved the moment the page exists, and each batch of blocks moves a
saved cursor forward, so trying again carries on where it stopped and never
makes a second page.
"""
import asyncio
import os
from datetime import datetime, timedelta

import aiohttp

API = os.environ.get("SIDECAR_NOTION_API", "https://api.notion.com/v1")
VERSION = "2022-06-28"  # the version the database was read with; later ones change how databases work
# Both ids come from the environment (~/.config/aloi-sidecar/env for the service).
DATABASE = os.environ.get("SIDECAR_NOTION_DATABASE", "")
# One row per follow-up, each related to its meeting's page. Until it's shared
# with the integration (⋯ → Connections), follow-ups stay to-dos on the page.
FOLLOWUPS = os.environ.get("SIDECAR_NOTION_FOLLOWUPS", "")
BATCH = 100  # Notion's most children per request
TEXT = 1900  # under Notion's 2,000 characters per rich-text item
HEADING = "Sidecar notes"  # what Sidecar's part of a page it fills in sits under


class NotionError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


async def token():
    """The token from the keyring, or an error saying how to put it there."""
    if os.environ.get("SIDECAR_NOTION_TOKEN"):  # tests only
        return os.environ["SIDECAR_NOTION_TOKEN"]
    try:
        proc = await asyncio.create_subprocess_exec(
            "secret-tool", "lookup", "service", "aloi-sidecar", "account", "notion",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(proc.communicate(), 20)
    except (FileNotFoundError, asyncio.TimeoutError):
        raise NotionError("Couldn't read the keyring. Is it unlocked?")
    if not out.strip():
        raise NotionError("No Notion token in the keyring. Store it with: secret-tool store "
                          "--label=\"Aloi Sidecar Notion\" service aloi-sidecar account notion")
    return out.decode().strip()


def text(s, **annotations):
    """Rich text for any length of string, in pieces Notion accepts."""
    s = s or ""
    pieces = [s[i:i + TEXT] for i in range(0, len(s), TEXT)] or [""]
    out = []
    for p in pieces:
        item = {"type": "text", "text": {"content": p}}
        if annotations:
            item["annotations"] = annotations
        out.append(item)
    return out


def block(kind, content="", **extra):
    return {"object": "block", "type": kind, kind: {"rich_text": text(content), **extra}}


def plain(rich):
    return "".join(r.get("plain_text", r.get("text", {}).get("content", "")) for r in rich or [])


def iso(t):
    return datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")


def duration(meta):
    minutes = max(1, round(((meta["ended"] or meta["started"]) - meta["started"]) / 60))
    return f"{minutes} min" if minutes < 60 else f"{minutes // 60} h {minutes % 60:02d} min"


def body(w, refs=None, todos=True):
    """The page's sections, in the shape the database's other pages have
    (TL;DR, then Topics), with the follow-ups as to-dos unless they're rows in
    the Follow-ups database (todos=False). refs, if given, is filled in
    parallel: the index of Chris's follow-up each to-do is, else None, so the
    to-dos' block ids can be kept for ticking them off later."""
    out = []
    if w["tldr"] or w["summary"]:
        out.append(block("heading_2", "TL;DR"))
        if w["tldr"]:
            out.append(block("paragraph", w["tldr"]))
        for para in (w["summary"] or "").split("\n\n"):
            if para.strip():
                out.append(block("paragraph", para.strip()))
    if w["topics"]:
        out.append(block("heading_2", "Topics"))
        for t in w["topics"]:
            out.append(block("heading_3", t["title"]))
            out += [block("bulleted_list_item", p) for p in t["points"]]

    def due(i):
        return f" ({i['due']})" if i.get("due") else ""

    if w["mine"] and todos:
        out.append(block("heading_2", "My follow-ups"))
        start = len(out)
        out += [block("to_do", i["text"] + due(i), checked=bool(i.get("done"))) for i in w["mine"]]
        if refs is not None:
            refs.update({start + n: n for n in range(len(w["mine"]))})
    if w["theirs"]:
        out.append(block("heading_2", "Their commitments"))
        out += [block("bulleted_list_item", f"{i['who']}: {i['text']}{due(i)}") for i in w["theirs"]]
    if w["decisions"]:
        out.append(block("heading_2", "Decisions"))
        out += [block("bulleted_list_item", i["text"]) for i in w["decisions"]]
    if w["questions"]:
        out.append(block("heading_2", "Open questions"))
        out += [block("bulleted_list_item", i["text"]) for i in w["questions"]]
    return out


def transcript(segments):
    """The transcript as paragraphs of whole lines, each under Notion's
    limit, rather than a block per line."""
    out, chunk = [], ""
    for s in segments:
        line = f"{datetime.fromtimestamp(s['start']):%-I:%M:%S %p}  {s['speaker']}: {s['text']}"
        if chunk and len(chunk) + len(line) + 1 > TEXT:
            out.append(block("paragraph", chunk))
            chunk = ""
        chunk = f"{chunk}\n{line}" if chunk else line
    if chunk:
        out.append(block("paragraph", chunk))
    return out


class Notion:
    def __init__(self, session=None):
        self.session = session

    async def call(self, method, path, json=None):
        if not DATABASE:
            raise NotionError("No Notion database set. Put SIDECAR_NOTION_DATABASE=<id> in "
                              "~/.config/aloi-sidecar/env, then restart the engine.")
        if self.session is None:
            self.session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=60))
        headers = {"Authorization": f"Bearer {await token()}", "Notion-Version": VERSION,
                   "Content-Type": "application/json"}
        for attempt in range(4):
            try:
                async with self.session.request(method, API + path, json=json, headers=headers) as r:
                    data = await r.json(content_type=None)
                    if r.status == 429 or r.status >= 500:
                        await asyncio.sleep(float(r.headers.get("Retry-After", 1 + attempt * 2)))
                        continue
                    if r.status >= 400:
                        message = (data or {}).get("message", f"HTTP {r.status}")
                        if r.status == 401:
                            message = "Notion didn't accept the token. Make a new one and store it again."
                        elif r.status == 404:
                            message = ("Notion can't see that. Share the My Meetings database with the "
                                       "Aloi Sidecar integration (⋯ → Connections).")
                        raise NotionError(message, r.status)
                    return data
            except aiohttp.ClientError:
                if attempt == 3:
                    raise NotionError("Couldn't reach Notion.")
                await asyncio.sleep(1 + attempt * 2)
        raise NotionError("Notion is busy; try again in a minute.")

    async def close(self):
        if self.session:
            await self.session.close()
            self.session = None

    async def options(self):
        """The names and tags the database already has."""
        db = await self.call("GET", f"/databases/{DATABASE}")
        props = db.get("properties", {})

        def names(key):
            p = props.get(key, {})
            return [o["name"] for o in p.get(p.get("type", ""), {}).get("options", [])]

        return {"met_with": names("Met with"), "tags": names("Tags")}

    async def candidates(self, meta):
        """Pages made the day of the meeting, which may be this meeting
        already filed by something else. Chris picks; nothing merges by
        itself."""
        day = datetime.fromtimestamp(meta["started"]).astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
        query = {"page_size": 25, "sorts": [{"timestamp": "created_time", "direction": "ascending"}],
                 "filter": {"or": [
                     {"and": [{"timestamp": "created_time", "created_time": {"on_or_after": day.isoformat()}},
                              {"timestamp": "created_time", "created_time": {"before": (day + timedelta(days=1)).isoformat()}}]},
                     {"property": "Date", "date": {"equals": day.date().isoformat()}}]}}
        data = await self.call("POST", f"/databases/{DATABASE}/query", query)
        out = []
        for page in data.get("results", []):
            p = page.get("properties", {})
            out.append({"id": page["id"], "url": page.get("url", ""),
                        "title": plain(p.get("Meeting Title", {}).get("title")) or "Untitled",
                        "created": page.get("created_time", ""),
                        "summary": plain(p.get("Summary", {}).get("rich_text"))[:200]})
        return out

    def properties(self, meta, w, options):
        met = [v for v in w["met_with"] if v in options["met_with"]]
        tags = [v for v in w["tags"] if v in options["tags"]][:5]
        return {
            "Meeting Title": {"title": text(w.get("title") or meta["title"])},
            "Date": {"date": {"start": iso(meta["started"]), "end": iso(meta["ended"] or meta["started"])}},
            "Duration": {"rich_text": text(duration(meta))},
            "Summary": {"rich_text": text(w["tldr"])},
            "Topic": {"rich_text": text(", ".join(t["title"] for t in w["topics"]))},
            "Met with": {"multi_select": [{"name": v} for v in met]},
            "Tags": {"multi_select": [{"name": v} for v in tags]},
            "Format": {"select": {"name": w["format"]}},
            "Status": {"select": {"name": "published"}},
        }

    async def send(self, meta, w, segments, target, save):
        """Files the meeting. target is None for a new page or the id of a
        page to fill in; save(progress) is called after every step so a
        failure part way can be resumed with the same progress."""
        progress = dict(meta.get("notion") or {})
        options = await self.options()
        props = self.properties(meta, w, options)
        # Decided once per page, so a resumed send lays out the same sections.
        rows = progress.get("rows", False) if progress.get("id") else await followups_ready(self)
        refs = {}
        sections = body(w, refs, todos=not rows)
        lines = transcript(segments)
        lead = 0  # blocks put before Sidecar's own when filling in a page

        if not progress.get("id"):
            if target:
                page = await self.call("GET", f"/pages/{target}")
                # Only what's empty is filled in; whatever's there stays.
                empty = {k: v for k, v in props.items()
                         if k in page.get("properties", {}) and is_empty(page["properties"][k])}
                empty.pop("Meeting Title", None)
                if empty:
                    await self.call("PATCH", f"/pages/{target}", {"properties": empty})
                sections = [{"object": "block", "type": "divider", "divider": {}},
                            block("heading_1", HEADING)] + sections
                lead = 2
                progress = {"id": target, "url": page.get("url", ""), "filled": True}
            else:
                page = await self.call("POST", "/pages", {"parent": {"database_id": DATABASE},
                                                          "properties": props})
                progress = {"id": page["id"], "url": page.get("url", ""), "filled": False}
            progress.update({"state": "sending", "sections": 0, "lines": 0, "toggle": None,
                             "total": len(sections), "todos": {}, "rows": rows})
            save(progress)
        elif progress.get("filled"):
            sections = [{"object": "block", "type": "divider", "divider": {}},
                        block("heading_1", HEADING)] + sections
            lead = 2

        page_id = progress["id"]
        while progress["sections"] < len(sections):
            first = progress["sections"]
            batch = sections[first:first + BATCH]
            result = await self.call("PATCH", f"/blocks/{page_id}/children", {"children": batch})
            # Each to-do's block id, by which follow-up it is.
            todos = progress.setdefault("todos", {})
            for n, made in enumerate(result.get("results", [])):
                k = first + n - lead
                if k in refs:
                    todos[str(refs[k])] = made["id"]
            progress["sections"] += len(batch)
            save(progress)

        if lines and not progress.get("toggle"):
            toggle = block("toggle", "Full transcript")
            result = await self.call("PATCH", f"/blocks/{page_id}/children", {"children": [toggle]})
            progress["toggle"] = result["results"][0]["id"]
            save(progress)
        while progress["lines"] < len(lines):
            batch = lines[progress["lines"]:progress["lines"] + BATCH]
            await self.call("PATCH", f"/blocks/{progress['toggle']}/children", {"children": batch})
            progress["lines"] += len(batch)
            save(progress)

        progress["state"] = "sent"
        progress["sent"] = datetime.now().timestamp()
        save(progress)
        return progress


async def todos_on(notion, page_id):
    """The to-dos on a page, as (block id, text, checked), reading every
    child (and the children of Sidecar's own heading when it filled one in)."""
    out, cursor = [], None
    while True:
        data = await notion.call("GET", f"/blocks/{page_id}/children?page_size=100" + (f"&start_cursor={cursor}" if cursor else ""))
        for b in data.get("results", []):
            if b.get("type") == "to_do":
                out.append((b["id"], plain(b["to_do"].get("rich_text")), bool(b["to_do"].get("checked"))))
        if not data.get("has_more"):
            return out
        cursor = data.get("next_cursor")


async def tick(notion, block_id, done):
    """Ticks (or unticks) one follow-up's to-do on its Notion page."""
    await notion.call("PATCH", f"/blocks/{block_id}", {"to_do": {"checked": bool(done)}})


GONE = "gone"


# ---- the Follow-ups database ----

async def followups_ready(notion):
    """Whether the integration can reach the Follow-ups database."""
    if not FOLLOWUPS:
        return False
    try:
        await notion.call("GET", f"/databases/{FOLLOWUPS}")
    except NotionError:
        return False
    return True


async def rows(notion):
    """Every row: {id: {text, done, flagged, meeting}}, in one paged query
    rather than a read per follow-up. Raises if any page can't be read, so a
    short answer is never taken to mean rows were deleted."""
    out, cursor = {}, None
    while True:
        query = {"page_size": 100}
        if cursor:
            query["start_cursor"] = cursor
        data = await notion.call("POST", f"/databases/{FOLLOWUPS}/query", query)
        for page in data.get("results", []):
            p = page.get("properties", {})
            out[page["id"]] = {"text": plain(p.get("Task", {}).get("title")),
                               "done": bool(p.get("Done", {}).get("checkbox")),
                               "flagged": bool(p.get("Flagged", {}).get("checkbox")),
                               "meeting": [r["id"].replace("-", "") for r in p.get("Meeting", {}).get("relation", [])]}
        if not data.get("has_more"):
            return out
        cursor = data.get("next_cursor")


async def add_row(notion, item, page_id, started):
    page = await notion.call("POST", "/pages", {"parent": {"database_id": FOLLOWUPS}, "properties": {
        "Task": {"title": text(item["text"])},
        "Done": {"checkbox": bool(item.get("done"))},
        "Flagged": {"checkbox": bool(item.get("flagged"))},
        "Due": {"rich_text": text(item.get("due", ""))},
        "Said": {"date": {"start": iso(started)}},
        "Meeting": {"relation": [{"id": page_id}]}}})
    return page["id"]


async def set_row(notion, row_id, done, flagged):
    await notion.call("PATCH", f"/pages/{row_id}", {"properties": {
        "Done": {"checkbox": bool(done)}, "Flagged": {"checkbox": bool(flagged)}}})


async def row_gone(notion, row_id):
    """Whether a row missing from the query was really deleted in Notion."""
    try:
        page = await notion.call("GET", f"/pages/{row_id}")
    except NotionError as e:
        return e.status == 404
    return bool(page.get("archived") or page.get("in_trash"))


async def remove_row(notion, row_id):
    """Takes one row out of the Follow-ups database (to Notion's trash)."""
    try:
        await notion.call("PATCH", f"/pages/{row_id}", {"archived": True})
    except NotionError as e:
        if e.status != 404:
            raise


async def ticked(notion, block_id):
    """Whether a follow-up's to-do is ticked in Notion; GONE if it was
    deleted there, None if Notion couldn't be asked."""
    try:
        b = await notion.call("GET", f"/blocks/{block_id}")
    except NotionError as e:
        return GONE if e.status == 404 else None
    return GONE if b.get("archived") or b.get("in_trash") else bool(b.get("to_do", {}).get("checked"))


async def remove(notion, block_id):
    """Deletes one follow-up's to-do from its Notion page (to Notion's trash)."""
    try:
        await notion.call("DELETE", f"/blocks/{block_id}")
    except NotionError as e:
        if e.status != 404:  # already gone is as good as removed
            raise


def is_empty(prop):
    kind = prop.get("type")
    value = prop.get(kind)
    if kind in ("rich_text", "title", "multi_select", "people", "files"):
        return not value
    if kind in ("select", "date", "url"):
        return value is None
    return False
