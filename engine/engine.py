#!/usr/bin/env python3
"""Aloi Sidecar engine: a live transcript of the meeting you're in.

Captures your mic ("Chris") and every speaker output ("Them") through
PipeWire and transcribes locally with Parakeet (sherpa-onnx). It only listens
while asked to (POST /listen); the Aloi Sidecar app turns it on and off and
runs the agent. Events stream from GET /events. It asks no model itself
except through `claude -p` (wrap-ups, takeaways, the email): no API key.
"""
import asyncio
import concurrent.futures
import collections
import difflib
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

import numpy as np
import sherpa_onnx
from aiohttp import web

import agenda
import insights
import calls
import mailer
import takeaways
import tools
import voices
import wrapup
import notion
from notion import Notion, NotionError

tools.extend_path()

RATE = 16000
CHUNK = 1600  # 100 ms of samples per read
PORT = int(os.environ.get("SIDECAR_PORT", 8777))
MODELS = Path.home() / ".local/share/aloi-sidecar/models"
PARAKEET = MODELS / "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
MEETINGS = Path(os.environ.get("SIDECAR_MEETINGS", Path.home() / ".local/share/aloi-sidecar/meetings"))
TRASH = MEETINGS.parent / "trash"  # deleted meetings go here, never straight to nothing
SETTINGS = Path(os.environ.get("SIDECAR_SETTINGS", Path.home() / ".config/aloi-sidecar/settings.json"))
DEFAULTS = {"watch_calls": True, "live_takeaways": True, "stop_on_silence": True,
            "speaker_names": False}
QUIET_ASK = 5 * 60  # seconds of nothing said while listening before the call is taken to be over
QUIET_END = 3 * 60  # and then, still quiet, before the meeting ends by itself
SWITCH_AFTER = 60  # seconds before a running meeting gives way to the next calendar meeting
END_AFTER = 30  # seconds after a call lets go of the mic before its meeting ends
RECOVER_WINDOW = 2 * 60 * 60  # a meeting left live by a crash comes back paused if its last line is this recent
ME = "Chris"
# Lines Chris adds himself, not speech: a typed note, and a mark on a moment
# that mattered. They sit in the transcript so the agent and the wrap-up see them.
OWN = ("Note", "Mark")

INTERIM_EVERY = 2.5  # seconds between live-preview decodes
INTERIM_TAIL = 4  # preview only the last N seconds of the utterance
# A mic line whose loudness rises and falls with a speaker output's, at the
# same moments, is that speaker heard through the room: skip it before it's
# decoded. Speech over speech (Chris talking over them) blurs the match.
ECHO_CORR = float(os.environ.get("SIDECAR_ECHO_CORR", 0.85))
ECHO_MIN_FRAMES = 15  # 1.5 s; shorter mic lines are cheap, decode them anyway
ECHO_LAG = 5  # frames (100 ms each) either way the two captures may drift
ECHO_HOLD = 3  # seconds a mic line waits for the speaker line it may be an echo of
ECHO_RATIO = 0.55



def make_recognizer():
    return sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=str(PARAKEET / "encoder.int8.onnx"),
        decoder=str(PARAKEET / "decoder.int8.onnx"),
        joiner=str(PARAKEET / "joiner.int8.onnx"),
        tokens=str(PARAKEET / "tokens.txt"),
        model_type="nemo_transducer",
        # onnxruntime's extra threads busy-wait. Measured 2026-11-12 on the
        # Core Ultra X7: an 8 s line takes 646 ms wall / 644 ms CPU on one
        # thread, 530 ms / 1,769 ms on two. One is still ~12x real time.
        num_threads=int(os.environ.get("SIDECAR_ASR_THREADS", 1)),
        decoding_method="greedy_search",
    )


def make_vad():
    config = sherpa_onnx.VadModelConfig()
    config.silero_vad.model = str(MODELS / "silero_vad.onnx")
    config.silero_vad.min_silence_duration = 0.5
    config.silero_vad.max_speech_duration = 15
    config.sample_rate = RATE
    return sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=60), config.silero_vad.window_size


def stamp(t):
    return datetime.fromtimestamp(t).strftime("%H:%M:%S")


def echo_score(mine, theirs, lag=ECHO_LAG):
    """How closely one loudness track (100 ms frames) follows another,
    allowing a few frames of drift either way: Pearson correlation at the best
    lag, 0 when either side is flat (silence, or an idle output)."""
    mine, theirs = np.asarray(mine, dtype=np.float64), np.asarray(theirs, dtype=np.float64)
    n = min(len(mine), len(theirs))
    best = 0.0
    for k in range(-lag, lag + 1):
        a = mine[max(0, k):n + min(0, k)]
        b = theirs[max(0, -k):n - max(0, k)]
        m = min(len(a), len(b))
        if m < ECHO_MIN_FRAMES:
            continue
        a, b = a[:m], b[:m]
        if a.std() < 1e-6 or b.std() < 1e-6:
            continue
        best = max(best, float(np.corrcoef(a, b)[0, 1]))
    return best


def similar(a, b):
    return difflib.SequenceMatcher(None, a.lower(), b.lower()).ratio() > ECHO_RATIO


class Meeting:
    """One meeting: a folder with meta.json and transcript.jsonl. It has edges:
    it starts (by hand or for a calendar event), it can pause, and it ends.
    Nothing is ever merged into a meeting by time alone."""

    def __init__(self, folder, meta, segments=None):
        self.folder = Path(folder)
        self.meta = meta
        self._segments = segments
        self.log = None

    @classmethod
    def create(cls, title, event=None):
        now = time.time()
        mid = datetime.fromtimestamp(now).strftime("%Y-%m-%d_%H%M%S")
        folder = MEETINGS / mid
        n = 2
        while folder.exists():  # two starts in one second
            folder = MEETINGS / f"{mid}-{n}"
            n += 1
        meta = {"id": folder.name, "title": title, "started": now, "ended": None, "state": "live",
                "event": event, "people": [], "notion": None, "skipped": False}
        m = cls(folder, meta, [])
        return m

    @classmethod
    def load(cls, folder):
        meta = json.loads((folder / "meta.json").read_text())
        return cls(folder, meta)

    @property
    def id(self):
        return self.meta["id"]

    @property
    def segments(self):
        if self._segments is None:
            path = self.folder / "transcript.jsonl"
            self._segments = []
            if path.exists():
                with path.open() as f:
                    self._segments = [json.loads(line) for line in f if line.strip()]
        return self._segments

    def lines(self):
        if self._segments is not None:
            return len(self._segments)
        path = self.folder / "transcript.jsonl"
        if not path.exists():
            return 0
        with path.open("rb") as f:
            return sum(1 for _ in f)

    def last_line_end(self):
        segs = self.segments
        return segs[-1]["end"] if segs else self.meta["started"]

    def summary(self):
        w = self.wrapup()
        return {**self.meta, "lines": self.lines(),
                "wrapup": w["state"] if w else None, "edited": bool(w and w.get("edited"))}

    # The wrap-up lives beside the transcript: the model's draft and, kept
    # apart from it, whatever Chris changed, so a redraft never quietly
    # throws his edits away.
    def wrapup(self):
        path = self.folder / "wrapup.json"
        if not hasattr(self, "_wrapup"):
            self._wrapup = json.loads(path.read_text()) if path.exists() else None
        return self._wrapup

    def save_wrapup(self, w):
        self._wrapup = w
        self.folder.mkdir(parents=True, exist_ok=True)
        tmp = self.folder / "wrapup.json.tmp"
        tmp.write_text(json.dumps(w, indent=1))
        tmp.replace(self.folder / "wrapup.json")

    def takeaways(self):
        path = self.folder / "takeaways.json"
        return json.loads(path.read_text()) if path.exists() else None

    def save_takeaways(self, t):
        self.folder.mkdir(parents=True, exist_ok=True)
        tmp = self.folder / "takeaways.json.tmp"
        tmp.write_text(json.dumps(t, indent=1))
        tmp.replace(self.folder / "takeaways.json")

    def notes(self):
        """The wrap-up as it stands: Chris's edits if he made any, else the draft."""
        w = self.wrapup()
        return (w.get("edited") or w.get("draft")) if w else None

    def save(self):
        # Written beside and renamed over, so a crash never leaves half a file.
        # The folder is made with the first line or the first edit, so a meeting
        # nobody spoke in leaves nothing behind.
        self.folder.mkdir(parents=True, exist_ok=True)
        tmp = self.folder / "meta.json.tmp"
        tmp.write_text(json.dumps(self.meta, indent=1))
        tmp.replace(self.folder / "meta.json")

    def append(self, seg):
        seg["id"] = len(self.segments)
        self.segments.append(seg)
        if not self.log:
            self.save()
            self.log = (self.folder / "transcript.jsonl").open("a")
        self.log.write(json.dumps(seg) + "\n")
        self.log.flush()
        return seg

    def close(self):
        if self.log:
            self.log.close()
            self.log = None


