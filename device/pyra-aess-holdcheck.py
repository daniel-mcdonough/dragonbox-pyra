#!/usr/bin/env python3
"""Is the DL1 signal already held at 2666.67 Hz when it reaches DMEM?

If the output updates only every 36 McPDM frames, a 20-frame snapshot of the
downlink FIFO is mostly runs of identical samples. If it updates every frame,
every sample differs. This distinguishes a fault before DMEM from one after.
"""
import mmap, os, struct, sys, time
DMEM, OFF, NB = 0x40180000, 0x3800, 480
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x10000, mmap.MAP_SHARED, mmap.PROT_READ, offset=DMEM)
def s24(v):
    v >>= 8
    return v - (1 << 24) if v & (1 << 23) else v
runs, tot, frames = [], 0, 0
for _ in range(int(sys.argv[1]) if len(sys.argv) > 1 else 200):
    w = [struct.unpack_from("<I", m, OFF + j)[0] for j in range(0, NB-3, 4)]
    L = [s24(w[i*6]) for i in range(len(w)//6)]
    frames += len(L)
    r = 1
    for a, b in zip(L, L[1:]):
        if a == b:
            r += 1
        else:
            runs.append(r); r = 1
    runs.append(r); tot += 1
    time.sleep(0.002)
n = len(runs); avg = sum(runs)/n
print("snapshots %d, frames %d" % (tot, frames))
print("runs of identical consecutive samples: %d, mean length %.2f" % (n, avg))
hist = {}
for r in runs:
    hist[r] = hist.get(r, 0) + 1
for k in sorted(hist)[:8]:
    print("   run of %2d : %5d" % (k, hist[k]))
print("longest run: %d" % max(runs))
print()
print("mean run 1.0  -> a new sample every McPDM frame (96 kHz): healthy")
print("mean run ~36  -> held at 2666.67 Hz already in DMEM: the fault is in")
print("                 the AESS, before the ATC")
