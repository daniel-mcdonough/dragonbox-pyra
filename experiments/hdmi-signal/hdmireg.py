#!/usr/bin/env python3
# Read/write OMAP5 HDMI registers through /dev/mem (devmem2 on trixie is broken).
# hdmireg.py dump            wp, pll, phy blocks
# hdmireg.py r ADDR [N]      N words from ADDR
# hdmireg.py w ADDR VAL      write a word
# hdmireg.py f ADDR HI LO V  set bits HI..LO of ADDR to V
import mmap, os, struct, sys
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
maps = {}
def page(a):
    b = a & ~0xfff
    if b not in maps:
        maps[b] = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=b)
    return maps[b], a & 0xfff
def rd(a):
    m, o = page(a); return struct.unpack("<I", m[o:o+4])[0]
def wr(a, v):
    m, o = page(a); m[o:o+4] = struct.pack("<I", v & 0xffffffff)
def show(a, n):
    for i in range(0, n, 4):
        print("%08x:" % (a + i*4), " ".join("%08x" % rd(a + (i+j)*4) for j in range(min(4, n-i))))
c = sys.argv[1]; x = lambda s: int(s, 0)
if c == "dump":
    for name, a, n in (("wp", 0x58040000, 0x30), ("pll", 0x58040200, 0x20), ("phy", 0x58040300, 0x8)):
        print("--", name); show(a, n)
elif c == "r": show(x(sys.argv[2]), x(sys.argv[3]) if len(sys.argv) > 3 else 1)
elif c == "w": wr(x(sys.argv[2]), x(sys.argv[3])); show(x(sys.argv[2]), 1)
elif c == "f":
    a, hi, lo, v = map(x, sys.argv[2:6]); mask = ((1 << (hi-lo+1)) - 1) << lo
    wr(a, (rd(a) & ~mask) | ((v << lo) & mask)); show(a, 1)
