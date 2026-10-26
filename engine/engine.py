#!/usr/bin/env python3
"""Aloi Sidecar engine: a live transcript of the meeting you're in.

Captures your mic ("Chris") and every speaker output ("Them") through
PipeWire and transcribes locally with Parakeet (sherpa-onnx). It only listens
while asked to (POST /listen); the Aloi Sidecar app turns it on and off and
runs the agent. Events stream from GET /events; http://127.0.0.1:8777 is a
plain web view with a direct Claude ask box, kept as a fallback.
"""
import asyncio
import concurrent.futures
import difflib
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

import anthropic
import numpy as np
import sherpa_onnx
from aiohttp import web

import calls
import wrapup
from notion import Notion, NotionError

RATE = 16000
CHUNK = 1600  # 100 ms of samples per read
PORT = int(os.environ.get("SIDECAR_PORT", 8777))
HERE = Path(__file__).resolve().parent
MODELS = Path.home() / ".local/share/aloi-sidecar/models"
PARAKEET = MODELS / "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
MEETINGS = Path(os.environ.get("SIDECAR_MEETINGS", Path.home() / ".local/share/aloi-sidecar/meetings"))
TRASH = MEETINGS.parent / "trash"  # deleted meetings go here, never straight to nothing
SETTINGS = Path(os.environ.get("SIDECAR_SETTINGS", Path.home() / ".config/aloi-sidecar/settings.json"))
DEFAULTS = {"watch_calls": True}
END_AFTER = 120  # seconds after a call lets go of the mic before its meeting ends by itself
KEY_FILE = Path.home() / ".config/aloi-sidecar/api-key"  # optional; else SDK defaults (ANTHROPIC_API_KEY etc.)
RECOVER_WINDOW = 2 * 60 * 60  # a meeting left live by a crash comes back paused if its last line is this recent
ME = "Chris"

INTERIM_EVERY = 1.5  # seconds between live-preview decodes
INTERIM_TAIL = 8  # preview only the last N seconds of the utterance
ECHO_HOLD = 3  # seconds a mic line waits for the speaker line it may be an echo of
ECHO_RATIO = 0.55

# Direct Q&A for the web view. Effort stays low so answers come back fast mid-call.
ASK_MODEL = "claude-opus-5-5"
ASK_EFFORT = "low"
FALLBACK_BETA = "server-side-fallback-2026-07-01"

SYSTEM = f"""You are a sidecar assistant listening to a live meeting alongside {ME}.
You receive the meeting transcript so far, produced by local speech recognition, then a question from {ME}.

Transcript notes:
- "{ME}" lines come from {ME}'s microphone. "Them" lines are everyone else on the call, mixed together.
- Recognition errors happen, especially names, numbers and jargon. Read past obvious mis-hearings.
- The transcript may stop mid-thought; it is live.

Answer {ME}'s question directly and briefly; he is reading this while the call continues.
Quote or cite the moment (timestamp) when it helps. If the transcript doesn't contain the answer, say so plainly."""


