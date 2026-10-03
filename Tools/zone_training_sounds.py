#!/usr/bin/env python3
"""Generate the Zone training notification sounds (StrandiOS/Resources/zone-*.wav).

NOOP's own tones, synthesised here so the assets have a known origin and can be rebuilt byte-for-byte:

  zone-increase.wav  below the zone  -> two short tones stepping UP   (pairs with the strap's 2 light taps)
  zone-decrease.wav  above the zone  -> three short tones stepping DOWN (pairs with the 3 heavier taps)
  zone-in.wav        back in the zone -> one soft chime                 (pairs with the single tap)

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


def sequence(freqs: list[float], length: float, gap: float) -> list[float]:
    samples: list[float] = []
    for k, f in enumerate(freqs):
        if k:
            samples += silence(gap)
        samples += tone(f, length)
    return samples


# Up a fifth: E5 -> B5.
INCREASE_HZ = [659.25, 987.77]
# Down a triad: B5 -> G5 -> D5.
DECREASE_HZ = [987.77, 783.99, 587.33]

SOUNDS = {
    "zone-increase.wav": lambda: sequence(INCREASE_HZ, 0.14, 0.07),
    "zone-decrease.wav": lambda: sequence(DECREASE_HZ, 0.14, 0.07),
    # A single soft G5 chime with a gentle decay.
    "zone-in.wav": lambda: tone(783.99, 0.45, overtone=0.25, decay=5.0),
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
