"""Sending a meeting to Chris's private "My Meetings" database in Notion.

The token is an internal integration's, kept in the keyring and shared with
that one database only. Sending is built to survive being interrupted: the
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
DATABASE = os.environ.get("SIDECAR_NOTION_DATABASE", "21553fc0-1092-80f5-b264-e9a451b14cee")
BATCH = 100  # Notion's most children per request
TEXT = 1900  # under Notion's 2,000 characters per rich-text item
HEADING = "Sidecar notes"  # what Sidecar's part of a page it fills in sits under


class NotionError(Exception):
    pass


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


def body(w):
    """The page's sections, in the shape the database's other pages have
    (TL;DR, then Topics), with the follow-ups as to-dos."""
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

    if w["mine"]:
        out.append(block("heading_2", "My follow-ups"))
        out += [block("to_do", i["text"] + due(i), checked=bool(i.get("done"))) for i in w["mine"]]
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
                        raise NotionError(message)
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
        sections = body(w)
        lines = transcript(segments)

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
                progress = {"id": target, "url": page.get("url", ""), "filled": True}
            else:
                page = await self.call("POST", "/pages", {"parent": {"database_id": DATABASE},
                                                          "properties": props})
                progress = {"id": page["id"], "url": page.get("url", ""), "filled": False}
            progress.update({"state": "sending", "sections": 0, "lines": 0, "toggle": None,
                             "total": len(sections)})
            save(progress)
        elif progress.get("filled"):
            sections = [{"object": "block", "type": "divider", "divider": {}},
                        block("heading_1", HEADING)] + sections

        page_id = progress["id"]
        while progress["sections"] < len(sections):
            batch = sections[progress["sections"]:progress["sections"] + BATCH]
            await self.call("PATCH", f"/blocks/{page_id}/children", {"children": batch})
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


def is_empty(prop):
    kind = prop.get("type")
    value = prop.get(kind)
    if kind in ("rich_text", "title", "multi_select", "people", "files"):
        return not value
    if kind in ("select", "date", "url"):
        return value is None
    return False
