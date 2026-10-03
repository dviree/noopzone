#!/usr/bin/env python3
"""Generate the Zone training notification sounds (StrandiOS/Resources/zone-*.wav).

NOOP's own tones, synthesised here so the assets have a known origin and can be rebuilt byte-for-byte:

  zone-increase.wav  below the zone  -> four short tones stepping UP, each louder (a crescendo)
  zone-decrease.wav  above the zone  -> three short tones stepping DOWN and fading (a decrescendo;
                                        pairs with the 3 heavier taps)
  zone-in.wav        back in the zone -> one soft chime                 (pairs with the single tap)

and for interval sessions (4x4):

  zone-go.wav        a work block starts -> a start signal: two short beeps, then a long higher one
  zone-rest.wav      a rest block starts -> a calm falling two-note chime, fading
  zone-done.wav      the session is done -> a short rising fanfare ending on a held note

The direction of the pitch says what to do with the effort, so the sound is readable without looking.
Mono 16-bit linear PCM WAV at 44.1 kHz, well under iOS's 30 s limit for a notification sound. Each tone
has a short attack and release so nothing clicks.

Usage: python3 Tools/zone_training_sounds.py [output_dir]   (default: StrandiOS/Resources)
"""
from __future__ import annotations

import math
import struct
import sys
import wave
from pathlib import Path

RATE = 44_100
AMPLITUDE = 0.55          # of full scale, leaving headroom
ATTACK_S = 0.008
RELEASE_S = 0.04


def tone(freq: float, seconds: float, overtone: float = 0.0, decay: float = 0.0) -> list[float]:
    """One enveloped sine (plus an optional octave-and-a-fifth overtone for a chime colour)."""
    n = int(RATE * seconds)
    attack = int(RATE * ATTACK_S)
    release = int(RATE * RELEASE_S)
    out = []
    for i in range(n):
        t = i / RATE
        v = math.sin(2 * math.pi * freq * t)
        if overtone:
            v += overtone * math.sin(2 * math.pi * freq * 3 * t)
        v /= 1 + overtone
        env = 1.0
        if i < attack:
            env = i / attack
        elif i > n - release:
            env = max(0.0, (n - i) / release)
        if decay:
            env *= math.exp(-decay * t)
        out.append(v * env)
    return out


def silence(seconds: float) -> list[float]:
    return [0.0] * int(RATE * seconds)


def sequence(freqs: list[float], length: float, gap: float, gains: list[float] | None = None) -> list[float]:
    samples: list[float] = []
    for k, f in enumerate(freqs):
        if k:
            samples += silence(gap)
        g = gains[k] if gains else 1.0
        samples += [v * g for v in tone(f, length)]
    return samples


# Four tones climbing E5 -> G5 -> B5 -> E6, each step louder (a stepped crescendo).
INCREASE_HZ = [659.25, 783.99, 987.77, 1318.51]
INCREASE_GAINS = [0.15, 0.4, 0.7, 1.0]
# Down a triad: B5 -> G5 -> D5, fading as it falls (a decrescendo), so "less" is said twice over.
DECREASE_HZ = [987.77, 783.99, 587.33]
DECREASE_GAINS = [1.0, 0.6, 0.32]

SOUNDS = {
    "zone-increase.wav": lambda: sequence(INCREASE_HZ, 0.11, 0.05, INCREASE_GAINS),
    "zone-decrease.wav": lambda: sequence(DECREASE_HZ, 0.14, 0.07, DECREASE_GAINS),
    # A single soft G5 chime with a gentle decay.
    "zone-in.wav": lambda: tone(783.99, 0.45, overtone=0.25, decay=5.0),
    # Start signal: A5, A5, then a long E6, swelling.
    "zone-go.wav": lambda: (sequence([880.0, 880.0], 0.12, 0.28, [0.6, 0.6]) + silence(0.28)
                            + [v * 1.0 for v in tone(1318.51, 0.38)]),
    # Calm falling chime: G5 then C5, each ringing out, the second softer.
    "zone-rest.wav": lambda: ([v * 0.8 for v in tone(783.99, 0.5, overtone=0.2, decay=3.5)]
                              + [v * 0.55 for v in tone(523.25, 0.7, overtone=0.2, decay=3.0)]),
    # Fanfare: C5 E5 G5 short, then a held C6.
    "zone-done.wav": lambda: (sequence([523.25, 659.25, 783.99], 0.1, 0.03, [0.6, 0.75, 0.9])
                              + silence(0.03) + tone(1046.50, 0.6, overtone=0.25, decay=2.0)),
}


def write_wav(path: Path, samples: list[float]) -> None:
    frames = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s)) * AMPLITUDE * 32767)) for s in samples)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames)


def main(argv: list[str]) -> int:
    out_dir = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parent.parent / "StrandiOS" / "Resources"
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, build in SOUNDS.items():
        write_wav(out_dir / name, build())
        print(f"wrote {out_dir / name}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
