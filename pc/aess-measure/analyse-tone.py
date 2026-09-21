#!/usr/bin/env python3
"""Characterise a tone recorded from the Pyra's analogue output.

    analyse-tone.py <recording.wav> <source Hz> [label]

The Pyra's headphone jack goes into a PC line input; record with parecord and
point this at the file. It finds the steady part of the tone, then reports the
fundamental and every image at n * 2666.67 +/- f0 -- the signature of the DL1
path being resampled at 96000/36 Hz somewhere after DMEM. A healthy path puts
those 85 dB or more below the tone; the AESS path puts the worst of them
within 6 dB of it.

Record with headroom. The first attempt at this clipped the line input at
0.9999 FS and every number it produced was worthless.
"""
import sys, wave, numpy as np

FM = 96000 / 36.0


def analyse(fn, f0, label=None):
    w = wave.open(fn)
    fs = w.getframerate()
    d = np.frombuffer(w.readframes(w.getnframes()),
                      dtype='<i2').reshape(-1, w.getnchannels())
    x = d[:, 0].astype(float) / 32768.0
    if np.max(np.abs(x)) > 0.98:
        print("WARNING: %s reaches %.4f FS -- the input is clipping"
              % (fn, np.max(np.abs(x))))

    # The steady middle of the burst: the open and close pops are large and
    # the DC-blocking settles for about a second after each.
    B = int(fs * 0.05)
    env = np.sqrt(np.mean((x - x.mean())[:len(x)//B*B].reshape(-1, B)**2, axis=1))
    hi = np.where(env > env.max() * 0.12)[0]
    a, b = hi[0]*B, (hi[-1]+1)*B
    mid = (a + b) // 2
    half = int(min((b - a) * 0.2, 0.75 * fs))
    s = x[mid-half:mid+half].astype(float)
    s -= s.mean()
    N = 1 << int(np.floor(np.log2(len(s))))
    s = s[:N]

    sp = np.abs(np.fft.rfft(s * np.hanning(N))) / N * 2
    f = np.fft.rfftfreq(N, 1/fs)
    sel = f > 60                      # ignore DC and mains-frequency drift
    ref = sp[sel].max()

    def at(fc, hw=18.0):
        m = (f > fc-hw) & (f < fc+hw)
        return 20*np.log10(max(np.max(sp[m]), 1e-12) / ref)

    print("\n=== %s  (source %d Hz, window %.2f-%.2f s)"
          % (label or fn, f0, (mid-half)/fs, (mid+half)/fs))
    print("    fundamental        %7.1f dB" % at(f0))
    worst = None
    for n in range(1, 5):
        for sgn in (-1, 1):
            v = abs(n*FM + sgn*f0)
            if not 60 < v < fs/2 - 100:
                continue
            db = at(v)
            if worst is None or db > worst[1]:
                worst = (v, db)
            print("    %d x %.1f %s %-5d = %8.1f Hz  %7.1f dB"
                  % (n, FM, '+' if sgn > 0 else '-', f0, v, db))
    band = lambda lo, hi_: float(np.sum(sp[(f >= lo) & (f < hi_)]**2))
    tp = band(f0-25, f0+25)
    junk = band(60, fs/2) - tp
    print("    worst image        %7.1f dB at %.1f Hz" % (worst[1], worst[0]))
    print("    everything else    %+7.1f dB relative to the tone"
          % (10*np.log10(junk/tp)))


if __name__ == "__main__":
    analyse(sys.argv[1], float(sys.argv[2]),
            sys.argv[3] if len(sys.argv) > 3 else None)
