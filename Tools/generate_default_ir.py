#!/usr/bin/env python3
"""
Generates Resources/IR/AlnicoBlue_2x12.wav - a SYNTHETIC, minimum-phase impulse
response approximating a close-miked (dynamic mic, cap-edge) open-back 2x12
cabinet loaded with Celestion Alnico Blue speakers, as found in a Vox AC30.

It is a stand-in so that the project builds and sounds right out of the box.
For the most authentic result replace the file with a measured IR (e.g. the
official Celestion "Alnico Blue" IRs) - keep the same file name, or load it at
runtime with the "IR" button in the app.

Target response (published Alnico Blue curve + open-back behaviour):
  - speaker resonance ~75 Hz, open-back low-end cancellation below ~90 Hz
  - smooth, slightly scooped low mids, upper-mid "chime" peaks at ~2.3 kHz and ~4 kHz
  - steep roll-off above ~5.5 kHz with cone break-up ripples
  - rear-wave (open back) and floor reflections

Requires only numpy.  Usage:  python3 Tools/generate_default_ir.py [out.wav]
"""
import math
import struct
import sys
import wave
from pathlib import Path

import numpy as np

FS = 48000
LENGTH = 2048          # ~43 ms


def biquad(kind, f0, q, gain_db=0.0, fs=FS):
    a = 10 ** (gain_db / 40)
    w = 2 * math.pi * f0 / fs
    c, s = math.cos(w), math.sin(w)
    al = s / (2 * q)
    if kind == "lp":
        b = [(1 - c) / 2, 1 - c, (1 - c) / 2]; d = [1 + al, -2 * c, 1 - al]
    elif kind == "hp":
        b = [(1 + c) / 2, -(1 + c), (1 + c) / 2]; d = [1 + al, -2 * c, 1 - al]
    elif kind == "peak":
        b = [1 + al * a, -2 * c, 1 - al * a]; d = [1 + al / a, -2 * c, 1 - al / a]
    else:
        raise ValueError(kind)
    return np.array(b) / d[0], np.array(d) / d[0]


def lfilter(b, a, x):
    y = np.zeros_like(x)
    s1 = s2 = 0.0
    for n, xn in enumerate(x):
        yn = b[0] * xn + s1
        s1 = b[1] * xn - a[1] * yn + s2
        s2 = b[2] * xn - a[2] * yn
        y[n] = yn
    return y


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "Resources" / "IR" / "AlnicoBlue_2x12.wav"

    x = np.zeros(LENGTH)
    x[0] = 1.0

    # Direct sound + open-back rear wave (inverted, delayed) + floor bounce
    x[int(0.00085 * FS)] -= 0.28
    x[int(0.0031 * FS)] += 0.12
    x[int(0.0057 * FS)] -= 0.05

    stages = [
        ("hp", 70.0, 0.9, 0.0),       # open-back cancellation / Fs region
        ("hp", 55.0, 0.7, 0.0),
        ("peak", 110.0, 1.2, 2.5),     # resonance bump (12" Alnico, ~75-110 Hz loaded)
        ("peak", 450.0, 0.8, -2.0),    # low-mid scoop
        ("peak", 1200.0, 2.0, 1.5),
        ("peak", 2300.0, 2.2, 4.5),    # "chime"
        ("peak", 4000.0, 3.0, 4.0),    # presence peak
        ("peak", 3100.0, 5.0, -3.0),   # cone break-up notch
        ("lp", 5600.0, 0.9, 0.0),      # steep upper roll-off (4th order)
        ("lp", 6200.0, 0.6, 0.0),
        ("peak", 7400.0, 6.0, -6.0),   # break-up ripple
        ("lp", 9000.0, 0.7, 0.0),
    ]
    for kind, f0, q, g in stages:
        b, a = biquad(kind, f0, q, g)
        x = lfilter(b, a, x)

    # Gentle fade-out to avoid truncation clicks
    fade = int(0.25 * LENGTH)
    x[-fade:] *= 0.5 * (1 + np.cos(np.linspace(0, math.pi, fade)))
    x /= np.max(np.abs(x)) * 1.05

    out.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(out), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(3)
        w.setframerate(FS)
        frames = bytearray()
        for v in x:
            i = int(round(v * 8388607))
            frames += struct.pack("<i", i)[:3]
        w.writeframes(bytes(frames))

    print(f"wrote {out} ({LENGTH} samples @ {FS} Hz)")


if __name__ == "__main__":
    main()
