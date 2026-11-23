#!/usr/bin/env python3
# analyse.py REC.wav [dB]: finds broadband events in a recording of the
# headphone output. Splits the left channel into 20 ms frames, sums the
# 3-16 kHz energy (the test beep is 440 Hz, so only noise and edges land
# there), and lists runs of frames more than dB (default 10) above the median.
# A burst of 0.2 s or more is a run of 10 frames or more.
import sys, wave
import numpy as np

w = wave.open(sys.argv[1])
x = np.frombuffer(w.readframes(w.getnframes()), np.int16).reshape(-1, w.getnchannels())[:, 0] / 32768
r = w.getframerate(); win = r // 50
n = len(x) // win; fr = x[:n * win].reshape(n, win) * np.hanning(win)
F = np.abs(np.fft.rfft(fr, axis=1)) ** 2; f = np.fft.rfftfreq(win, 1 / r)
hb = 10 * np.log10(F[:, (f > 3000) & (f < 16000)].sum(1) + 1e-12)
med = np.median(hb); thr = float(sys.argv[2]) if len(sys.argv) > 2 else 10
print(f"frames {n}, HF median {med:.1f} dB, max +{hb.max() - med:.1f} dB; peak {abs(x).max():.4f}")
ev = np.where(hb > med + thr)[0]
runs = np.split(ev, np.where(np.diff(ev) > 1)[0] + 1) if len(ev) else []
for g in runs:
    print(f"  +{hb[g].max() - med:.1f} dB at {g[0] * 0.02:.2f}-{(g[-1] + 1) * 0.02:.2f}s ({len(g) * 20} ms)")
print(f"longest run {max((len(g) for g in runs), default=0) * 20} ms")