def ad_hoc_title(t=None):
    return "Call at " + datetime.fromtimestamp(t or time.time()).strftime("%-H:%M")


class Sidecar:
    def __init__(self):
        self.recognizer = make_recognizer()
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)  # one recognizer, one decoder thread
        # Voiceprints on a thread of their own, so they never hold up a line's words.
        self.voice_pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        self.voice_ext = voices.Extractor()
        self.voice_sets = {}  # meeting id -> voices.Voices
        self.pending_me = []  # held briefly so speaker echo of "Them" can be dropped
        self.clients = set()
        self.previewers = set()
        self.echo_skips = 0  # clients that show the live preview (the app, the web view)
        self.channels = []
        self.tasks = []
        self.listening = False
        self.listening_since = 0  # when listening last started, for dead air
        self.asked_quiet = False
        self.current = None  # the meeting that's live or paused, if any
        MEETINGS.mkdir(parents=True, exist_ok=True)
        self.meetings = {}
        for meta in sorted(MEETINGS.glob("*/meta.json")):
            m = Meeting.load(meta.parent)
            self.meetings[m.id] = m
        self.recover()
        self.notion = Notion()
        self.drafting = {}  # meeting id -> task
        self.sending = {}
        for m in list(self.meetings.values()):  # short ones from before the rule
            if self.too_short(m):
                print(f"short: {m.id} ({m.lines()} lines) goes to the trash folder", flush=True)
                self.delete_meeting(m)
        self.bulk = {"running": False}  # Send all, as it goes
        self.syncing = asyncio.Lock()  # one pass over the Follow-ups database at a time
        self.settings = {**DEFAULTS, **(json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {})}
        self.call = None  # {"app", "since"} while another app holds the mic
        self.pending = None  # what's waiting to happen by itself: the call's meeting ending, a switch
        self.agenda = agenda.Calendar()
        self.offered = set()  # calendar events already switched to (or passed over), each once
        self.watch = calls.CallWatch(lambda: [c.pid for c in self.channels if c.pid],
                                     self.call_started, self.call_ended, self.sounds_like_call)

    def recover(self):
        """A meeting left live by a crash or a reboot comes back paused if it
        was recent, and is ended (at its last line) if it wasn't."""
        self.interrupted = []
        for m in self.meetings.values():
            w = m.wrapup()
            if w and w["state"] == "drafting":  # the engine stopped part way through: draft it again
                w.update(state="failed", error="Drafting was interrupted. Try again.")
                m.save_wrapup(w)
                self.interrupted.append(m)
            if m.meta["state"] == "ended":
                continue
            if self.current is None and time.time() - m.last_line_end() < RECOVER_WINDOW:
                m.meta["state"] = "paused"
                m.meta["recovered"] = True  # a call still going picks it back up
                self.current = m
            else:
                m.meta["state"] = "ended"
                m.meta["ended"] = m.last_line_end()
            m.save()

    # ---- meetings ----

    def too_short(self, m):
        """An ended meeting with only a few lines, that Chris did nothing
        with: no note or mark of his own, no wrap-up, nothing in Notion."""
        return (m.meta["state"] == "ended" and m is not self.current and m.lines() < wrapup.MIN_LINES
                and not m.wrapup() and not m.meta.get("notion")
                and not any(s["speaker"] in OWN for s in m.segments))

    def listing(self):
        return sorted((m.summary() for m in self.meetings.values()), key=lambda s: s["started"], reverse=True)

    def announce(self, m):
        self.broadcast({"type": "meeting", "meeting": m.summary()})

    def state(self):
        return {"type": "state", "listening": self.listening,
                "current": self.current.id if self.current else None,
                "channels": [{"label": c.label, "speaker": c.speaker} for c in self.channels],
                "call": self.call, "settings": self.settings, "to_wrap_up": self.to_wrap_up(),
                "followups_open": self.open_followups(), "bulk": self.bulk}

    def to_wrap_up(self):
        """Meetings from the last week still to wrap up, for the bar."""
        week = time.time() - 7 * 86400
        return sum(1 for m in self.meetings.values()
                   if m.meta["state"] == "ended" and m.meta["started"] > week and not m.meta.get("skipped")
                   and (m.meta.get("notion") or {}).get("state") != "sent" and m.lines() > 0)

    def set_settings(self, changes):
        for key in DEFAULTS:
            if key in changes:
                self.settings[key] = type(DEFAULTS[key])(changes[key])
        SETTINGS.parent.mkdir(parents=True, exist_ok=True)
        tmp = SETTINGS.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.settings, indent=1))
        tmp.replace(SETTINGS)
        self.broadcast(self.state())

    # ---- noticing calls ----

    async def call_started(self, app):
        """Another app took the mic. If Sidecar isn't already listening, it
        starts straight away, so the opening of the call is never lost. It
        says nothing: the bar shows it's recording. A call that wasn't worth
        keeping is deleted afterwards (and a few lines go by themselves)."""
        self.call = {"app": app, "since": time.time()}
        self.broadcast(self.state())
        if self.listening or not self.settings["watch_calls"]:
            return
        self.later(self.auto_listen())

    def used_events(self):
        """Calendar meetings a finished recording already had: done with."""
        return {(m.meta.get("event") or {}).get("id") for m in self.meetings.values() if m.meta["state"] == "ended"}

    async def sounds_like_call(self, app):
        """A call app is playing sound but nothing has the mic: joined muted,
        or a video. It's a call when the calendar says one is starting now
        (and hasn't been had), or a call window names one of today's."""
        if self.listening or not self.settings["watch_calls"]:
            return False
        seen = await calls.context()
        used = self.used_events()
        return bool(self.agenda.matching(seen.get("title"), used=used)
                    or (seen.get("app") and self.agenda.happening(used=used)))

    async def call_ended(self, app):
        """The call let go of the mic. A meeting that's listening ends by
        itself half a minute later."""
        self.call = None
        self.broadcast(self.state())
        if self.listening and self.current:
            self.later(self.end_after_call(self.current))
        else:
            self.later(None)

    def later(self, coro):
        """One thing waits to happen by itself at a time; a newer one (the
        call coming back, the next meeting) takes the older one's place."""
        if self.pending:
            self.pending.cancel()
        self.pending = asyncio.create_task(coro) if coro else None

    async def auto_listen(self):
        m = self.current
        if m and m.meta.get("recovered"):
            # The engine restarted mid-call: the call is the same meeting.
            m.meta.pop("recovered", None)
            await self.set_listening(True)
        else:
            await self.start_meeting()

    # ---- the calendar ----

    async def follow_calendar(self):
        """Keeps today's meetings fresh (they name a call when it starts), and
        moves on to the next one when it begins while a meeting that's over
        is still being heard."""
        while True:
            try:
                if self.agenda.due():
                    await self.agenda.refresh()
                now = time.time()
                for e in self.agenda.begun(now):
                    if not (self.listening and self.current) or ("switch", e["id"]) in self.offered:
                        continue
                    on = self.current.meta.get("event") or {}
                    self.offered.add(("switch", e["id"]))
                    if on.get("id") == e["id"]:
                        continue
                    # Only when the meeting being heard is over (or about to be)
                    # does the next one take over; overlapping or unplanned,
                    # the one he's in carries on.
                    over = bool(on) and on.get("end", 0) - e["t0"] <= agenda.SLACK
                    if over:
                        self.later(self.switch_to(self.current, e))
            except Exception as e:  # the calendar is a nicety; it never takes the engine down
                print(f"calendar: {e}", file=sys.stderr, flush=True)
            await asyncio.sleep(20)

    async def switch_to(self, m, e):
        """The next calendar meeting has begun and the one being heard is
        over: a minute's grace for goodbyes, then the new one starts."""
        await asyncio.sleep(SWITCH_AFTER)
        if self.current is m and self.listening:
            await self.start_meeting(event=agenda.event_meta(e))

    async def end_after_call(self, m):
        # The half minute runs its course, and again for as long as the
        # other side is still being heard, since a mute or a headset switch
        # can look like the call ending.
        asked = time.time()
        await asyncio.sleep(END_AFTER)
        while self.current is m and self.listening and not self.call and self.heard_them_since(m, asked):
            asked = time.time()
            await asyncio.sleep(END_AFTER)
        if self.current is not m or self.call or not self.listening:
            return  # something else happened meanwhile: another call, a pause, or it ended already
        await self.end_meeting()

    @staticmethod
    def heard_them_since(m, t):
        return any(s["speaker"] not in (ME, *OWN) and s["start"] >= t for s in m.segments[-20:])

    async def start_meeting(self, title=None, event=None):
        """Starts a meeting, ending the one that's on. With no title or
        event, the calendar meeting that's on (or about to be) names it."""
        await self.end_meeting()
        # A new meeting leaves nothing of the last one waiting to happen;
        # the one doing the starting mustn't cancel itself.
        if self.pending and asyncio.current_task() is not self.pending:
            self.later(None)
        event = agenda.normalize(event)
        # Unnamed: the call app's window says which meeting it is (matched to
        # the calendar when it can be), else the calendar's meeting on now,
        # else the window's own name for it, else the app and the time.
        seen = {}
        if not title and not event:
            seen = await calls.context() if self.call else {}
            used = self.used_events()
            on = self.agenda.matching(seen.get("title"), used=used) or self.agenda.happening(used=used)
            event = agenda.event_meta(on) if on else None
        if not title and not event and seen.get("title"):
            title = seen["title"]
        app = seen.get("app") or (self.call or {}).get("app")
        if not title and not event and app in calls.CALL_APPS:
            title = f"{app} call at {datetime.now():%-I:%M}"
        m = Meeting.create(title or (event or {}).get("subject") or ad_hoc_title(), event)
        m.meta["people"] = agenda.people(event, ME)
        self.meetings[m.id] = m
        self.current = m
        self.announce(m)
        await self.set_listening(True)
        return m

    async def end_meeting(self):
        """Ends the meeting that's on. One that was actually talked in gets
        its wrap-up drafted straight away, so it's ready by the time Chris
        looks; one ended by recovery at startup never does."""
        if not self.current:
            return None
        await self.set_listening(False)
        m, self.current = self.current, None
        m.meta["state"] = "ended"
        m.meta["ended"] = time.time()
        m.close()
        if m.lines() or (m.folder / "meta.json").exists():
            m.save()
        else:
            del self.meetings[m.id]  # nobody spoke: it never happened
            self.broadcast({"type": "meeting_removed", "id": m.id})
            self.broadcast(self.state())
            return None
        if self.too_short(m):  # a few lines, nothing of Chris's: not a meeting
            print(f"short: {m.id} ({m.lines()} lines) goes to the trash folder", flush=True)
            self.delete_meeting(m)
            self.broadcast(self.state())
            return None
        self.announce(m)
        self.broadcast(self.state())
        if m.lines() >= wrapup.MIN_LINES and not m.wrapup():
            self.draft(m)
        return m

    async def resume_meeting(self, m):
        """Carries on with an ended meeting, for one ended by mistake."""
        if self.current is m:
            await self.set_listening(True)
            return m
        await self.end_meeting()
        m.meta["state"] = "paused"
        m.meta["ended"] = None
        self.current = m
        await self.set_listening(True)
        return m

    def merge_meetings(self, a, b):
        """Two meetings that were one call (split by a restart, a dropped
        line, a pause too long): the earlier one keeps its title and gets
        both transcripts in time order, the other goes to the trash, and the
        wrap-up is drafted again over the whole of it, keeping any edits."""
        if a is b or self.current in (a, b) or a.id in self.sending or b.id in self.sending:
            return None
        keep, other = sorted((a, b), key=lambda m: m.meta["started"])
        for m in (keep, other):
            task = self.drafting.pop(m.id, None)
            if task:
                task.cancel()
        # The other meeting's voices are numbered after this one's: its voice 1
        # isn't this one's voice 1. Their voiceprints and names come along.
        kv, ov = voices.Voices(keep.folder), voices.Voices(other.folder)
        offset = max([len(kv.centroids)] + [s.get("voice") or 0 for s in keep.segments])
        theirs = [dict(s, voice=s["voice"] + offset) if s.get("voice") else s for s in other.segments]
        if ov.centroids:
            kv.centroids += ov.centroids
            kv.counts += ov.counts
            kv.save()
        for v, name in (other.meta.get("voices") or {}).items():
            keep.meta.setdefault("voices", {})[str(int(v) + offset)] = name
        self.voice_sets.pop(keep.id, None)
        self.voice_sets.pop(other.id, None)
        tagged = [(s, True) for s in keep.segments] + [(s, False) for s in theirs]
        tagged.sort(key=lambda x: x[0]["start"])
        remap, merged = {}, []
        for i, (s, ours) in enumerate(tagged):
            if ours:
                remap[s.get("id", i)] = i
            merged.append({**s, "id": i})
        keep.close()
        keep.folder.mkdir(parents=True, exist_ok=True)
        tmp = keep.folder / "transcript.jsonl.tmp"
        tmp.write_text("".join(json.dumps(s) + "\n" for s in merged))
        tmp.replace(keep.folder / "transcript.jsonl")
        keep._segments = merged

        def moved(o):  # a wrap-up's line numbers follow the lines they point at
            if isinstance(o, dict):
                return {k: (remap.get(v, v) if k == "at" and isinstance(v, int) and v >= 0 else moved(v)) for k, v in o.items()}
            return [moved(x) for x in o] if isinstance(o, list) else o
        w = keep.wrapup()
        if w:
            if w.get("state") == "drafting":
                w.update(state="failed", error="Merged while drafting.")
            keep.save_wrapup(moved(w))
        meta = keep.meta
        meta["ended"] = max(x for x in (meta.get("ended"), other.meta.get("ended")) if x) if (meta.get("ended") or other.meta.get("ended")) else None
        meta["people"] = list(dict.fromkeys((meta.get("people") or []) + (other.meta.get("people") or [])))
        meta["event"] = meta.get("event") or other.meta.get("event")
        meta["merged"] = (meta.get("merged") or []) + [{"id": other.id, "title": other.meta["title"]}]
        keep.save()
        self.delete_meeting(other)
        self.announce(keep)
        self.broadcast(self.state())
        if (meta.get("notion") or {}).get("state") != "sent" and keep.lines() >= wrapup.MIN_LINES:
            self.draft(keep)
        return keep

    def delete_meeting(self, m):
        """Moves a meeting to the trash folder. The one that's on can't go."""
        if m is self.current or m.id in self.sending:
            return False
        task = self.drafting.pop(m.id, None)
        if task:
            task.cancel()
        m.close()
        if m.folder.exists():
            TRASH.mkdir(parents=True, exist_ok=True)
            dest = TRASH / m.id
            n = 2
            while dest.exists():
                dest = TRASH / f"{m.id}-{n}"
                n += 1
            m.folder.rename(dest)
        del self.meetings[m.id]
        self.broadcast({"type": "meeting_removed", "id": m.id})
        return True

    # ---- the wrap-up ----

    def announce_wrapup(self, m):
        self.broadcast({"type": "wrapup", "id": m.id, "wrapup": m.wrapup()})
        self.announce(m)

    def draft(self, m, replace=False):
        """Starts drafting the wrap-up in the background. Edits survive a
        redraft unless replace says to drop them."""
        if m.id in self.drafting:
            return
        w = dict(m.wrapup() or {"draft": None, "edited": None})
        w.update(state="drafting", error=None, started=time.time())
        if replace:
            w["edited"] = None
        m.save_wrapup(w)
        self.announce_wrapup(m)
        self.drafting[m.id] = asyncio.create_task(self._draft(m))

    async def _draft(self, m):
        try:
            try:
                options = await self.notion.options()
            except NotionError:
                options = {}  # drafts fine without Notion; just no names or tags
            notes = await wrapup.draft(ME, m.meta, self.labelled(m), options)
            w = m.wrapup()
            w.update(state="ready", error=None, draft=notes, drafted=time.time(), lines=m.lines(),
                     model=wrapup.MODEL)
        except asyncio.CancelledError:
            raise
        except Exception as e:  # anything at all lands on screen, not in a log
            w = m.wrapup()
            w.update(state="failed" if not w.get("draft") else "ready", error=str(e) or type(e).__name__)
        finally:
            self.drafting.pop(m.id, None)
        if m.id in self.meetings:
            m.save_wrapup(w)
            self.announce_wrapup(m)

    def edit_wrapup(self, m, edited, tick=True):
        """Saves Chris's version of the wrap-up. What the engine keeps on each
        follow-up (its Notion to-do, when it was ticked) survives a save from
        a window that didn't have it yet, and a follow-up ticked or flagged
        here is ticked or flagged in Notion too. tick says where a change is
        pushed: True everywhere, False nowhere, "todo" or "row" only there
        (when it came from the other one)."""
        w = dict(m.wrapup() or {"state": "ready", "draft": None})
        old = (m.notes() or {}).get("mine", [])
        if edited:
            edited = {**wrapup.EMPTY, **json.loads(json.dumps(edited))}
            same_count = len(edited["mine"]) == len(old)
            for i, item in enumerate(edited["mine"]):
                before = old[i] if i < len(old) and old[i].get("text") == item.get("text") else \
                    next((o for o in old if o.get("text") == item.get("text")), None)
                if not before and same_count and i < len(old):
                    before = old[i]  # its text was edited; it's still the same to-do
                if not before:
                    continue
                for key in ("notion", "row", "flagged", "done_at"):
                    if key in before and key not in item:
                        item[key] = before[key]
                ticked = bool(item.get("done")) != bool(before.get("done"))
                flagged = bool(item.get("flagged")) != bool(before.get("flagged"))
                if ticked:
                    item["done_at"] = time.time() if item.get("done") else None
                    if tick in (True, "todo") and item.get("notion"):
                        asyncio.create_task(self._tick(m, i, item["notion"], bool(item.get("done"))))
                if (ticked or flagged) and tick in (True, "row") and item.get("row"):
                    asyncio.create_task(self._push_row(m, i, item["row"]))
            # Taken out (fewer than before, and its to-do or row isn't kept by
            # any that remain): it comes off Notion too.
            if tick and len(edited["mine"]) < len(old):
                todos = {i.get("notion") for i in edited["mine"]}
                kept = {i.get("row") for i in edited["mine"]}
                for o in old:
                    if tick in (True, "todo") and o.get("notion") and o["notion"] not in todos:
                        asyncio.create_task(self._remove_todo(o["notion"]))
                    if tick in (True, "row") and o.get("row") and o["row"] not in kept:
                        asyncio.create_task(self._remove_row(o["row"]))
        w["edited"] = edited or None
        if w["state"] == "failed" and edited:
            w["state"] = "ready"
        m.save_wrapup(w)
        self.announce_wrapup(m)
        self.broadcast({"type": "followups"})

    # ---- the follow-up email ----

    def set_email(self, m, **changes):
        w = dict(m.wrapup() or {"state": "ready", "draft": None, "edited": None})
        w["email"] = {**(w.get("email") or {}), **changes}
        m.save_wrapup(w)
        self.announce_wrapup(m)

    def write_email(self, m):
        if not m.notes() or (m.wrapup().get("email") or {}).get("state") == "writing":
            return False
        self.set_email(m, state="writing", error=None, to=mailer.recipients(m.meta), cc=[])
        asyncio.create_task(self._write_email(m))
        return True

    async def _write_email(self, m):
        try:
            mail = await mailer.write(m.meta, m.notes())
            self.set_email(m, state="ready", subject=mail["subject"], body=mail["body"], written=time.time())
        except Exception as e:
            self.set_email(m, state="failed", error=str(e) or type(e).__name__)

    async def save_email(self, m):
        e = (m.wrapup() or {}).get("email") or {}
        self.set_email(m, state="saving", error=None)
        try:
            await mailer.save_draft(e.get("to") or [], e.get("cc") or [], e.get("subject", ""), e.get("body", ""))
            self.set_email(m, state="saved", saved=time.time())
        except Exception as err:
            self.set_email(m, state="ready", error=str(err) or type(err).__name__)

    async def fill_ins(self, m):
        """Pages already in My Meetings from that day that this meeting could
        fill in (something else files meetings there too), less Sidecar's own."""
        pages = await self.notion.candidates(m.meta)
        ours = {(o.meta.get("notion") or {}).get("id", "").replace("-", "") for o in self.meetings.values()}
        return [p for p in pages if p["id"].replace("-", "") not in ours]

    async def finish(self, m, email=True):
        """Filed in Notion as a new page and, unless email is False, the
        follow-up email written (unless it already is) and saved to Outlook
        Drafts. Never sent. Each part reports as it does on its own. When
        there's already a page from that day it could fill in, the page is
        left to Chris to choose ("choose"); the email still goes ahead."""
        if not m.notes():
            return None
        started = {"notion": False, "email": False}
        if (m.meta.get("notion") or {}).get("state") != "sent" and m.id not in self.sending:
            try:
                pages = await self.fill_ins(m)
            except Exception:
                pages = []  # Notion unreachable: the send reports that itself
            started["notion"] = "choose" if pages else self.send(m)
        e = (m.wrapup() or {}).get("email") or {}
        if email and e.get("state") not in ("saved", "saving", "writing"):
            asyncio.create_task(self._finish_email(m))
            started["email"] = True
        return started

    async def _finish_email(self, m):
        if ((m.wrapup() or {}).get("email") or {}).get("state") != "ready":
            self.set_email(m, state="writing", error=None, to=mailer.recipients(m.meta), cc=[])
            await self._write_email(m)
        if ((m.wrapup() or {}).get("email") or {}).get("state") == "ready":
            await self.save_email(m)

    def send_all(self, ids):
        """Files the meetings Chris was shown, one at a time in the background.
        Returns how many it took on. Takes only what a single Send would."""
        if self.bulk.get("running"):
            return None
        todo = [m for m in (self.meetings.get(i) for i in ids) if m and self.sendable(m)]
        if todo:
            self.set_bulk(running=True, total=len(todo), done=0, failed=0, choose=[], ids=[m.id for m in todo],
                          current=None, sent=[], failures=[], finished=None)
            asyncio.create_task(self._send_all(todo))
        return len(todo)

    def sendable(self, m):
        s = m.summary()
        return (s.get("state") == "ended" and s["wrapup"] == "ready" and not s.get("skipped") and m.notes()
                and (m.meta.get("notion") or {}).get("state") not in ("sent", "sending") and m.id not in self.sending)

    def set_bulk(self, **changes):
        self.bulk = {**self.bulk, **changes}
        self.broadcast({"type": "bulk", "bulk": self.bulk})

    async def _send_all(self, todo):
        """In turn, so hundreds of block appends don't pile on Notion's rate
        limit, and so each page is on file before the next meeting looks for
        pages from its day. A page that could be this meeting is left for
        Chris to pick: nothing merges, or duplicates, by guessing."""
        done, failed, choose = 0, 0, []
        sent, failures = [], []  # which ones, for the window's progress bar and cards
        for m in todo:
            self.set_bulk(current=m.id)
            try:
                # One that failed part way has its page and carries on with it.
                fresh = not (m.meta.get("notion") or {}).get("id")
                if fresh and await self.fill_ins(m):
                    choose.append(m.id)
                elif self.send(m):
                    await self.sending[m.id]
                    if (m.meta.get("notion") or {}).get("state") == "sent":
                        done += 1
                        sent.append(m.id)
                    else:
                        failed += 1
                        failures.append({"id": m.id, "error": (m.meta.get("notion") or {}).get("error", "")})
                else:  # nothing to send after all: say so rather than skip it silently
                    failed += 1
                    failures.append({"id": m.id, "error": "Nothing to send, or it's already sending."})
            except Exception as e:  # Notion unreachable: nothing filed unchecked
                print(f"bulk send: {m.id}: {e}", file=sys.stderr, flush=True)
                failed += 1
                failures.append({"id": m.id, "error": str(e) or type(e).__name__})
            self.set_bulk(done=done, failed=failed, choose=choose, sent=sent, failures=failures)
        print(f"bulk send: {done} sent, {failed} failed, {len(choose)} to pick a page for", flush=True)
        self.set_bulk(running=False, current=None, finished=time.time())

    def send(self, m, target=None):
        """Starts filing the meeting in Notion in the background."""
        if m.id in self.sending or not m.notes():
            return False
        def save(progress):
            m.meta["notion"] = progress
            m.save()
            self.announce(m)
        self.sending[m.id] = asyncio.create_task(self._send(m, target, save))
        progress = dict(m.meta.get("notion") or {})
        progress.update(state="sending", error=None)
        save(progress)
        return True

    async def _send(self, m, target, save):
        try:
            progress = await self.notion.send(m.meta, m.notes(), self.labelled(m), target, save)
            # Each follow-up remembers its to-do on the page, so ticking it off
            # in Sidecar ticks it off in Notion too.
            if progress.get("todos"):
                doc = json.loads(json.dumps(m.notes()))
                for i, block_id in progress["todos"].items():
                    if int(i) < len(doc["mine"]):
                        doc["mine"][int(i)]["notion"] = block_id
                self.edit_wrapup(m, doc)
            if progress.get("rows"):
                try:
                    async with self.syncing:
                        await self.add_rows(m, await notion.rows(self.notion))
                except NotionError as e:  # it's filed; the next sync adds them
                    print(f"notion: follow-ups for {m.id}: {e}", file=sys.stderr, flush=True)
        except Exception as e:
            progress = dict(m.meta.get("notion") or {})
            progress.update(state="failed", error=str(e) or type(e).__name__)
            save(progress)
        finally:
            self.sending.pop(m.id, None)

    # ---- dead air ----

    def quiet_for(self):
        """Seconds since anything was said in the meeting that's listening:
        its last line, or since listening started if it's said nothing yet."""
        m = self.current
        last = m.segments[-1]["end"] if m and m.segments else 0
        return time.time() - max(last, self.listening_since)

    async def watch_silence(self):
        """Listening to a room where nothing's being said: after five quiet
        minutes and three more, the meeting ends by itself, rather than
        leave the mic open on dead air."""
        while True:
            await asyncio.sleep(15)
            if not (self.listening and self.current and self.settings["stop_on_silence"]):
                continue
            if self.quiet_for() >= QUIET_ASK and not self.asked_quiet:
                self.asked_quiet = True
                self.later(self.end_if_quiet(self.current))

    async def end_if_quiet(self, m):
        heard = m.lines()
        await asyncio.sleep(QUIET_END)
        if self.current is not m or not self.listening:
            return
        if m.lines() == heard:
            await self.end_meeting()
        else:
            self.asked_quiet = False  # people started talking again

    # ---- takeaways while the call goes on ----

    async def follow_takeaways(self):
        """Keeps the live meeting's takeaways current: every couple of
        minutes, and only when something new has been said."""
        while True:
            await asyncio.sleep(20)
            m = self.current
            if not (m and self.listening and self.settings["live_takeaways"]):
                continue
            t = m.takeaways() or {"lines": 0, "updated": 0}
            if m.lines() - t["lines"] < takeaways.NEW_LINES or time.time() - t["updated"] < takeaways.EVERY:
                continue
            lines = m.lines()
            try:
                lists = await takeaways.update(ME, m.meta, self.labelled(m))
            except asyncio.CancelledError:
                raise
            except Exception as e:  # a missed update is fine; the next one catches up
                print(f"takeaways: {e}", file=sys.stderr, flush=True)
                t["updated"] = time.time()
                m.save_takeaways(t)
                continue
            lists["lookups"] = takeaways.merge_lookups(t.get("lookups"), lists.get("lookups"))
            self.guess_names(m, lists.pop("voices", []))
            t = {**lists, "lines": lines, "updated": time.time()}
            m.save_takeaways(t)
            self.broadcast({"type": "takeaways", "id": m.id, "takeaways": t})

    # ---- follow-ups: what Chris has to do, across every meeting ----

    # ---- voices: telling the other side apart ----

    def voices_on(self):
        return self.settings["speaker_names"] and self.voice_ext.available()

    async def voice_of(self, samples):
        """Which of the meeting's voices a line of theirs is in, or None when
        it's too short to tell (or voices are off, or anything goes wrong)."""
        m = self.current
        if not m or len(samples) < voices.MIN_SECONDS * voices.RATE:
            return None
        try:
            e = await asyncio.get_running_loop().run_in_executor(self.voice_pool, self.voice_ext.embed, samples)
            vs = self.voice_sets.get(m.id) or self.voice_sets.setdefault(m.id, voices.Voices(m.folder))
            voice, sim = vs.assign(e)
            # Numbers only, never words: for tuning the threshold on real calls.
            print(f"voice: {voice} of {len(vs.centroids)}, best match {sim if sim is None else round(sim, 3)}", file=sys.stderr, flush=True)
            return voice
        except Exception as err:
            print(f"voice: {err}", file=sys.stderr, flush=True)
            return None

    def guess_names(self, m, guesses):
        """Names the takeaways pass is sure of, for voices nobody named by hand."""
        names = m.meta.setdefault("voices", {})
        changed = False
        for g in guesses:
            key = str(g["voice"])
            if (names.get(key) or {}).get("by") != "hand" and (names.get(key) or {}).get("name") != g["name"].strip():
                names[key] = {"name": g["name"].strip(), "by": "guess"}
                changed = True
        if changed:
            m.save()
            self.announce(m)

    def labelled(self, m):
        """The meeting's lines with each voice's name (or "Voice 2") as the
        speaker, for what reads them: the wrap-up, the takeaways, Notion.
        The lines themselves keep "Them"."""
        names = m.meta.get("voices") or {}
        return [dict(s, speaker=voices.label(s, names)) if s.get("voice") else s for s in m.segments]

    def search(self, q, per=3, limit=40):
        """Meetings whose title or transcript has every word of q, newest
        first, each with its first few matching lines."""
        words = [w for w in q.lower().split() if w]
        if not words:
            return []
        out = []
        for m in sorted(self.meetings.values(), key=lambda m: m.meta["started"], reverse=True):
            title = all(w in m.meta["title"].lower() for w in words)
            hits = [s for s in m.segments if all(w in s["text"].lower() for w in words)]
            if title or hits:
                out.append({"id": m.id, "title": title, "count": len(hits),
                            "hits": [{"at": s.get("id", -1), "speaker": s["speaker"], "text": s["text"],
                                      "time": stamp(s["start"])} for s in hits[:per]]})
                if len(out) >= limit:
                    break
        return out

    def followups(self):
        out = []
        for m in self.meetings.values():
            notes = m.notes()
            if not notes or m.meta.get("skipped"):
                continue
            sent = (m.meta.get("notion") or {}).get("state") == "sent"
            for i, item in enumerate(notes.get("mine", [])):
                if not (item.get("text") or "").strip():
                    continue
                out.append({"meeting": m.id, "title": m.meta["title"], "started": m.meta["started"], "index": i,
                            "text": item["text"], "due": item.get("due", ""), "at": item.get("at", -1),
                            "done": bool(item.get("done")), "doneAt": item.get("done_at"),
                            "flagged": bool(item.get("flagged")),
                            "inNotion": sent and bool(item.get("notion") or item.get("row")),
                            "syncError": item.get("sync_error")})
        return sorted(out, key=lambda f: (-f["started"], f["index"]))  # newest meeting first

    def learned(self, days=30):
        """Home's other half: what the wrap-ups say, taken together."""
        return insights.learned(((m.meta, m.notes()) for m in self.meetings.values()), time.time(), days)

    def topic(self, name):
        return insights.topic(((m.meta, m.notes()) for m in self.meetings.values()), name, time.time())

    def open_followups(self):
        return sum(1 for f in self.followups() if not f["done"])

    def set_done(self, m, index, done, tick=True):
        """Ticks a follow-up off (or back on) in the meeting's wrap-up, and in
        Notion wherever tick says (see edit_wrapup)."""
        self.set_item(m, index, tick, done=bool(done))

    def set_flagged(self, m, index, flagged, tick=True):
        self.set_item(m, index, tick, flagged=bool(flagged))

    def set_item(self, m, index, tick, **changes):
        doc = json.loads(json.dumps(m.notes()))
        doc["mine"][index].update(changes)
        doc["mine"][index].pop("sync_error", None)
        self.edit_wrapup(m, doc, tick=tick)
        self.broadcast(self.state())

    def sync_failed(self, m, index, key, value, error):
        doc = json.loads(json.dumps(m.notes()))
        if index < len(doc["mine"]) and doc["mine"][index].get(key) == value:
            doc["mine"][index]["sync_error"] = str(error) or "Couldn't reach Notion"
            self.edit_wrapup(m, doc, tick=False)
            self.broadcast({"type": "followups"})

    async def _push_row(self, m, index, row_id):
        """Ticks and flags live together on the row, so both go each time, as
        they stand when this runs."""
        try:
            item = m.notes()["mine"][index]
            await notion.set_row(self.notion, row_id, item.get("done"), item.get("flagged"))
        except Exception as e:
            self.sync_failed(m, index, "row", row_id, e)

    async def _tick(self, m, index, block_id, done):
        try:
            await notion.tick(self.notion, block_id, done)
        except Exception as e:
            self.sync_failed(m, index, "notion", block_id, e)

    def brief(self, m, keep=3, days=90):
        """What Sidecar already knows going into a meeting, from meetings
        before it: the same series (same calendar subject) or the same
        people. Their gist, what Chris still owes from them, and what the
        others said they'd do. No model call: it's only what's on file."""
        def norm(t):
            return " ".join((t or "").lower().split())
        subject = norm((m.meta.get("event") or {}).get("subject"))
        people = {norm(p) for p in (m.meta.get("people") or []) if p}
        related = []
        for o in self.meetings.values():
            if o is m or o.meta["state"] != "ended" or o.meta["started"] >= m.meta["started"] \
                    or o.meta["started"] < m.meta["started"] - days * 86400 or not o.notes():
                continue
            same = subject and norm((o.meta.get("event") or {}).get("subject") or o.meta["title"]) == subject
            shared = sorted(p for p in (o.meta.get("people") or []) if norm(p) in people)
            if same or shared:
                related.append((o, bool(same), shared))
        related.sort(key=lambda r: r[0].meta["started"], reverse=True)
        related = related[:keep]
        out = {"related": [], "mine": [], "theirs": []}
        for o, same, shared in related:
            notes = o.notes()
            out["related"].append({"id": o.id, "title": o.meta["title"], "started": o.meta["started"],
                                   "tldr": notes.get("tldr", ""), "series": same, "shared": shared})
            out["mine"] += [{"meeting": o.id, "index": i, "text": it["text"], "due": it.get("due", "")}
                            for i, it in enumerate(notes.get("mine", [])) if it.get("text") and not it.get("done")]
            out["theirs"] += [{"meeting": o.id, "who": it.get("who", ""), "text": it["text"], "due": it.get("due", "")}
                              for it in notes.get("theirs", []) if it.get("text")]
        return out

    def remove_followup(self, m, index):
        """Takes a follow-up out of the meeting's wrap-up altogether (not done:
        gone), and out of Notion."""
        doc = json.loads(json.dumps(m.notes()))
        del doc["mine"][index]
        self.edit_wrapup(m, doc)
        self.broadcast(self.state())

    async def _remove_todo(self, block_id):
        try:
            await notion.remove(self.notion, block_id)
        except Exception as e:
            print(f"notion: couldn't remove to-do {block_id}: {e}", file=sys.stderr, flush=True)

    async def _remove_row(self, row_id):
        try:
            await notion.remove_row(self.notion, row_id)
        except Exception as e:
            print(f"notion: couldn't remove follow-up {row_id}: {e}", file=sys.stderr, flush=True)

    async def add_rows(self, m, existing):
        """Gives a filed meeting's follow-ups their rows. Each id is saved as
        it's made, and a row already there for this meeting with the same
        words is taken up rather than made again, so being cut off or redrafted
        never leaves a second row. Returns how many it made."""
        n = m.meta.get("notion") or {}
        page = n.get("id", "").replace("-", "")
        made = 0
        taken = {i.get("row") for i in m.notes()["mine"]}
        for index, item in enumerate(m.notes()["mine"]):
            if item.get("row") or not (item.get("text") or "").strip():
                continue
            row = next((r for r, v in existing.items() if r not in taken and page in v["meeting"]
                        and v["text"].strip() == item["text"].strip()), None)
            if not row:
                row = await notion.add_row(self.notion, item, n["id"], m.meta["started"])
                existing[row] = {"text": item["text"], "done": bool(item.get("done")),
                                 "flagged": bool(item.get("flagged")), "meeting": [page]}
                made += 1
            taken.add(row)
            doc = json.loads(json.dumps(m.notes()))
            doc["mine"][index]["row"] = row
            self.edit_wrapup(m, doc, tick=False)
        return made

    async def pull_rows(self):
        """The Follow-ups database, both ways: every filed follow-up has its
        row, and ticks, flags and deletions made there come back. A follow-up
        whose last push failed goes up again instead. Returns what changed,
        what's gone, and which follow-ups the row has just decided, so an old
        to-do that hasn't caught up doesn't undo them."""
        changed, gone, settled = 0, [], set()
        if not await notion.followups_ready(self.notion):
            return changed, gone, settled
        existing = await notion.rows(self.notion)
        for m in list(self.meetings.values()):
            n = m.meta.get("notion") or {}
            if n.get("state") != "sent" or not n.get("id") or not m.notes() or m.id in self.sending:
                continue
            changed += await self.add_rows(m, existing)
            for index, item in enumerate(m.notes().get("mine", [])):
                if not item.get("row"):
                    continue
                row = existing.get(item["row"])
                if row is None:
                    if await notion.row_gone(self.notion, item["row"]):
                        gone.append((m, index))
                elif item.get("sync_error"):
                    settled.add((m.id, index))
                    try:
                        await notion.set_row(self.notion, item["row"], item.get("done"), item.get("flagged"))
                        self.set_item(m, index, False)
                    except NotionError:
                        pass  # still marked; the next sync tries again
                else:
                    if row["done"] != bool(item.get("done")):
                        settled.add((m.id, index))
                        self.set_done(m, index, row["done"], tick="todo")
                        changed += 1
                    if row["flagged"] != bool(item.get("flagged")):
                        self.set_flagged(m, index, row["flagged"], tick="todo")
                        changed += 1
        return changed, gone, settled

    async def link_todos(self):
        """Meetings sent before follow-ups knew their to-dos: find each one's
        to-do on the page by its text. Only reads from Notion."""
        for m in list(self.meetings.values()):
            n = m.meta.get("notion") or {}
            notes = m.notes()
            if n.get("state") != "sent" or not notes or all(i.get("notion") or i.get("row") for i in notes.get("mine", [])):
                continue
            todos = await notion.todos_on(self.notion, n["id"])
            doc = json.loads(json.dumps(notes))
            used = {i.get("notion") for i in doc["mine"]}
            for item in doc["mine"]:
                if item.get("notion"):
                    continue
                want = item["text"] + (f" ({item['due']})" if item.get("due") else "")
                match = next((t for t in todos if t[0] not in used and t[1].strip() in (want.strip(), item["text"].strip())), None)
                if match:
                    item["notion"] = match[0]
                    used.add(match[0])
            self.edit_wrapup(m, doc, tick=False)

    async def pull_ticks(self):
        """What changed in Notion comes back to Sidecar."""
        async with self.syncing:
            await self.link_todos()
            changed, gone, settled = await self.pull_rows()
            # The to-dos on pages sent before the database. A row that changed
            # just now has already said what's true.
            before = len(gone)
            for f in self.followups():
                if not f["inNotion"]:
                    continue
                m = self.meetings[f["meeting"]]
                block_id = m.notes()["mine"][f["index"]].get("notion")
                if not block_id:
                    continue
                state = await notion.ticked(self.notion, block_id)
                if state == notion.GONE:
                    if (m, f["index"]) not in gone:
                        gone.append((m, f["index"]))
                elif state is not None and state != f["done"] and (m.id, f["index"]) not in settled:
                    self.set_done(m, f["index"], state, tick="row")
                    changed += 1
            # Deleted in Notion: gone here too and from whichever of its row
            # and to-do is left, last first so the indexes hold.
            for at, (m, index) in sorted(enumerate(gone), key=lambda g: (g[1][0].id, -g[1][1])):
                doc = json.loads(json.dumps(m.notes()))
                del doc["mine"][index]
                self.edit_wrapup(m, doc, tick="todo" if at < before else "row")
                changed += 1
        if gone:
            self.broadcast(self.state())
        return changed

    def update_meeting(self, m, changes):
        for key in ("title", "people", "skipped"):
            if key in changes:
                m.meta[key] = changes[key]
        # Names for voices: {"2": "Hector"} names voice 2 by hand (a hand
        # always beats a guess); an empty name clears it.
        for v, name in (changes.get("voices") or {}).items():
            names = m.meta.setdefault("voices", {})
            if name:
                names[str(v)] = {"name": str(name).strip(), "by": "hand"}
            else:
                names.pop(str(v), None)
        m.save()
        self.announce(m)

    async def set_listening(self, on):
        if on and not self.current:
            await self.start_meeting()  # listening always belongs to a meeting
            return
        if on == self.listening:
            return
        self.listening = on
        if on:
            # Outputs are found afresh each time, so a display plugged in since
            # the last call is heard too.
            self.channels = [Channel(self, ME, "@DEFAULT_SOURCE@", "Mic")]
            displays = []
            for sink in sinks():
                self.channels.append(Channel(self, "Them", sink + ".monitor", label_for(sink, displays)))
            self.tasks = [asyncio.create_task(c.run()) for c in self.channels]
            self.listening_since = time.time()
            self.asked_quiet = False
            self.current.meta["state"] = "live"
        else:
            for t in self.tasks:
                t.cancel()
            await asyncio.gather(*self.tasks, return_exceptions=True)
            self.tasks, self.channels = [], []
            for m in self.pending_me:
                self.commit(m)
            self.pending_me = []
            if self.current:
                self.current.meta["state"] = "paused"
        if self.current:
            if (self.current.folder / "meta.json").exists():
                self.current.save()
            self.announce(self.current)
        self.broadcast(self.state())

    # ---- transcript ----

    def decode(self, samples):
        s = self.recognizer.create_stream()
        s.accept_waveform(RATE, samples)
        self.recognizer.decode_stream(s)
        return s.result.text.strip()

    def broadcast(self, msg):
        data = json.dumps(msg)
        for q in list(self.clients):
            if q.qsize() < 1000:
                q.put_nowait(data)

    def add_note(self, m, kind, text=""):
        """A note Chris typed, or a mark on the moment, into a meeting's
        transcript: now for the meeting that's on, or at its end for one
        that's over."""
        t = time.time() if m is self.current else m.last_line_end()
        seg = m.append({"speaker": kind, "start": t, "end": t, "text": text.strip() or "Marked this moment"})
        if m is not self.current:
            m.close()
        self.broadcast(self.segment_event(seg, m.id))
        self.announce(m)
        return seg

    def segment_event(self, seg, meeting):
        return {"type": "segment", **seg, "meeting": meeting, "time": stamp(seg["start"])}

    def them_speaking(self):
        return any(c.speaking for c in self.channels if c.speaker != ME)

    def heard_through_room(self, mic, seconds):
        """Whether a mic line that just ended is a speaker output picked up by
        the mic, judged on loudness alone so it costs no decode. The window
        covers the line plus the silence the VAD waited for after it."""
        if seconds * 10 < ECHO_MIN_FRAMES:
            return False
        since = time.time() - seconds - 0.8
        mine = mic.loudness_since(since)
        for c in self.channels:
            if c.speaker == ME:
                continue
            score = echo_score(mine, c.loudness_since(since))
            if score >= ECHO_CORR:
                self.echo_skips += 1
                print(f"echo: skipped a {seconds:.1f}s mic line, follows {c.label} at {score:.2f}", flush=True)
                return True
        return False

    def add_segment(self, speaker, start, end, text, voice=None):
        seg = {"speaker": speaker, "start": start, "end": end, "text": text}
        if voice:
            seg["voice"] = voice
        if speaker == ME:
            # Speakers bleeding into the mic: the "Them" line may already be in,
            # or may still be decoding, so check now and again until the hold ends.
            recent = [s for s in (self.current.segments[-8:] if self.current else []) if s["speaker"] not in (ME, *OWN)]
            if any(overlaps(seg, s) and similar(seg["text"], s["text"]) for s in recent):
                self.broadcast({"type": "echo_dropped", "text": text})
                return
            seg["hold_until"] = time.time() + ECHO_HOLD
            self.pending_me.append(seg)
        else:
            # Two outputs carrying the same call (a capture moved, or audio
            # mirrored) decode the same words at the same moment; keep one.
            recent = [s for s in (self.current.segments[-8:] if self.current else []) if s["speaker"] not in (ME, *OWN)]
            if any(overlaps(seg, s) and similar(seg["text"], s["text"]) for s in recent):
                self.broadcast({"type": "echo_dropped", "text": text})
                return
            self.commit(seg)
            for m in list(self.pending_me):
                if overlaps(m, seg) and similar(m["text"], seg["text"]):
                    self.pending_me.remove(m)
                    self.broadcast({"type": "echo_dropped", "text": m["text"]})

    def commit(self, seg):
        if not self.current:
            return
        seg = self.current.append({k: v for k, v in seg.items() if k != "hold_until"})
        self.broadcast(self.segment_event(seg, self.current.id))

    async def flush_pending(self):
        while True:
            await asyncio.sleep(0.5)
            now = time.time()
            for m in [m for m in self.pending_me if m["hold_until"] <= now]:
                self.pending_me.remove(m)
                self.commit(m)

    async def levels(self):
        while True:
            await asyncio.sleep(0.15)
            if self.channels:
                self.broadcast({"type": "levels", "channels": [c.status() for c in self.channels]})

