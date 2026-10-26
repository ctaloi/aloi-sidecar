#!/usr/bin/env python3
"""Downloads the speech models the engine needs, once, into
~/.local/share/aloi-sidecar/models (about 650 MB)."""
import tarfile
import urllib.request
from pathlib import Path

MODELS = Path.home() / ".local/share/aloi-sidecar/models"
BASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
PARAKEET = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"


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
print(f"Speech models are in {MODELS}")
