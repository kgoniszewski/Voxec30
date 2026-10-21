#!/usr/bin/env python3
"""Generuje ikonę aplikacji i dźwięki (alarmy, sygnały) dla projektu Janek.

Uruchomienie z katalogu Janek/:  python3 Tools/generate_assets.py
Wymaga Pillow (pip install pillow) do ikony; dźwięki tylko biblioteki standardowej.
"""
import math
import os
import struct
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOUNDS = os.path.join(ROOT, "Janek", "Resources", "Sounds")
ICON = os.path.join(ROOT, "Janek", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
RATE = 44100


def write_wav(name, samples):
    os.makedirs(SOUNDS, exist_ok=True)
    with wave.open(os.path.join(SOUNDS, name), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32000)) for s in samples))


def tone(freqs, duration, volume=0.6, attack=0.005, release=0.08, partials=(1.0,)):
    n = int(RATE * duration)
    out = []
    for i in range(n):
        t = i / RATE
        env = min(1.0, t / attack) * min(1.0, (duration - t) / release)
        v = 0.0
        for f in freqs:
            for k, amp in enumerate(partials, start=1):
                v += amp * math.sin(2 * math.pi * f * k * t)
        out.append(volume * env * v / (len(freqs) * sum(partials)))
    return out


def silence(duration):
    return [0.0] * int(RATE * duration)


def bell(freq, duration, volume=0.7):
    n = int(RATE * duration)
    partials = [(1.0, 1.0), (2.0, 0.5), (2.76, 0.35), (5.4, 0.15)]
    return [volume * math.exp(-3.2 * i / RATE) * sum(a * math.sin(2 * math.pi * freq * p * i / RATE) for p, a in partials) / 2.0
            for i in range(n)]


def main():
    # Klasyczny budzik: podwójne piknięcia powtarzane przez ~20 s.
    beep = tone([1046.5], 0.12, 0.8, release=0.02, partials=(1.0, 0.3))
    pattern = beep + silence(0.08) + beep + silence(0.6)
    write_wav("janek_alarm.wav", pattern * 20)

    # Łagodne dzwonki: arpeggio C-dur, narastające.
    gentle = []
    for rep in range(6):
        for f in (523.25, 659.25, 783.99, 1046.5):
            gentle += [s * (0.4 + 0.1 * rep) for s in bell(f, 0.45)]
        gentle += silence(0.6)
    write_wav("janek_gentle.wav", gentle)

    # Leki: dwa łagodne tony co 2 s.
    pills = []
    for _ in range(8):
        pills += bell(880, 0.35) + bell(1318.5, 0.6) + silence(1.0)
    write_wav("janek_pills.wav", pills)

    # Sygnały: początek słuchania (w górę) i koniec (w dół).
    write_wav("janek_listen.wav", tone([880], 0.07, 0.5) + tone([1318.5], 0.1, 0.5))
    write_wav("janek_done.wav", tone([1318.5], 0.07, 0.4) + tone([880], 0.1, 0.4))

    make_icon()


def make_icon():
    try:
        from PIL import Image, ImageDraw, ImageFilter
    except ImportError:
        print("Pillow niedostępny – pomijam ikonę")
        return
    size = 1024
    img = Image.new("RGB", (size, size))
    px = img.load()
    top, bottom = (88, 86, 214), (0, 122, 255)
    for y in range(size):
        k = y / (size - 1)
        row = tuple(int(top[c] + (bottom[c] - top[c]) * k) for c in range(3))
        for x in range(size):
            px[x, y] = row
    glow = Image.new("L", (size, size), 0)
    ImageDraw.Draw(glow).ellipse((212, 212, 812, 812), fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(60))
    img = Image.composite(Image.new("RGB", (size, size), (130, 200, 255)), img, glow.point(lambda v: v * 0.45))
    draw = ImageDraw.Draw(img)
    heights = [180, 320, 470, 600, 470, 320, 180]
    bar_w, gap = 70, 34
    total = len(heights) * bar_w + (len(heights) - 1) * gap
    x = (size - total) // 2
    for h in heights:
        draw.rounded_rectangle((x, (size - h) // 2, x + bar_w, (size + h) // 2), radius=bar_w // 2, fill=(255, 255, 255))
        x += bar_w + gap
    os.makedirs(os.path.dirname(ICON), exist_ok=True)
    img.save(ICON)


if __name__ == "__main__":
    main()
