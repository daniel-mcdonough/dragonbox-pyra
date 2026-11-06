#!/usr/bin/env python3
# Read or switch the GPU functional-clock source mux in CM_GPU_GPU_CLKCTRL (TRM Table 3-1245).
#   gpumux.py get
#   gpumux.py set core|per     bits 24 (CORE_GCLK) and 25 (HYD_GCLK) together; waits for module idle
import mmap, os, struct, sys, time

CLKCTRL = 0x4A009520
H14_CORE = 0x4A004144
H14_PER = 0x4A008164
SEL = (1 << 24) | (1 << 25)

fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
pages = {}

def page(a):
    base = a & ~0xFFF
    if base not in pages:
        pages[base] = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
    return pages[base], a - base

def rd(a):
    m, o = page(a)
    return struct.unpack("<I", m[o:o + 4])[0]

def wr(a, v):
    m, o = page(a)
    m[o:o + 4] = struct.pack("<I", v)

def describe():
    c = rd(CLKCTRL)
    src = {0: "core", SEL: "per"}.get(c & SEL, "mixed")
    # DIVHS 63 is a special code: /2.5 then /2, so /5 overall (TRM Table 3-880).
    div = lambda r: 5 if (r & 0x3F) == 63 else (r & 0x3F)
    mhz = 2127.36 / div(rd(H14_CORE)) if src == "core" else 768.0 / div(rd(H14_PER))
    return f"CLKCTRL={c:#010x} source={src} idlest={(c >> 16) & 3} -> {mhz:.1f} MHz"

if sys.argv[1] == "get":
    print(describe())
elif sys.argv[1] == "set":
    want = SEL if sys.argv[2] == "per" else 0
    # Switch only while the module reports idle (IDLEST 2): the functional clocks are cut then.
    deadline = time.time() + 5
    while (rd(CLKCTRL) >> 16) & 3 != 2 and time.time() < deadline:
        pass
    c = rd(CLKCTRL)
    wr(CLKCTRL, (c & ~SEL) | want)
    print("set:", describe())
