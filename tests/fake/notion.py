#!/usr/bin/env python3
"""A stand-in for the Notion API, enough of it for Send: the database, a
query, pages and appending blocks. It keeps every request it gets, at
GET /_log, and fails the Nth append when told to (POST /_fail {"after": n})
so a resumed send can be tested."""
import json
import sys
import uuid

from aiohttp import web

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8790
DATABASE = "21553fc0-1092-80f5-b264-e9a451b14cee"
log = []
pages = {}
blocks = {}  # block or page id -> children
fail = {"after": None}


def opts(*names):
    return {"options": [{"name": n} for n in names]}


async def record(request):
    body = await request.json() if request.can_read_body else None
    log.append({"method": request.method, "path": request.path, "body": body})
    return body


async def database(request):
    await record(request)
    return web.json_response({"id": DATABASE, "properties": {
        "Met with": {"type": "multi_select", "multi_select": opts("Belmont", "Nortridge")},
        "Tags": {"type": "multi_select", "multi_select": opts("Migration", "VoIP", "Sales")}}})


async def query(request):
    await record(request)
    results = [{"id": pid, "url": f"https://notion.so/{pid}", "created_time": "2026-10-26T18:00:00.000Z",
                "properties": p["properties"]} for pid, p in pages.items()]
    return web.json_response({"results": results})


def page_json(pid):
    return {"id": pid, "url": f"https://notion.so/{pid.replace('-', '')}", **pages[pid]}


async def create(request):
    body = await record(request)
    pid = str(uuid.uuid4())
    props = {k: {"type": next(iter(v)), **v} for k, v in body["properties"].items()}
    pages[pid] = {"properties": props}
    blocks[pid] = list(body.get("children", []))
    return web.json_response(page_json(pid))


async def get_page(request):
    await record(request)
    pid = request.match_info["id"]
    if pid not in pages:
        return web.json_response({"message": "Could not find page"}, status=404)
    return web.json_response(page_json(pid))


async def update_page(request):
    body = await record(request)
    pid = request.match_info["id"]
    for k, v in body.get("properties", {}).items():
        pages[pid]["properties"][k] = {"type": next(iter(v)), **v}
    return web.json_response(page_json(pid))


async def append(request):
    body = await record(request)
    if fail["after"] is not None:
        if fail["after"] == 0:
            fail["after"] = None
            return web.json_response({"message": "Bad gateway"}, status=400)
        fail["after"] -= 1
    bid = request.match_info["id"]
    assert len(body["children"]) <= 100, "more than 100 children"
    for child in body["children"]:
        for rt in child.get(child["type"], {}).get("rich_text", []):
            assert len(rt["text"]["content"]) <= 2000, "rich text over 2000"
    results = []
    for child in body["children"]:
        cid = str(uuid.uuid4())
        blocks.setdefault(bid, []).append({**child, "id": cid})
        blocks[cid] = []
        results.append({**child, "id": cid})
    return web.json_response({"results": results})


async def get_block(request):
    await record(request)
    bid = request.match_info["id"]
    for children in blocks.values():
        for b in children:
            if b.get("id") == bid:
                return web.json_response(b)
    return web.json_response({"message": "Could not find block"}, status=404)


async def update_block(request):
    body = await record(request)
    bid = request.match_info["id"]
    for children in blocks.values():
        for b in children:
            if b.get("id") == bid:
                for k, v in body.items():
                    b.setdefault(k, {}).update(v)
                return web.json_response(b)
    return web.json_response({"message": "Could not find block"}, status=404)


async def get_log(request):
    return web.json_response({"log": log, "pages": pages, "blocks": {k: len(v) for k, v in blocks.items()}})


async def set_fail(request):
    fail["after"] = (await request.json()).get("after")
    return web.json_response(fail)


async def add_page(request):
    """Seeds a page as if another tool had made it."""
    body = await request.json()
    pid = str(uuid.uuid4())
    pages[pid] = {"properties": {
        "Meeting Title": {"type": "title", "title": [{"plain_text": body["title"], "text": {"content": body["title"]}}]},
        "Summary": {"type": "rich_text", "rich_text": [{"plain_text": "Theirs", "text": {"content": "Theirs"}}]},
        "Date": {"type": "date", "date": None}, "Duration": {"type": "rich_text", "rich_text": []},
        "Tags": {"type": "multi_select", "multi_select": []}}}
    blocks[pid] = []
    return web.json_response({"id": pid})


app = web.Application()
app.router.add_get(f"/databases/{DATABASE}", database)
app.router.add_post(f"/databases/{DATABASE}/query", query)
app.router.add_post("/pages", create)
app.router.add_get("/pages/{id}", get_page)
app.router.add_patch("/pages/{id}", update_page)
app.router.add_patch("/blocks/{id}/children", append)
app.router.add_get("/blocks/{id}", get_block)
app.router.add_patch("/blocks/{id}", update_block)
app.router.add_get("/_log", get_log)
app.router.add_post("/_fail", set_fail)
app.router.add_post("/_page", add_page)
web.run_app(app, host="127.0.0.1", port=PORT, print=None)
