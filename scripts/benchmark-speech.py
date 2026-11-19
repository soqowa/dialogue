#!/usr/bin/env python3
"""Exercise the actual JSONL speech worker against a public 16 kHz WAV fixture."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import time
import wave

import numpy as np

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("audio", type=Path, nargs="+")
parser.add_argument("--engines", nargs="+", default=["parakeet", "gigaam", "whisper-base", "whisper-turbo"])
parser.add_argument("--output", type=Path, default=root / "output/verification/speech-benchmark.json")
args = parser.parse_args()
fixtures = []
for audio in args.audio:
    with wave.open(str(audio)) as wav:
        assert (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) == (16000, 1, 2)
        pcm = wav.readframes(wav.getnframes())
    label = "speech" if len(args.audio) == 1 else audio.stem
    fixtures.extend([(label + "-cold", pcm), (label + "-warm", pcm)])
noise = np.random.default_rng(42).normal(0, 0.006, 16000 * 3).clip(-1, 1)
fixtures.extend([("silence", bytes(16000 * 3 * 2)), ("noise", (noise * 32767).astype("<i2").tobytes())])
results = []
args.output.parent.mkdir(parents=True, exist_ok=True)
for engine in args.engines:
    started = time.monotonic()
    with (args.output.parent / f"speech-{engine}.log").open("w") as log:
        child = subprocess.Popen([str(root / ".venv/bin/python"), "-u", str(root / "speech/worker.py")],
                                 env={**os.environ, "DIALOG_SPEECH_ENGINE": engine, "HF_HUB_DISABLE_XET": "1", "HF_HUB_DISABLE_PROGRESS_BARS": "1"},
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True, bufsize=1)
        def read_event(wanted):
            for line in child.stdout:
                event = json.loads(line)
                if event["type"] in ("speech.error", "speech.warning"):
                    raise RuntimeError(event)
                if event["type"] == wanted:
                    return event
            raise RuntimeError(f"{engine} exited: {child.poll()}")
        try:
            read_event("speech.ready")
            load = round(time.monotonic() - started, 2)
            for index, (label, data) in enumerate(fixtures):
                job = {"owner": "benchmark", "id": str(index), "source": "remote", "final": True,
                       "time": 0, "language": "ru", "audio": base64.b64encode(data).decode("ascii")}
                child.stdin.write(json.dumps(job) + "\n"); child.stdin.flush()
                event = read_event("transcript")
                assert event["id"] == str(index) and event["owner"] == "benchmark" and event["final"]
                if label in ("silence", "noise"):
                    assert event["text"] == "", event
                result = {"engine": engine, "fixture": label, "audioSeconds": len(data) / 32000,
                          "loadSeconds": load, "ms": event["ms"], "text": event["text"]}
                results.append(result)
                print(json.dumps(result, ensure_ascii=False), flush=True)
                args.output.write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
        finally:
            child.stdin.close()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
