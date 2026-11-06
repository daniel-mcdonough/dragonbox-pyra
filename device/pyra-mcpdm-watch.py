#!/usr/bin/env python3
"""Watch the McPDM downlink for underruns while something plays.

IRQSTATUS_RAW is read-only-ish: reading it does not clear anything, unlike
DN_DATA/UP_DATA which pop the FIFO. DN_IRQ_EMPTY means the hardware FIFO ran
dry -- the transmitter had nothing to send. That is what a steady tone
breaking up sounds like.

    sudo ./pyra-mcpdm-watch.py [seconds]        default 3
"""
import mmap, os, struct, sys, time
BASE = 0x40132000
IRQSTATUS_RAW, CTRL, FIFO_CTRL_DN, DN_OFFSET = 0x24, 0x44, 0x50, 0x58
SECS = float(sys.argv[1]) if len(sys.argv) > 1 else 3.0
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=BASE)
r = lambda o: struct.unpack_from("<I", m, o)[0]

print("CTRL         0x%04x" % r(CTRL))
print("FIFO_CTRL_DN 0x%04x  (downlink threshold)" % r(FIFO_CTRL_DN))
print("DN_OFFSET    0x%08x" % r(DN_OFFSET))

BITS = [(0, "DN_IRQ"), (1, "DN_EMPTY  <-- underrun"), (2, "DN_ALMOST_EMPTY"),
        (3, "DN_FULL")]
counts = {b: 0 for b, _ in BITS}
n = 0
t0 = time.time()
prev = 0
while time.time() - t0 < SECS:
    v = r(IRQSTATUS_RAW)
    for b, _ in BITS:
        if (v >> b) & 1 and not (prev >> b) & 1:
            counts[b] += 1
    prev = v
    n += 1
el = time.time() - t0
print("\npolled %d times over %.2f s (%.0f/s)" % (n, el, n/el))
for b, name in BITS:
    print("  %-22s asserted %5d times  (%.1f/s)" % (name, counts[b], counts[b]/el))
