"""Telling apart the voices on the other side of a call.

Everything not from Chris's mic arrives as one "Them". Each finished line of
theirs long enough to judge gets a voiceprint (TitaNet-small, through
sherpa-onnx), and lines whose voiceprints are close enough are taken for the
same person: voice 1, voice 2, and so on, numbered per meeting. Names come
later, from Chris or from the takeaways pass. Voiceprints stay with their
meeting (voices.json in its folder); there's no library of people's voices.
"""
import json
import os
from pathlib import Path

import numpy as np

MODEL = Path(os.environ.get("SIDECAR_VOICE_MODEL",
                            Path.home() / ".local/share/aloi-sidecar/models/nemo_en_titanet_small.onnx"))
SAME = float(os.environ.get("SIDECAR_VOICE_SAME", 0.65))  # tried on four voices: 0.65 kept each apart, lower merged them
MIN_SECONDS = 1.5  # shorter lines ("okay", "yeah") say too little about a voice
RATE = 16000


class Extractor:
    """The voiceprint model, loaded the first time it's needed. One thread:
    onnxruntime's threads spin while they wait, and a voiceprint takes
    about 25 ms anyway."""

    def __init__(self, model=MODEL):
        self.model = Path(model)
        self._ext = None

    def available(self):
        return self.model.exists()

    def embed(self, samples):
        if self._ext is None:
            import sherpa_onnx
            self._ext = sherpa_onnx.SpeakerEmbeddingExtractor(
                sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(self.model), num_threads=1))
        stream = self._ext.create_stream()
        stream.accept_waveform(RATE, samples)
        stream.input_finished()
        e = np.array(self._ext.compute(stream), dtype=np.float32)
        n = float(np.linalg.norm(e))
        return e / n if n else e


class Voices:
    """One meeting's voices: a running average voiceprint for each."""

    def __init__(self, folder):
        self.path = Path(folder) / "voices.json"
        self.centroids, self.counts = [], []
        if self.path.exists():
            data = json.loads(self.path.read_text())
            self.centroids = [np.array(c, dtype=np.float32) for c in data.get("centroids", [])]
            self.counts = data.get("counts", [1] * len(self.centroids))

    def assign(self, e):
        """The voice a voiceprint belongs to (1, 2, …), a new one if it's
        like none so far, and how alike it was to the best match."""
        sims = [float(e @ (c / (np.linalg.norm(c) or 1))) for c in self.centroids]
        best = int(np.argmax(sims)) if sims else -1
        if best >= 0 and sims[best] >= SAME:
            self.centroids[best] = self.centroids[best] + e
            self.counts[best] += 1
            voice = best + 1
        else:
            self.centroids.append(e.copy())
            self.counts.append(1)
            voice = len(self.centroids)
        self.save()
        return voice, (sims[best] if best >= 0 else None)

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"centroids": [c.round(5).tolist() for c in self.centroids], "counts": self.counts}))
        tmp.replace(self.path)


def label(seg, names):
    """How a line's speaker reads: a name if the voice has one, "Voice 2" if
    it's only been told apart, else the speaker as recorded."""
    v = seg.get("voice")
    if not v:
        return seg["speaker"]
    return (names.get(str(v)) or {}).get("name") or f"Voice {v}"
