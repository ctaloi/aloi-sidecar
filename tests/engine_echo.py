#!/usr/bin/env python3
"""Echo skipping on loudness alone: a mic line that is the speakers heard
through the room is skipped before it's decoded; Chris's own voice, alone or
over theirs, and an idle output never are. Loudness tracks are synthetic
(100 ms frames), so nothing is recorded or decoded.

    engine/.venv/bin/python tests/engine_echo.py
"""
import os
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
TMP = Path(tempfile.mkdtemp(prefix="sidecar-echo-"))
os.environ.update(SIDECAR_MEETINGS=str(TMP / "meetings"), SIDECAR_SETTINGS=str(TMP / "settings.json"),
                  SIDECAR_CALENDAR="", SIDECAR_CALL_WATCH="0")
sys.path.insert(0, str(ROOT / "engine"))
import engine  # noqa: E402

failures = []
rng = np.random.default_rng(7)


def check(name, ok):
    print(("PASS " if ok else "FAIL ") + name)
    if not ok:
        failures.append(name)


def speech(frames):
    """A talker's loudness: syllable bursts and short pauses."""
    env = np.abs(rng.normal(0.08, 0.05, frames))
    env[rng.random(frames) < 0.25] = 0.003
    return env


def room(theirs, delay=2, gain=0.3):
    """Their voice off the laptop speakers into the mic: later, quieter, noisier."""
    out = np.concatenate([np.full(delay, 0.002), theirs[:-delay]]) * gain
    return out + np.abs(rng.normal(0, 0.004, len(out)))


n = 40
them = speech(n)
check("speakers heard through the room match", engine.echo_score(room(them), them) >= engine.ECHO_CORR)
check("drift of 400 ms still matches", engine.echo_score(room(them, delay=4), them) >= engine.ECHO_CORR)
check("Chris alone does not match", engine.echo_score(speech(n), them) < engine.ECHO_CORR)
check("Chris over them does not match", engine.echo_score(speech(n) + room(them), them) < engine.ECHO_CORR)
check("an idle output never matches", engine.echo_score(room(them), np.zeros(n)) == 0.0)
check("too short to judge", engine.echo_score(room(them)[:10], them[:10]) == 0.0)

# Many independent talkers: how often a real line of Chris's would be skipped.
false = sum(engine.echo_score(speech(30), speech(30)) >= engine.ECHO_CORR for _ in range(500))
check(f"Chris's lines skipped by chance: {false}/500", false <= 2)


class Ch:
    def __init__(self, speaker, label, track):
        self.speaker, self.label = speaker, label
        now = time.time()
        self.loudness = [(now - (len(track) - i) * 0.1, r) for i, r in enumerate(track)]

    def loudness_since(self, t):
        return [r for when, r in self.loudness if when >= t]


class App:
    heard_through_room = engine.Sidecar.heard_through_room

    def __init__(self, channels):
        self.channels, self.echo_skips = channels, 0


laptop = Ch("Them", "Laptop", them)
idle = Ch("Them", "Display A", np.zeros(n))
echo_mic = Ch(engine.ME, "Mic", room(them))
own_mic = Ch(engine.ME, "Mic", speech(n))
check("echo line skipped", App([echo_mic, idle, laptop]).heard_through_room(echo_mic, 3.0))
check("own line kept", not App([own_mic, idle, laptop]).heard_through_room(own_mic, 3.0))
check("short line kept without judging", not App([echo_mic, laptop]).heard_through_room(echo_mic, 1.0))

print(f"\n{len(failures)} failed" if failures else "\nall passed")
sys.exit(1 if failures else 0)
