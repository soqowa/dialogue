import sys
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'speech'))
from quality import SpeechGate, whisper_text


class SpeechQualityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gate = SpeechGate(ROOT)

    def test_silence_noise_and_invalid_audio_do_not_reach_the_recognizer(self):
        fixtures = [np.zeros(48000, dtype=np.float32),
                    np.random.default_rng(42).normal(0, 0.006, 48000).astype(np.float32),
                    np.full(16000, np.nan, dtype=np.float32), np.zeros(512, dtype=np.float32)]
        for audio in fixtures:
            with self.subTest(samples=len(audio)):
                self.assertIsNone(self.gate.trim(audio))

    def test_decoder_loops_and_low_confidence_silence_are_rejected(self):
        self.assertEqual(whisper_text({'text': 'СП' + 'П' * 30}), '')
        self.assertEqual(whisper_text({'text': 'бей ' * 25}), '')
        self.assertEqual(whisper_text({'segments': [{'text': 'Спасибо за просмотр', 'no_speech_prob': 0.99}]}), '')
        self.assertEqual(whisper_text({'segments': [{'text': ' шум', 'avg_logprob': -3}, {'text': ' Привет', 'avg_logprob': -0.2}]}), 'Привет')

    def test_normal_repetition_and_technical_terms_survive(self):
        text = 'Да, да. Напиши тест для Spring Boot и PostgreSQL.'
        self.assertEqual(whisper_text({'text': text}), text)


if __name__ == '__main__':
    unittest.main()