def overlaps(a, b):
    return a["start"] < b["end"] + 2 and b["start"] < a["end"] + 2


class Channel:
    """One PipeWire capture (mic or a speaker monitor) with its own VAD."""

    def __init__(self, app, speaker, device, label):
        self.app, self.speaker, self.device, self.label = app, speaker, device, label
        self.level = 0.0
        self.alive = False
        self.speaking = False
        self.pid = None
        self.loudness = collections.deque(maxlen=600)  # (arrival time, rms) per 100 ms read, last minute

    def loudness_since(self, t):
        return [r for when, r in self.loudness if when >= t]

    def status(self):
        return {"label": self.label, "speaker": self.speaker, "level": round(self.level, 3),
                "alive": self.alive, "speaking": self.speaking}

    async def run(self):
        loop = asyncio.get_running_loop()
        # A speaker monitor stays on its own speakers. Left movable, WirePlumber
        # shifts a capture off an idle output onto whichever one is playing,
        # and every Them line then comes out once per output. The mic follows
        # the default source, so it may move.
        pin = [] if self.device.startswith("@") else [
            "--property=node.dont-move=true", "--property=node.dont-reconnect=true",
            "--property=node.dont-fallback=true"]
        while True:
            proc = await asyncio.create_subprocess_exec(
                "parec", "-d", self.device, "--format=s16le", f"--rate={RATE}", "--channels=1",
                "--raw", "--latency-msec=100", *pin,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            self.pid = proc.pid  # so the call watch knows this recorder is ours
            vad, window = make_vad()
            buf = np.zeros(0, dtype=np.float32)
            speech = []
            last_interim = 0.0
            self.alive = True
            try:
                while True:
                    data = await proc.stdout.readexactly(CHUNK * 2)
                    x = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0
                    self.level = float(np.sqrt(np.mean(x * x)))
                    self.loudness.append((time.time(), self.level))
                    buf = np.concatenate([buf, x])
                    while len(buf) >= window:
                        vad.accept_waveform(buf[:window])
                        buf = buf[window:]
                    self.speaking = vad.is_speech_detected()
                    if self.speaking:
                        speech.append(x)
                        now = time.time()
                        # Interim text is display-only. The mic's preview waits while
                        # the other side talks: that's mostly their voice echoing.
                        busy = not self.app.pool._work_queue.empty()
                        echo = self.speaker == ME and self.app.them_speaking()
                        if (self.app.previewers and now - last_interim > INTERIM_EVERY
                                and len(speech) > 6 and not busy and not echo):
                            last_interim = now
                            tail = np.concatenate(speech[-INTERIM_TAIL * 10:])
                            text = await loop.run_in_executor(self.app.pool, self.app.decode, tail)
                            if self.speaking and text:
                                self.app.broadcast({"type": "interim", "label": self.label, "speaker": self.speaker, "text": text})
                    while not vad.empty():
                        samples = np.array(vad.front.samples, dtype=np.float32)
                        vad.pop()
                        speech = []
                        end = time.time()
                        start = end - len(samples) / RATE
                        if self.speaker == ME and self.app.heard_through_room(self, len(samples) / RATE):
                            self.app.broadcast({"type": "interim", "label": self.label, "speaker": self.speaker, "text": ""})
                            continue
                        text = await loop.run_in_executor(self.app.pool, self.app.decode, samples)
                        self.app.broadcast({"type": "interim", "label": self.label, "speaker": self.speaker, "text": ""})
                        if text:
                            voice = await self.app.voice_of(samples) if self.speaker != ME and self.app.voices_on() else None
                            self.app.add_segment(self.speaker, start, end, text, voice)
            except (asyncio.IncompleteReadError, ConnectionError):
                pass
            finally:
                self.alive = False
                self.speaking = False
                self.level = 0.0
                if proc.returncode is None:
                    proc.kill()
                    await proc.wait()
            await asyncio.sleep(2)  # device went away (display unplugged, sleep); retry


def sinks():
    out = subprocess.run(["pactl", "list", "short", "sinks"], capture_output=True, text=True).stdout
    return [line.split("\t")[1] for line in out.splitlines() if line.strip()]


def label_for(device, displays_seen):
    if "Studio_Display" in device:
        displays_seen.append(device)
        return "Display " + "ABCD"[len(displays_seen) - 1]
    if "pci" in device:
        return "Laptop"
    return device


# ---- HTTP ----

async def events(request):
    app = request.app["sidecar"]
    resp = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache"})
    await resp.prepare(request)
    q = asyncio.Queue()
    # Every meeting, the state, then the live meeting's lines: a client that
    # reconnects starts from a clean slate.
    hello = [{"type": "meetings", "meetings": app.listing()}, app.state()]
    if app.current:
        hello += [app.segment_event(s, app.current.id) for s in app.current.segments]
    app.clients.add(q)
    if request.query.get("interims") == "1":
        app.previewers.add(q)
    try:
        for m in hello:
            await resp.write(f"data: {json.dumps(m)}\n\n".encode())
        while True:
            try:
                data = await asyncio.wait_for(q.get(), 15)
                await resp.write(f"data: {data}\n\n".encode())
            except asyncio.TimeoutError:
                await resp.write(b": keepalive\n\n")
    except (ConnectionResetError, asyncio.CancelledError):
        pass
    finally:
        app.clients.discard(q)
        app.previewers.discard(q)
    return resp


async def body(request):
    try:
        return await request.json() if request.can_read_body else {}
    except json.JSONDecodeError:
        return {}


async def status(request):
    app = request.app["sidecar"]
    return web.json_response({**app.state(), "meeting": app.current.summary() if app.current else None})


async def listen(request):
    app = request.app["sidecar"]
    await app.set_listening(bool((await body(request)).get("on", not app.listening)))
    return web.json_response(app.state())


async def meetings(request):
    return web.json_response(request.app["sidecar"].listing())


def find(request):
    m = request.app["sidecar"].meetings.get(request.match_info["id"])
    if not m:
        raise web.HTTPNotFound(text="No such meeting.")
    return m


async def meeting(request):
    m = find(request)
    return web.json_response({"meeting": m.summary(), "segments": m.segments})


async def update(request):
    m = find(request)
    request.app["sidecar"].update_meeting(m, await body(request))
    return web.json_response(m.summary())


async def start(request):
    app = request.app["sidecar"]
    b = await body(request)
    m = await app.start_meeting(b.get("title"), b.get("event"))
    return web.json_response(m.summary())


async def end(request):
    m = await request.app["sidecar"].end_meeting()
    return web.json_response(m.summary() if m else None)


async def resume(request):
    m = await request.app["sidecar"].resume_meeting(find(request))
    return web.json_response(m.summary())


async def finish(request):
    m = find(request)
    started = await request.app["sidecar"].finish(m, email=(await body(request)).get("email", True))
    if started is None:
        raise web.HTTPConflict(text="There's no wrap-up yet.")
    return web.json_response({"started": started, "meeting": m.summary()})


async def merge(request):
    app = request.app["sidecar"]
    other = app.meetings.get((await body(request)).get("with", ""))
    if not other:
        raise web.HTTPNotFound(text="No such meeting to merge with.")
    m = app.merge_meetings(find(request), other)
    if not m:
        raise web.HTTPConflict(text="End the meeting that's on (and let any Notion send finish) before merging.")
    return web.json_response(m.summary())


async def delete(request):
    if not request.app["sidecar"].delete_meeting(find(request)):
        raise web.HTTPConflict(text="End the meeting before deleting it.")
    return web.json_response({"ok": True})


async def get_wrapup(request):
    m = find(request)
    return web.json_response({"meeting": m.summary(), "wrapup": m.wrapup(), "takeaways": m.takeaways(),
                              "brief": request.app["sidecar"].brief(m)})


async def draft(request):
    m = find(request)
    request.app["sidecar"].draft(m, bool((await body(request)).get("replace")))
    return web.json_response({"wrapup": m.wrapup()})


async def edit_wrapup(request):
    m = find(request)
    request.app["sidecar"].edit_wrapup(m, (await body(request)).get("edited"))
    return web.json_response({"wrapup": m.wrapup()})


async def markdown(request):
    m = find(request)
    notes = m.notes()
    if not notes:
        raise web.HTTPNotFound(text="No wrap-up yet.")
    return web.Response(text=wrapup.markdown(m.meta, notes), content_type="text/markdown")


async def candidates(request):
    app = request.app["sidecar"]
    try:
        return web.json_response({"pages": await app.fill_ins(find(request))})
    except NotionError as e:
        return web.json_response({"error": str(e)}, status=502)


async def send(request):
    app = request.app["sidecar"]
    m = find(request)
    if (m.meta.get("notion") or {}).get("state") == "sent":
        raise web.HTTPConflict(text="Already in Notion.")
    if not app.send(m, (await body(request)).get("target")):
        raise web.HTTPConflict(text="Nothing to send yet, or it's already sending.")
    return web.json_response(m.summary())


async def send_all(request):
    taken = request.app["sidecar"].send_all((await body(request)).get("ids") or [])
    if taken is None:
        raise web.HTTPConflict(text="Already sending.")
    return web.json_response({"taken": taken})


async def note(request):
    m = find(request)
    b = await body(request)
    kind = "Mark" if b.get("kind") == "mark" else "Note"
    if kind == "Note" and not (b.get("text") or "").strip():
        raise web.HTTPBadRequest(text="A note needs some text.")
    return web.json_response(request.app["sidecar"].add_note(m, kind, b.get("text") or ""))


async def search(request):
    q = request.query.get("q", "")
    return web.json_response({"q": q, "results": request.app["sidecar"].search(q)})


async def remove_followup(request):
    app = request.app["sidecar"]
    b = await body(request)
    m = app.meetings.get(b.get("meeting", ""))
    notes = m.notes() if m else None
    index = b.get("index", -1)
    if not notes or not 0 <= index < len(notes.get("mine", [])):
        raise web.HTTPNotFound(text="No such follow-up.")
    app.remove_followup(m, index)
    return web.json_response({"followups": app.followups()})


async def followups(request):
    return web.json_response({"followups": request.app["sidecar"].followups()})


async def learned(request):
    try:
        days = max(0, int(request.query.get("days", 30)))
    except ValueError:
        days = 30
    return web.json_response({"learned": request.app["sidecar"].learned(days)})


async def topic(request):
    found = request.app["sidecar"].topic(request.query.get("name", ""))
    if not found:
        raise web.HTTPNotFound(text="Nothing under that topic.")
    return web.json_response({"topic": found})


async def set_followup(request):
    app = request.app["sidecar"]
    b = await body(request)
    m = app.meetings.get(b.get("meeting"))
    notes = m.notes() if m else None
    index = b.get("index")
    if not notes or not isinstance(index, int) or not 0 <= index < len(notes.get("mine", [])):
        raise web.HTTPNotFound(text="No such follow-up.")
    app.set_done(m, index, bool(b.get("done")))
    return web.json_response({"ok": True})


async def flag_followup(request):
    app = request.app["sidecar"]
    b = await body(request)
    m = app.meetings.get(b.get("meeting"))
    notes = m.notes() if m else None
    index = b.get("index")
    if not notes or not isinstance(index, int) or not 0 <= index < len(notes.get("mine", [])):
        raise web.HTTPNotFound(text="No such follow-up.")
    app.set_flagged(m, index, bool(b.get("flagged")))
    return web.json_response({"ok": True})


async def sync_followups(request):
    app = request.app["sidecar"]
    try:
        changed = await app.pull_ticks()
    except NotionError as e:
        return web.json_response({"error": str(e)}, status=502)
    return web.json_response({"changed": changed, "followups": app.followups()})


async def write_email(request):
    m = find(request)
    if not request.app["sidecar"].write_email(m):
        raise web.HTTPConflict(text="Draft the wrap-up first, or it's already writing.")
    return web.json_response({"ok": True})


async def edit_email(request):
    m = find(request)
    b = await body(request)
    changes = {k: b[k] for k in ("to", "cc", "subject", "body") if k in b}
    request.app["sidecar"].set_email(m, **changes)
    return web.json_response({"ok": True})


async def save_email(request):
    m = find(request)
    e = (m.wrapup() or {}).get("email") or {}
    if e.get("state") not in ("ready", "saved") or not e.get("body"):
        raise web.HTTPConflict(text="There's no email to save yet.")
    asyncio.create_task(request.app["sidecar"].save_email(m))
    return web.json_response({"ok": True})


async def get_settings(request):
    return web.json_response(request.app["sidecar"].settings)


async def set_settings(request):
    app = request.app["sidecar"]
    app.set_settings(await body(request))
    return web.json_response(app.settings)


async def main():
    listen_now = "--listen" in sys.argv
    sidecar = Sidecar()
    app = web.Application()
    app["sidecar"] = sidecar
    app.router.add_get("/events", events)
    app.router.add_get("/status", status)
    app.router.add_post("/listen", listen)
    app.router.add_get("/meetings", meetings)
    app.router.add_get("/meeting/{id}", meeting)
    app.router.add_patch("/meeting/{id}", update)
    app.router.add_post("/meeting/start", start)
    app.router.add_post("/meeting/end", end)
    app.router.add_post("/meeting/{id}/resume", resume)
    app.router.add_post("/meeting/{id}/merge", merge)
    app.router.add_post("/meeting/{id}/finish", finish)
    app.router.add_delete("/meeting/{id}", delete)
    app.router.add_get("/meeting/{id}/wrapup", get_wrapup)
    app.router.add_post("/meeting/{id}/wrapup", draft)
    app.router.add_put("/meeting/{id}/wrapup", edit_wrapup)
    app.router.add_get("/meeting/{id}/markdown", markdown)
    app.router.add_get("/meeting/{id}/notion", candidates)
    app.router.add_post("/meeting/{id}/notion", send)
    app.router.add_post("/meeting/{id}/note", note)
    app.router.add_post("/meeting/{id}/email", write_email)
    app.router.add_put("/meeting/{id}/email", edit_email)
    app.router.add_post("/meeting/{id}/email/save", save_email)
    app.router.add_get("/followups", followups)
    app.router.add_get("/learned", learned)
    app.router.add_get("/topic", topic)
    app.router.add_post("/followups/remove", remove_followup)
    app.router.add_get("/search", search)
    app.router.add_post("/followups/done", set_followup)
    app.router.add_post("/followups/flag", flag_followup)
    app.router.add_post("/notion/bulk", send_all)
    app.router.add_post("/followups/sync", sync_followups)
    app.router.add_get("/settings", get_settings)
    app.router.add_patch("/settings", set_settings)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", PORT).start()
    print(f"Aloi Sidecar engine on http://127.0.0.1:{PORT}", flush=True)
    if listen_now:
        await sidecar.set_listening(True)
    for m in sidecar.interrupted:  # a restart part way through a draft picks it back up
        sidecar.draft(m)
    jobs = [sidecar.flush_pending(), sidecar.levels(), sidecar.follow_calendar(), sidecar.follow_takeaways(),
            sidecar.watch_silence()]
    if calls.enabled():
        jobs.append(sidecar.watch.watch())
    await asyncio.gather(*jobs)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
