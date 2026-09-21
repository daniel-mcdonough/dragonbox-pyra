#!/usr/bin/env python3
"""Fit the McPDM DL FIFO contents to a sine: frequency and amplitude.

For a pure sine sampled at fs,  x[n+1] - 2x[n] + x[n-1] = -w^2 x[n],
so w^2 = -sum(d2 * x) / sum(x*x) over the contiguous part of a snapshot.
Amplitude follows from A^2 = x^2 + (dx/w)^2.
"""
import mmap, os, struct, sys, time, math
DMEM = 0x40180000
FIFO_OFF, FIFO_BYTES = 0x3800, 480      # map id 12
FS = 96000.0
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x10000, mmap.MAP_SHARED, mmap.PROT_READ, offset=DMEM)

def s24(v):
    v >>= 8
    return v - (1 << 24) if v & (1 << 23) else v

def snap():
    w = [struct.unpack_from("<I", m, FIFO_OFF + j)[0]
         for j in range(0, FIFO_BYTES - 3, 4)]
    return [s24(w[i * 6]) for i in range(len(w) // 6)]     # slot 0 = DL1 left

freqs, amps, peak = [], [], 0
for _ in range(int(sys.argv[1]) if len(sys.argv) > 1 else 60):
    x = snap()
    peak = max(peak, max(abs(v) for v in x))
    # longest run without the ring-buffer discontinuity: drop the worst point
    d2 = [x[i+1] - 2*x[i] + x[i-1] for i in range(1, len(x)-1)]
    body = [(x[i], d2[i-1]) for i in range(1, len(x)-1)]
    med = sorted(abs(d) for _, d in body)[len(body)//2]
    body = [(v, d) for v, d in body if abs(d) < 8 * max(med, 1)]
    num = -sum(d * v for v, d in body)
    den = sum(v * v for v, _ in body)
    if den <= 0 or num <= 0 or len(body) < 8:
        continue
    w = math.sqrt(num / den)
    f = w * FS / (2 * math.pi)
    dx = [x[i+1] - x[i] for i in range(len(x)-1)]
    mdx = sorted(abs(d) for d in dx)[len(dx)//2]
    cand = [math.sqrt(v*v + (d/w)**2) for v, d in zip(x[:-1], dx)
            if abs(d) < 4 * max(mdx, 1)]
    if not cand:
        continue
    a = sorted(cand)[len(cand)//2]
    freqs.append(f); amps.append(a)
    time.sleep(0.01)

freqs.sort(); amps.sort()
FS24 = float(1 << 23)
print("snapshots fitted : %d" % len(freqs))
if freqs:
    print("frequency        : %.2f Hz (median of fits)" % freqs[len(freqs)//2])
    a = amps[len(amps)//2]
    print("amplitude        : %.0f = %.4f FS = %.2f dBFS"
          % (a, a / FS24, 20 * math.log10(a / FS24)))
print("largest |sample| : %d = %.4f FS = %.2f dBFS"
      % (peak, peak / FS24, 20 * math.log10(peak / FS24) if peak else -999))
