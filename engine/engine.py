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

RATE = 16000
CHUNK = 1600  # 100 ms of samples per read
PORT = int(os.environ.get("SIDECAR_PORT", 8777))
HERE = Path(__file__).resolve().parent
MODELS = Path.home() / ".local/share/aloi-sidecar/models"
PARAKEET = MODELS / "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
MEETINGS = Path(os.environ.get("SIDECAR_MEETINGS", Path.home() / ".local/share/aloi-sidecar/meetings"))
KEY_FILE = Path.home() / ".config/aloi-sidecar/api-key"  # optional; else SDK defaults (ANTHROPIC_API_KEY etc.)
RESUME_WINDOW = 15 * 60  # listening again within this long of the last line continues the same meeting
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


class Sidecar:
    def __init__(self):
        self.recognizer = make_recognizer()
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)  # one recognizer, one decoder thread
        self.segments = []  # committed, append-only
        self.pending_me = []  # held briefly so speaker echo of "Them" can be dropped
        self.clients = set()
        self.channels = []
        self.tasks = []
        self.listening = False
        self.log = None
        self.path = None
        MEETINGS.mkdir(parents=True, exist_ok=True)
        self.ask_blocks = []  # frozen transcript blocks already sent to Claude
        self.ask_sent = 0  # number of segments covered by ask_blocks
        if KEY_FILE.exists():
            self.client = anthropic.AsyncAnthropic(api_key=KEY_FILE.read_text().strip())
        else:
            self.client = anthropic.AsyncAnthropic()
        self.resume_or_new(force_new=False)

    # ---- meetings ----

    def resume_or_new(self, force_new):
        """Continue the latest meeting if it had a line recently, else start a new one."""
        logs = sorted(MEETINGS.glob("*.jsonl"), key=lambda p: p.stat().st_mtime)
        path = None
        if not force_new and logs and time.time() - logs[-1].stat().st_mtime < RESUME_WINDOW:
            path = logs[-1]
        if path and path == self.path:
            return
        if not path and self.path and not self.path.exists() and not force_new:
            return  # a new meeting nobody has spoken in yet: keep it
        if self.log:
            self.log.close()
            self.log = None
        self.ask_blocks, self.ask_sent, self.pending_me = [], 0, []
        if path:
            with path.open() as f:
                self.segments = [json.loads(line) for line in f if line.strip()]
        else:
            # The file is made with the first line, so starting the service
            # (at every login) doesn't leave empty meetings behind.
            path = MEETINGS / f"{datetime.now():%Y-%m-%d_%H%M%S}.jsonl"
            self.segments = []
        self.path = path
        self.broadcast({"type": "meeting", **self.meeting_info()})
        for s in self.segments:
            self.broadcast(self.segment_event(s))

    def meeting_info(self):
        return {"meeting": self.path.stem, "path": str(self.path), "lines": len(self.segments)}

    def state(self):
        return {"type": "state", "listening": self.listening,
                "channels": [{"label": c.label, "speaker": c.speaker} for c in self.channels]}

    async def set_listening(self, on):
        if on == self.listening:
            return
        self.listening = on
        if on:
            self.resume_or_new(force_new=False)
            # Outputs are found afresh each time, so a display plugged in since
            # the last call is heard too.
            self.channels = [Channel(self, ME, "@DEFAULT_SOURCE@", "Mic")]
            displays = []
            for sink in sinks():
                self.channels.append(Channel(self, "Them", sink + ".monitor", label_for(sink, displays)))
            self.tasks = [asyncio.create_task(c.run()) for c in self.channels]
        else:
            for t in self.tasks:
                t.cancel()
            await asyncio.gather(*self.tasks, return_exceptions=True)
            self.tasks, self.channels = [], []
            for m in self.pending_me:
                self.commit(m)
            self.pending_me = []
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

    def segment_event(self, seg):
        return {"type": "segment", **seg, "time": stamp(seg["start"])}

    def them_speaking(self):
        return any(c.speaking for c in self.channels if c.speaker != ME)

    def add_segment(self, speaker, start, end, text):
        seg = {"speaker": speaker, "start": start, "end": end, "text": text}
        if speaker == ME:
            # Speakers bleeding into the mic: the "Them" line may already be in,
            # or may still be decoding, so check now and again until the hold ends.
            recent = [s for s in self.segments[-8:] if s["speaker"] != ME]
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
        seg = {k: v for k, v in seg.items() if k != "hold_until"}
        seg["id"] = len(self.segments)
        self.segments.append(seg)
        if not self.log:
            self.log = self.path.open("a")
        self.log.write(json.dumps(seg) + "\n")
        self.log.flush()
        self.broadcast(self.segment_event(seg))

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
        new = self.segments[self.ask_sent:]
        if new:
            self.ask_blocks.append({"type": "text", "text": self.transcript_text(new)})
            self.ask_sent = len(self.segments)
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
    # Everything so far, then live: a client that reconnects starts from a clean slate.
    hello = [{"type": "meeting", **app.meeting_info()}, app.state()]
    hello += [app.segment_event(s) for s in app.segments]
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


async def status(request):
    app = request.app["sidecar"]
    return web.json_response({**app.state(), **app.meeting_info()})


async def listen(request):
    app = request.app["sidecar"]
    body = await request.json() if request.can_read_body else {}
    await app.set_listening(bool(body.get("on", not app.listening)))
    return web.json_response(app.state())


async def new_meeting(request):
    app = request.app["sidecar"]
    app.resume_or_new(force_new=True)
    return web.json_response(app.meeting_info())


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
    app.router.add_post("/meeting/new", new_meeting)
    app.router.add_post("/ask", ask)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", PORT).start()
    print(f"Aloi Sidecar engine on http://127.0.0.1:{PORT}", flush=True)
    if listen_now:
        await sidecar.set_listening(True)
    await asyncio.gather(sidecar.flush_pending(), sidecar.levels())


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
