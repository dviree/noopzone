#!/usr/bin/env python3
"""The Zone training notification sounds in StrandiOS/Resources are generated, not hand-made.

Pins that the committed WAVs are exactly what Tools/zone_training_sounds.py produces, so an edited
generator without regenerated assets (or a hand-swapped file of unknown origin) fails here instead of
shipping, and that each sound keeps the shape its name promises: increase steps up, decrease steps down.
"""
import importlib.util
import pathlib
import tempfile
import unittest
import wave

ROOT = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("zts", ROOT / "Tools/zone_training_sounds.py")
zts = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(zts)

RESOURCES = ROOT / "StrandiOS" / "Resources"


class ZoneTrainingSoundsTest(unittest.TestCase):
    def test_committed_sounds_match_the_generator(self):
        with tempfile.TemporaryDirectory() as tmp:
            zts.main(["zone_training_sounds.py", tmp])
            for name in zts.SOUNDS:
                with self.subTest(name=name):
                    committed = (RESOURCES / name).read_bytes()
                    generated = (pathlib.Path(tmp) / name).read_bytes()
                    self.assertEqual(committed, generated,
                                     f"{name} differs from the generator; run Tools/zone_training_sounds.py")

    def test_sounds_are_short_mono_pcm(self):
        for name in zts.SOUNDS:
            with self.subTest(name=name), wave.open(str(RESOURCES / name)) as w:
                self.assertEqual(w.getnchannels(), 1)
                self.assertEqual(w.getsampwidth(), 2)
                self.assertLess(w.getnframes() / w.getframerate(), 30)  # iOS notification sound limit

    def test_pitch_direction_matches_the_instruction(self):
        # Four tones up for "more" and three tones down for "less".
        self.assertEqual(len(zts.INCREASE_HZ), 4)
        self.assertEqual(len(zts.DECREASE_HZ), 3)
        self.assertEqual(zts.INCREASE_HZ, sorted(zts.INCREASE_HZ))
        self.assertEqual(zts.DECREASE_HZ, sorted(zts.DECREASE_HZ, reverse=True))
        # Increase is also a crescendo, decrease a decrescendo: loudness moves the way the pitch does.
        self.assertEqual(len(zts.INCREASE_GAINS), len(zts.INCREASE_HZ))
        self.assertEqual(zts.INCREASE_GAINS, sorted(zts.INCREASE_GAINS))
        self.assertLess(zts.INCREASE_GAINS[0], zts.INCREASE_GAINS[-1])
        self.assertEqual(len(zts.DECREASE_GAINS), len(zts.DECREASE_HZ))
        self.assertEqual(zts.DECREASE_GAINS, sorted(zts.DECREASE_GAINS, reverse=True))
        self.assertGreater(zts.DECREASE_GAINS[0], zts.DECREASE_GAINS[-1])

class IntervalSoundsTest(unittest.TestCase):
    def test_interval_sounds_exist_for_every_phase_cue(self):
        for name in ("zone-go.wav", "zone-rest.wav", "zone-done.wav"):
            with self.subTest(name=name):
                self.assertIn(name, zts.SOUNDS)
                self.assertTrue((RESOURCES / name).is_file())


if __name__ == "__main__":
    unittest.main()