def make_recognizer():
    return sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=str(PARAKEET / "encoder.int8.onnx"),
        decoder=str(PARAKEET / "decoder.int8.onnx"),
        joiner=str(PARAKEET / "joiner.int8.onnx"),
        tokens=str(PARAKEET / "tokens.txt"),
        model_type="nemo_transducer",
        # onnxruntime threads busy-wait; 2 is as fast as 6 here at a quarter of the CPU
        num_threads=2,
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
        self.pending_me = []  # held briefly so speaker echo of "Them" can be dropped
        self.clients = set()
        self.channels = []
        self.tasks = []
        self.listening = False
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
        self.settings = {**DEFAULTS, **(json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {})}
        self.call = None  # {"app", "since"} while another app holds the mic
        self.prompt = None  # the notification task asking about the call
        self.watch = calls.CallWatch(lambda: [c.pid for c in self.channels if c.pid],
                                     self.call_started, self.call_ended)
        self.ask_blocks = []  # frozen transcript blocks already sent to Claude
        self.ask_sent = 0  # number of segments covered by ask_blocks
        if KEY_FILE.exists():
            self.client = anthropic.AsyncAnthropic(api_key=KEY_FILE.read_text().strip())
        else:
            self.client = anthropic.AsyncAnthropic()

    def recover(self):
        """A meeting left live by a crash or a reboot comes back paused if it
        was recent, and is ended (at its last line) if it wasn't."""
        for m in self.meetings.values():
            w = m.wrapup()
            if w and w["state"] == "drafting":  # the engine stopped part way through
                w.update(state="failed", error="Drafting was interrupted. Try again.")
                m.save_wrapup(w)
            if m.meta["state"] == "ended":
                continue
            if self.current is None and time.time() - m.last_line_end() < RECOVER_WINDOW:
                m.meta["state"] = "paused"
                self.current = m
            else:
                m.meta["state"] = "ended"
                m.meta["ended"] = m.last_line_end()
            m.save()

    # ---- meetings ----

    def listing(self):
        return sorted((m.summary() for m in self.meetings.values()), key=lambda s: s["started"], reverse=True)

    def announce(self, m):
        self.broadcast({"type": "meeting", "meeting": m.summary()})

    def state(self):
        return {"type": "state", "listening": self.listening,
                "current": self.current.id if self.current else None,
                "channels": [{"label": c.label, "speaker": c.speaker} for c in self.channels],
                "call": self.call, "settings": self.settings}

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
        asks, once, with a notification; clicking it starts a meeting."""
        self.call = {"app": app, "since": time.time()}
        self.broadcast(self.state())
        if self.listening or not self.settings["watch_calls"]:
            return
        self.notify(self.ask_to_listen(app))

    async def call_ended(self, app):
        """The call let go of the mic. A meeting that's listening gets an
        End prompt, and ends by itself after two quiet minutes."""
        self.call = None
        self.broadcast(self.state())
        if self.listening and self.current:
            self.notify(self.ask_to_end(self.current, app))
        else:
            self.notify(None)

    def notify(self, coro):
        if self.prompt:
            self.prompt.cancel()
        self.prompt = asyncio.create_task(coro) if coro else None

    async def ask_to_listen(self, app):
        choice = await calls.notify(f"{app} is using your mic", "Listen to this call with Sidecar?",
                                    [("default", "Listen"), ("ignore", "Not now")])
        if choice == "default" and not self.listening:
            await self.start_meeting()

    async def ask_to_end(self, m, app):
        heard = m.lines()
        choice = await calls.notify(f"Sounds like the {app} call ended",
                                    f"End “{m.meta['title']}”? It ends by itself in two minutes if nothing more is said.",
                                    [("default", "End meeting"), ("keep", "Keep listening")], timeout=END_AFTER)
        if self.current is not m or self.call:
            return  # something else happened meanwhile: another call, or it ended already
        if choice == "default" or (choice is None and m.lines() == heard):
            await self.end_meeting()

    async def start_meeting(self, title=None, event=None):
        await self.end_meeting()
        if self.prompt:  # a "Listen?" notification is answered by starting
            self.notify(None)
        if not title and not event and self.call and self.call["app"] in calls.CALL_APPS:
            title = f"{self.call['app']} call at {datetime.now():%-I:%M}"
        m = Meeting.create(title or (event or {}).get("subject") or ad_hoc_title(), event)
        self.meetings[m.id] = m
        self.current = m
        self.ask_blocks, self.ask_sent = [], 0
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
        self.ask_blocks, self.ask_sent = [], 0
        await self.set_listening(True)
        return m

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
            notes = await wrapup.draft(ME, m.meta, m.segments, options)
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

    def edit_wrapup(self, m, edited):
        w = dict(m.wrapup() or {"state": "ready", "draft": None})
        w["edited"] = {**wrapup.EMPTY, **edited} if edited else None
        if w["state"] == "failed" and edited:
            w["state"] = "ready"
        m.save_wrapup(w)
        self.announce_wrapup(m)

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
            await self.notion.send(m.meta, m.notes(), m.segments, target, save)
        except Exception as e:
            progress = dict(m.meta.get("notion") or {})
            progress.update(state="failed", error=str(e) or type(e).__name__)
            save(progress)
        finally:
            self.sending.pop(m.id, None)

    def update_meeting(self, m, changes):
        for key in ("title", "people", "skipped"):
            if key in changes:
                m.meta[key] = changes[key]
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

    def segment_event(self, seg, meeting):
        return {"type": "segment", **seg, "meeting": meeting, "time": stamp(seg["start"])}

    def them_speaking(self):
        return any(c.speaking for c in self.channels if c.speaker != ME)

    def add_segment(self, speaker, start, end, text):
        seg = {"speaker": speaker, "start": start, "end": end, "text": text}
        if speaker == ME:
            # Speakers bleeding into the mic: the "Them" line may already be in,
            # or may still be decoding, so check now and again until the hold ends.
            recent = [s for s in (self.current.segments[-8:] if self.current else []) if s["speaker"] != ME]
            if any(overlaps(seg, s) and similar(seg["text"], s["text"]) for s in recent):
                self.broadcast({"type": "echo_dropped", "text": text})
                return
            seg["hold_until"] = time.time() + ECHO_HOLD
            self.pending_me.append(seg)
        else:
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

    # ---- Claude (web view only; the app asks through its agent) ----

    def transcript_text(self, segs):
        return "\n".join(f"[{stamp(s['start'])}] {s['speaker']}: {s['text']}" for s in segs)

    async def ask(self, question):
        # Everything new since the last question becomes one frozen block, so the
        # prefix Claude saw last time is byte-identical and served from cache.
        segments = self.current.segments if self.current else []
        new = segments[self.ask_sent:]
        if new:
            self.ask_blocks.append({"type": "text", "text": self.transcript_text(new)})
            self.ask_sent = len(segments)
        if not self.ask_blocks:
            yield {"type": "answer_delta", "text": "Nothing has been transcribed yet."}
            return
        blocks = [dict(b) for b in self.ask_blocks]
        blocks[0]["text"] = "<transcript>\n" + blocks[0]["text"]
        blocks[-1] = {**blocks[-1], "text": blocks[-1]["text"] + "\n</transcript>", "cache_control": {"type": "ephemeral"}}
        content = blocks + [{"type": "text", "text": f"Question from {ME}: {question}"}]
        async with self.client.beta.messages.stream(
            model=ASK_MODEL,
            max_tokens=4000,
            system=SYSTEM,
            output_config={"effort": ASK_EFFORT},
            betas=[FALLBACK_BETA],
            fallbacks="default",
            messages=[{"role": "user", "content": content}],
        ) as stream:
            async for text in stream.text_stream:
                yield {"type": "answer_delta", "text": text}
            final = await stream.get_final_message()
        if final.stop_reason == "refusal":
            yield {"type": "answer_delta", "text": "\n\n(Claude declined to answer this one.)"}
        u = final.usage
        yield {"type": "answer_done", "usage": {
            "input": u.input_tokens, "cache_read": u.cache_read_input_tokens or 0,
            "cache_write": u.cache_creation_input_tokens or 0, "output": u.output_tokens}}


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

    def status(self):
        return {"label": self.label, "speaker": self.speaker, "level": round(self.level, 3),
                "alive": self.alive, "speaking": self.speaking}

    async def run(self):
        loop = asyncio.get_running_loop()
        while True:
            proc = await asyncio.create_subprocess_exec(
                "parec", "-d", self.device, "--format=s16le", f"--rate={RATE}", "--channels=1",
                "--raw", "--latency-msec=100",
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
                        if now - last_interim > INTERIM_EVERY and len(speech) > 6 and not busy and not echo:
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
                        text = await loop.run_in_executor(self.app.pool, self.app.decode, samples)
                        self.app.broadcast({"type": "interim", "label": self.label, "speaker": self.speaker, "text": ""})
                        if text:
                            self.app.add_segment(self.speaker, start, end, text)
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

def line(msg):
    return (json.dumps(msg) + "\n").encode()


async def index(request):
    return web.FileResponse(HERE / "web.html")


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


async def delete(request):
    if not request.app["sidecar"].delete_meeting(find(request)):
        raise web.HTTPConflict(text="End the meeting before deleting it.")
    return web.json_response({"ok": True})


async def get_wrapup(request):
    m = find(request)
    return web.json_response({"meeting": m.summary(), "wrapup": m.wrapup()})


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
        return web.json_response({"pages": await app.notion.candidates(find(request).meta)})
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


async def get_settings(request):
    return web.json_response(request.app["sidecar"].settings)


async def set_settings(request):
    app = request.app["sidecar"]
    app.set_settings(await body(request))
    return web.json_response(app.settings)


async def ask(request):
    app = request.app["sidecar"]
    question = (await request.json()).get("q", "").strip()
    resp = web.StreamResponse(headers={"Content-Type": "application/x-ndjson"})
    await resp.prepare(request)
    try:
        async for msg in app.ask(question):
            await resp.write(line(msg))
    except (anthropic.AuthenticationError, TypeError):  # TypeError: no credentials configured at all
        await resp.write(line({"type": "error", "text": "No Anthropic credentials. Link a key to ~/.config/aloi-sidecar/api-key, then restart."}))
    except anthropic.APIStatusError as e:
        await resp.write(line({"type": "error", "text": f"Claude API error {e.status_code}: {e.message}"}))
    except anthropic.APIConnectionError:
        await resp.write(line({"type": "error", "text": "Couldn't reach the Claude API."}))
    return resp


async def main():
    listen_now = "--listen" in sys.argv
    sidecar = Sidecar()
    app = web.Application()
    app["sidecar"] = sidecar
    app.router.add_get("/", index)
    app.router.add_get("/events", events)
    app.router.add_get("/status", status)
    app.router.add_post("/listen", listen)
    app.router.add_get("/meetings", meetings)
    app.router.add_get("/meeting/{id}", meeting)
    app.router.add_patch("/meeting/{id}", update)
    app.router.add_post("/meeting/start", start)
    app.router.add_post("/meeting/end", end)
    app.router.add_post("/meeting/{id}/resume", resume)
    app.router.add_delete("/meeting/{id}", delete)
    app.router.add_get("/meeting/{id}/wrapup", get_wrapup)
    app.router.add_post("/meeting/{id}/wrapup", draft)
    app.router.add_put("/meeting/{id}/wrapup", edit_wrapup)
    app.router.add_get("/meeting/{id}/markdown", markdown)
    app.router.add_get("/meeting/{id}/notion", candidates)
    app.router.add_post("/meeting/{id}/notion", send)
    app.router.add_post("/ask", ask)
    app.router.add_get("/settings", get_settings)
    app.router.add_patch("/settings", set_settings)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", PORT).start()
    print(f"Aloi Sidecar engine on http://127.0.0.1:{PORT}", flush=True)
    if listen_now:
        await sidecar.set_listening(True)
    jobs = [sidecar.flush_pending(), sidecar.levels()]
    if calls.enabled():
        jobs.append(sidecar.watch.watch())
    await asyncio.gather(*jobs)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
