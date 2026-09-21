#!/usr/bin/env python3
"""Play a 1 Hz sawtooth and watch the DSP's output for buffer sequencing faults.

The sample value is a clock: it should rise linearly and wrap once a second.
A ping-pong buffer replayed, skipped or torn shows as a jump that does not fit
that line. Reports every jump bigger than one ALSA period's worth of ramp.
"""
import mmap, os, struct, sys, time
DMEM, FIFO_OFF, FIFO_BYTES = 0x40180000, 0x3800, 480
SECS = float(sys.argv[1]) if len(sys.argv) > 1 else 3.0
PERIOD_FRAMES = int(sys.argv[2]) if len(sys.argv) > 2 else 1536
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x10000, mmap.MAP_SHARED, mmap.PROT_READ, offset=DMEM)
FS24 = float(1 << 23)

def s24(v):
    v >>= 8
    return v - (1 << 24) if v & (1 << 23) else v

# one period of ramp, as a fraction of full scale: 1 Hz over 48000 frames,
# peak-to-peak 1.0 FS (vol 0.5 => -0.5..+0.5)
STEP = PERIOD_FRAMES / 48000.0
log = []
t0 = time.time()
while time.time() - t0 < SECS:
    v = struct.unpack_from("<I", m, FIFO_OFF)[0]
    log.append((time.time() - t0, s24(v) / FS24))
    time.sleep(0.0002)

print("polls %d over %.2f s (%.0f/s)" % (len(log), log[-1][0], len(log)/log[-1][0]))
print("one ALSA period = %.1f ms = %.3f of the ramp" % (STEP*1000, STEP))
jumps, wraps = [], 0
for (t1, v1), (t2, v2) in zip(log, log[1:]):
    dt = t2 - t1
    d = v2 - v1
    if d < -0.5:                      # the once-a-second wrap
        wraps += 1
        continue
    expected = dt * 1.0               # 1.0 FS per second
    err = d - expected
    if abs(err) > STEP * 0.5:
        jumps.append((t2, err, err / STEP))
print("ramp wraps seen  : %d (expect ~%.0f)" % (wraps, SECS))
print("sequencing jumps : %d" % len(jumps))
for t, err, per in jumps[:25]:
    print("   t=%6.3f s  jump %+.4f FS = %+.2f periods  (%s)"
          % (t, err, per, "REPLAYED" if per < 0 else "SKIPPED"))
if jumps:
    gaps = [b[0]-a[0] for a, b in zip(jumps, jumps[1:])]
    if gaps:
        gaps.sort()
        g = gaps[len(gaps)//2]
        print("median gap between jumps: %.1f ms (%.1f Hz, %.2f periods)"
              % (g*1000, 1/g if g else 0, g/STEP))
