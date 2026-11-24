#!/usr/bin/env python3
"""Level analysis of a capture from the Pyra (R103). Run on the PC.

    analyse.py clip.wav [--window S] [--bands T0-T1 ...] [--peaks]

Per channel: RMS/peak per window, then the share of energy per frequency band
after the first 0.5 s (skips the stream-start click). --bands prints band
levels for the given time ranges (e.g. quiet 1-9 against speech 11-19).
--peaks lists the strongest spectral lines (finds a test tone that came out at
the wrong pitch). WAV S16 or S32, any rate.
"""
import argparse
import wave

import numpy as np

BANDS = [(40, 100), (100, 300), (300, 1000), (1000, 3000), (3000, 8000), (8000, 20000)]


def db(x):
    return 20 * np.log10(max(x, 1e-12))


def load(path):
    w = wave.open(path)
    sw, ch, sr = w.getsampwidth(), w.getnchannels(), w.getframerate()
    a = np.frombuffer(w.readframes(w.getnframes()), dtype={2: np.int16, 4: np.int32}[sw])
    return a.reshape(-1, ch).astype(float) / 2 ** (8 * sw - 1), sr


def band_db(s, sr):
    s = s - s.mean()
    sp = np.abs(np.fft.rfft(s * np.hanning(len(s)))) ** 2 / len(s)
    f = np.fft.rfftfreq(len(s), 1 / sr)
    return [10 * np.log10(sp[(f >= lo) & (f < hi)].sum() + 1e-30) for lo, hi in BANDS]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("wav")
    p.add_argument("--window", type=float, default=1.0)
    p.add_argument("--bands", nargs="*", default=[])
    p.add_argument("--peaks", action="store_true")
    o = p.parse_args()
    a, sr = load(o.wav)
    n = int(sr * o.window)
    print(f"{o.wav}: {sr} Hz, {a.shape[1]} ch, {len(a) / sr:.1f} s")
    for c in range(a.shape[1]):
        x = a[:, c]
        rows = [(i / sr, x[i:i + n]) for i in range(0, len(x) - n + 1, n)]
        print(f"ch{c} rms/peak dBFS per {o.window}s: " +
              " ".join(f"{t:.0f}:{db(np.sqrt(np.mean((s - s.mean()) ** 2))):.0f}/{db(np.abs(s).max()):.0f}"
                       for t, s in rows))
        st = x[int(0.5 * sr):] - x[int(0.5 * sr):].mean()
        sp = np.abs(np.fft.rfft(st * np.hanning(len(st)))) ** 2
        f = np.fft.rfftfreq(len(st), 1 / sr)
        edges = BANDS + [(20000, sr / 2)]
        print(f"  after 0.5 s: rms {db(np.sqrt(np.mean(st ** 2))):.1f} dBFS; share " +
              " ".join(f"{lo}-{hi:.0f}:{100 * sp[(f >= lo) & (f < hi)].sum() / sp.sum():.0f}%" for lo, hi in edges))
        for r in o.bands:
            t0, t1 = (float(v) for v in r.split("-"))
            seg, m = x[int(t0 * sr):int(t1 * sr)], sr // 2
            b = np.mean([band_db(seg[i:i + m], sr) for i in range(0, len(seg) - m, m)], axis=0)
            print(f"  bands {r:>7}s: " + " ".join(f"{lo}-{hi}:{v:.1f}" for (lo, hi), v in zip(BANDS, b)))
        if o.peaks:
            amp = np.sqrt(sp) / (len(st) / 4)
            idx = np.where((f > 50) & (f < 20000))[0]
            top = idx[np.argsort(amp[idx])[-5:]][::-1]
            print("  strongest lines: " + ", ".join(f"{f[k]:.0f} Hz {db(amp[k] / np.sqrt(2)):.0f} dBFS" for k in top))


if __name__ == "__main__":
    main()
