"""Adapters around upstream inference APIs; one loaded model at a time."""
import base64
import json
import os
from pathlib import Path
import subprocess


class EngineUnavailable(RuntimeError):
    pass


class Parakeet:
    def __init__(self, root, notify):
        candidates = [os.environ.get("DIALOG_SPEECH_HELPER", ""),
                      str(Path(root) / "native/.build/release/DialogSpeech"),
                      str(Path(root) / "native/.build/debug/DialogSpeech")]
        helper = next((p for p in candidates if p and Path(p).is_file()), None)
        if not helper:
            raise RuntimeError("Не найден DialogSpeech. Пересоберите приложение через scripts/build-mac.sh")
        self.process = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=None, text=True, bufsize=1)
        try:
            while True:
                event = self._read()
                if event.get("type") == "speech.ready":
                    break
                if event.get("type") == "speech.error":
                    raise EngineUnavailable(event.get("message", "Parakeet не запустился"))
                if event.get("type") == "speech.loading":
                    notify(event)
        except BaseException:
            self.close()
            raise

    def _read(self):
        for line in self.process.stdout:
            try:
                return json.loads(line)
            except ValueError:
                continue
        raise EngineUnavailable("Parakeet остановился. Повторите загрузку модели в настройках.")

    def transcribe(self, audio, job):
        encoded = (audio.clip(-1, 1) * 32767).astype("<i2").tobytes()
        request = {key: job[key] for key in ["owner", "source", "id", "final", "time", "language"]}
        request["audio"] = base64.b64encode(encoded).decode("ascii")
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        while True:
            event = self._read()
            if event.get("type") == "transcript":
                return event["text"].strip()
            if event.get("type") in ["speech.error", "speech.job_error"]:
                raise RuntimeError(event.get("message", "Ошибка Parakeet"))

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()


class GigaAM:
    def __init__(self):
        import torch
        import gigaam
        torch.set_num_threads(min(4, os.cpu_count() or 4))
        self.torch = torch
        self.model = gigaam.load_model("v3_e2e_ctc", device="cpu", fp16_encoder=False)

    def transcribe(self, audio, job):
        torch = self.torch
        with torch.inference_mode():
            wav = torch.from_numpy(audio).unsqueeze(0)
            length = torch.tensor([len(audio)], dtype=torch.long)
            encoded, encoded_length = self.model(wav, length)
            result = self.model.decoding.decode(self.model.head, encoded, encoded_length)
            return result[0][0].strip()

    def close(self):
        pass


class Whisper:
    def __init__(self, engine):
        import mlx_whisper
        from mlx_whisper.transcribe import ModelHolder
        import mlx.core as mx
        self.whisper = mlx_whisper
        self.model = (os.environ.get("DIALOG_WHISPER_MODEL", "mlx-community/whisper-base-mlx")
                      if engine == "whisper-base" else "mlx-community/whisper-large-v3-turbo")
        ModelHolder.get_model(self.model, mx.float16)

    def transcribe(self, audio, job):
        from quality import whisper_text
        prompt = job.get("prompt", "").strip()[:800] or None
        result = self.whisper.transcribe(
            audio, path_or_hf_repo=self.model, language=job.get("language", "ru"),
            initial_prompt=prompt, condition_on_previous_text=False,
            temperature=(0.0, 0.2, 0.4), compression_ratio_threshold=2.4,
            logprob_threshold=-1.0, no_speech_threshold=0.6,
            word_timestamps=False, verbose=None,
        )
        return whisper_text(result)

    def close(self):
        pass
