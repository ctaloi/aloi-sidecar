"""Noticing a call: another app opening the microphone.

Teams, Zoom or a browser tab grabbing the mic is the surest sign a call has
started, and letting go of it the surest sign it's over. PipeWire says when
a recording stream appears; this watches for one that isn't Sidecar's own,
isn't on a monitor (a speaker's loopback), isn't dictation, and lasts long
enough to be a call rather than a quick probe.
"""
import asyncio
import json
import os
import time

HOLD = 4  # seconds a stream must last before it counts; dictation and mic checks are shorter
RELEASE = 8  # seconds the mic must stay free before a call counts as over; rides out device switches
CALL_APPS = ("Teams", "Zoom", "Google Meet", "Slack", "Discord", "Webex", "WhatsApp")
IGNORE = ("superwhisper", "pavucontrol", "easyeffects", "cava", "wireplumber", "aloi-sidecar")


async def run(*args):
    proc = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE,
                                                stderr=asyncio.subprocess.DEVNULL)
    out, _ = await proc.communicate()
    return out.decode()


async def window_name():
    """What's in front, to name the call: Omarchy web apps carry the site in
    their class (chrome-teams.microsoft.com__-Default)."""
    try:
        w = json.loads(await run("hyprctl", "-j", "activewindow") or "{}")
    except (json.JSONDecodeError, FileNotFoundError):
        return None
    cls = (w.get("class") or "").lower()
    for key, name in (("teams", "Teams"), ("zoom", "Zoom"), ("meet.google", "Google Meet"),
                      ("slack", "Slack"), ("discord", "Discord"), ("webex", "Webex"), ("whatsapp", "WhatsApp")):
        if key in cls:
            return name
    return None


def describe(props):
    name = props.get("application.name") or props.get("application.process.binary") or "An app"
    return {"Chromium": "Chromium", "Google Chrome": "Chrome", "Firefox": "Firefox"}.get(name, name)


class CallWatch:
    """Calls on_start(app) when a call seems to begin and on_end(app) when it
    seems over. own() returns the process ids of Sidecar's own recorders."""

    def __init__(self, own, on_start, on_end):
        self.own, self.on_start, self.on_end = own, on_start, on_end
        self.seen = {}  # stream index -> (first seen, app)
        self.active = None  # the app in a call, once on_start has fired
        self.free_since = None
        self.wake = asyncio.Event()

    async def users(self):
        """Recording streams that could be a call."""
        try:
            outputs = json.loads(await run("pactl", "-f", "json", "list", "source-outputs") or "[]")
            sources = json.loads(await run("pactl", "-f", "json", "list", "sources") or "[]")
        except (json.JSONDecodeError, FileNotFoundError):
            return {}
        monitors = {s["index"] for s in sources
                    if (s.get("name") or "").endswith(".monitor") or s.get("monitor_of_sink") not in (None, "n/a")}
        mine = {str(p) for p in self.own()}
        out = {}
        for o in outputs:
            p = o.get("properties", {})
            who = " ".join(str(p.get(k, "")) for k in ("application.name", "application.process.binary", "node.name")).lower()
            if (p.get("application.process.id") in mine or o.get("source") in monitors or o.get("corked")
                    or any(i in who for i in IGNORE)):
                continue
            out[o["index"]] = describe(p)
        return out

    async def check(self):
        now = time.time()
        users = await self.users()
        self.seen = {i: self.seen.get(i, (now, app)) for i, app in users.items()}
        lasting = [app for first, app in self.seen.values() if now - first >= HOLD]
        if self.active is None:
            if lasting:
                self.active = (await window_name()) or lasting[0]
                self.free_since = None
                await self.on_start(self.active)
            return bool(self.seen)  # something new is still proving itself
        if users:
            self.free_since = None
            return False
        self.free_since = self.free_since or now
        if now - self.free_since >= RELEASE:
            app, self.active, self.free_since = self.active, None, None
            await self.on_end(app)
            return False
        return True

    async def watch(self):
        """Wakes on PipeWire's events, and checks again every second while a
        stream is proving itself or the mic has only just come free."""
        events = asyncio.create_task(self.listen())
        try:
            pending = await self.check()
            while True:
                try:
                    await asyncio.wait_for(self.wake.wait(), 1 if pending else 30)
                except asyncio.TimeoutError:
                    pass
                self.wake.clear()
                pending = await self.check()
        finally:
            events.cancel()

    async def listen(self):
        while True:
            try:
                proc = await asyncio.create_subprocess_exec("pactl", "subscribe", stdout=asyncio.subprocess.PIPE,
                                                            stderr=asyncio.subprocess.DEVNULL)
            except FileNotFoundError:
                return
            try:
                async for line in proc.stdout:
                    if b"source-output" in line:
                        self.wake.set()
            finally:
                if proc.returncode is None:
                    proc.kill()
            await asyncio.sleep(3)  # PipeWire restarted; follow it back


async def notify(title, body, actions, timeout=60):
    """A desktop notification with buttons; returns the chosen action's
    name, or None if it was dismissed or timed out. Clicking the
    notification itself picks "default". Cancelling takes it off screen."""
    args = ["notify-send", "--app-name=Aloi Sidecar", "--icon=aloi-sidecar", "--print-id",
            f"--expire-time={timeout * 1000}"]
    args += [f"--action={name}={label}" for name, label in actions]
    try:
        proc = await asyncio.create_subprocess_exec(*args, title, body, stdout=asyncio.subprocess.PIPE,
                                                    stderr=asyncio.subprocess.DEVNULL)
    except FileNotFoundError:
        return None
    nid, choice = None, None
    try:
        async with asyncio.timeout(timeout + 5):
            async for raw in proc.stdout:
                line = raw.decode().strip()
                if line.isdigit() and nid is None:
                    nid = line
                elif line:
                    choice = line
        await proc.wait()
        return choice
    except (asyncio.TimeoutError, asyncio.CancelledError):
        proc.kill()
        if nid:
            await run("gdbus", "call", "--session", "--dest", "org.freedesktop.Notifications",
                      "--object-path", "/org/freedesktop/Notifications",
                      "--method", "org.freedesktop.Notifications.CloseNotification", nid)
        if asyncio.current_task().cancelling():
            raise
        return None


def enabled():
    return os.environ.get("SIDECAR_CALL_WATCH", "1") != "0"
