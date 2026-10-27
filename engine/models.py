#!/usr/bin/env python3
"""Downloads the speech models the engine needs, once, into
~/.local/share/aloi-sidecar/models (about 700 MB)."""
import tarfile
import urllib.request
from pathlib import Path

MODELS = Path.home() / ".local/share/aloi-sidecar/models"
BASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
PARAKEET = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
VOICES = "nemo_en_titanet_small.onnx"


def fetch(url, dest):
    tmp = dest.with_suffix(dest.suffix + ".part")
    print(f"Downloading {url}", flush=True)
    urllib.request.urlretrieve(url, tmp)
    tmp.rename(dest)


MODELS.mkdir(parents=True, exist_ok=True)
if not (MODELS / "silero_vad.onnx").exists():
    fetch(f"{BASE}/asr-models/silero_vad.onnx", MODELS / "silero_vad.onnx")
if not (MODELS / PARAKEET / "tokens.txt").exists():
    archive = MODELS / f"{PARAKEET}.tar.bz2"
    fetch(f"{BASE}/asr-models/{PARAKEET}.tar.bz2", archive)
    with tarfile.open(archive) as tar:
        tar.extractall(MODELS, filter="data")
    archive.unlink()
# Telling voices apart on the other side of a call (speaker names).
if not (MODELS / VOICES).exists():
    fetch(f"{BASE}/speaker-recongition-models/{VOICES}", MODELS / VOICES)
print(f"Speech models are in {MODELS}")
