"""Speech gating shared by every recognizer. Audio stays local."""
import hashlib
import os
from pathlib import Path
import re
import urllib.request
import numpy as np

VAD_URL = "https://raw.githubusercontent.com/snakers4/silero-vad/066409f3d9db45a30d21dfcbf9147826ffdd7052/src/silero_vad/data/silero_vad.onnx"
VAD_SHA256 = "1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3"


class SpeechGate:
    def __init__(self, root):
        import onnxruntime as ort
        path = Path(os.environ.get("DIALOG_VAD_MODEL", str(Path(root) / ".local/models/silero_vad.onnx")))
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            data = urllib.request.urlopen(VAD_URL, timeout=60).read()
            if hashlib.sha256(data).hexdigest() != VAD_SHA256:
                raise ValueError("Не совпала контрольная сумма Silero VAD")
            temporary = path.with_suffix(".tmp")
            temporary.write_bytes(data)
            temporary.replace(path)
        if hashlib.sha256(path.read_bytes()).hexdigest() != VAD_SHA256:
            raise ValueError("Модель Silero VAD повреждена")
        options = ort.SessionOptions()
        options.intra_op_num_threads = 1
        options.inter_op_num_threads = 1
        self.session = ort.InferenceSession(str(path), sess_options=options, providers=["CPUExecutionProvider"])

    def trim(self, audio):
        if len(audio) < 1600 or not np.isfinite(audio).all():
            return None
        state = np.zeros((2, 1, 128), dtype=np.float32)
        context = np.zeros((1, 64), dtype=np.float32)
        voiced = []
        for offset in range(0, len(audio), 512):
            frame = np.zeros((1, 512), dtype=np.float32)
            part = audio[offset:offset + 512]
            frame[0, :len(part)] = part
            window = np.concatenate([context, frame], axis=1)
            probability, state = self.session.run(None, {"input": window, "state": state, "sr": np.array(16000, dtype=np.int64)})
            context = window[:, -64:]
            if float(probability[0, 0]) >= 0.45:
                voiced.append(offset)
        if len(voiced) < 3:
            return None
        first = max(0, voiced[0] - 3200)
        last = min(len(audio), voiced[-1] + 512 + 3200)
        return audio[first:last].copy()


def whisper_text(result):
    """Drop low-confidence silence and decoder loops, not ordinary repeated words."""
    segments = result.get("segments", [])
    if segments:
        text = "".join(segment.get("text", "") for segment in segments
                       if segment.get("avg_logprob", 0) >= -1.2
                       and segment.get("no_speech_prob", 0) < 0.8
                       and segment.get("compression_ratio", 0) < 2.6).strip()
    else:
        text = result.get("text", "").strip()
    if re.search(r"([^\s])\1{16,}", text, re.I):
        return ""
    words = re.findall(r"[\wё]+", text.lower())
    if len(words) >= 16:
        for size in range(1, 7):
            for start in range(len(words) - size * 6 + 1):
                phrase = words[start:start + size]
                if words[start:start + size * 6] == phrase * 6:
                    return ""
    return text
