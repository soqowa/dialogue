"""Persistent local STT worker. JSONL in/out; audio is never uploaded."""
import base64
import contextlib
import json
from pathlib import Path
import os
import signal
import sys
import time

protocol = sys.stdout
engine = None


def emit(value):
    protocol.write(json.dumps(value, ensure_ascii=False) + '\n')
    protocol.flush()


def stop(*_):
    if engine is not None:
        engine.close()
    raise SystemExit(0)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
name = os.environ.get('DIALOG_SPEECH_ENGINE', 'parakeet')
emit({'type': 'speech.loading', 'engine': name, 'detail': 'Подготовка детектора речи…'})
try:
    with contextlib.redirect_stdout(sys.stderr):
        import numpy as np
        from quality import SpeechGate
        from engines import GigaAM, Parakeet, Whisper, EngineUnavailable
        gate = SpeechGate(Path(__file__).resolve().parent.parent)
        emit({'type': 'speech.loading', 'engine': name, 'detail': 'Загрузка модели распознавания…'})
        if name == 'parakeet':
            engine = Parakeet(Path(__file__).resolve().parent.parent, emit)
        elif name == 'gigaam':
            engine = GigaAM()
        elif name in ['whisper-base', 'whisper-turbo']:
            engine = Whisper(name)
        else:
            raise ValueError('Неизвестная модель распознавания')
    emit({'type': 'speech.ready', 'engine': name})
except Exception as error:
    emit({'type': 'speech.error', 'engine': name, 'message': str(error)})
    if engine is not None:
        engine.close()
    sys.exit(1)

try:
    for line in sys.stdin:
        job = None
        try:
            job = json.loads(line)
            audio = np.frombuffer(base64.b64decode(job['audio'], validate=True), dtype='<i2').astype(np.float32) / 32768.0
            began = time.monotonic()
            with contextlib.redirect_stdout(sys.stderr):
                trimmed = gate.trim(audio)
                text = engine.transcribe(trimmed, job) if trimmed is not None else ''
            emit({'type': 'transcript', 'owner': job['owner'], 'id': job['id'], 'source': job['source'],
                  'text': text.strip(), 'final': job['final'], 'time': job['time'], 'engine': name,
                  'suppressed': not text.strip(), 'ms': round((time.monotonic() - began) * 1000)})
        except EngineUnavailable as error:
            emit({'type': 'speech.error', 'engine': name, 'message': str(error)})
            break
        except Exception as error:
            if job:
                emit({'type': 'transcript', 'owner': job['owner'], 'id': job['id'], 'source': job['source'],
                      'text': '', 'final': job['final'], 'time': job['time'], 'engine': name, 'suppressed': True})
            emit({'type': 'speech.warning', 'engine': name, 'message': str(error)})
finally:
    engine.close()
