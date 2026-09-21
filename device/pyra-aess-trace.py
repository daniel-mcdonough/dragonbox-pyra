#!/usr/bin/env python3
"""pyra-aess-trace.py -- where does the audio stop inside the AESS?

    sudo ./pyra-aess-trace.py sweep      every mapped buffer, and what is live
    sudo ./pyra-aess-trace.py fifo       the McPDM downlink FIFO, as 6-slot frames
    sudo ./pyra-aess-trace.py gains      the live gain targets in SMEM
    sudo ./pyra-aess-trace.py sched      the DSP's MultiFrame task schedule

Run any of these while something is playing; they say nothing useful idle.
Everything here is read-only.

Two rules this file exists to encode, both learned by breaking them:

  * ALL ABE memory access must be aligned 32-bit. A byte-wise slice read
    raises an asynchronous external abort, and because it is ASYNCHRONOUS it
    surfaces at whatever access happens next and blames that one instead.
    Six aborts were traced to exactly this, after two wrong diagnoses.

  * Sample a WHOLE buffer before calling it dead. The McPDM FIFO was twice
    written off as "frozen, all zero" from a 32-word window; over its full
    120 words it was carrying audio the entire time.

Buffer addresses come from the firmware's own label map, never from a
constant typed in here and never from the device tree -- the DT had the bank
sizes wrong, which is what made an in-kernel memcpy run off the end of an
ioremap in patch 0018.
"""
import mmap, os, struct, sys, time

FW = "/lib/firmware/omap_aess-adfw.bin"
BASE = {0: 0x40180000, 1: 0x401A0000, 2: 0x401C0000, 3: 0x401E0000}
SAFE = {0: 0x10000, 1: 7852, 2: 21600, 3: 8192}   # measured on hardware
BN = {0: "DMEM", 1: "CMEM", 2: "SMEM", 3: "PMEM"}

# aess-fw.h map ids worth naming. The _LP_ ones are the low-power path.
NAMED = {0: "MULTIFRAME", 12: "MCPDM_DL_FIFO", 31: "MM_DL", 44: "BT_DL",
         46: "BT_DL_48_8_HP", 47: "BT_DL_48_8_LP", 51: "DL1_M_EQ",
         52: "EARP_48_96_LP", 53: "IHF_48_96_LP", 57: "GTARGET1",
         73: "PING", 74: "DEBUG_FIFO", 77: "LOOPCOUNTER"}

GAINS = {0: "DMIC1_L", 1: "DMIC1_R", 2: "DMIC2_L", 3: "DMIC2_R",
         4: "DMIC3_L", 5: "DMIC3_R", 6: "AMIC_L", 7: "AMIC_R",
         8: "DL1_L", 9: "DL1_R", 10: "DL2_L", 11: "DL2_R",
         12: "SPLIT_L", 13: "SPLIT_R"}
UNITY = 0x00040000


def load_map():
    d = open(FW, "rb").read()
    off, bl = 0, {}
    while off < len(d):
        _m, _a, t, _vt, _v, sz = struct.unpack_from("<6I", d, off)
        bl.setdefault(t, []).append(d[off + 24:off + 24 + sz])
        off += 24 + sz
    cfg = bl[1001][0]
    n = struct.unpack_from("<I", cfg, 0)[0]
    return [struct.unpack_from("<iII", cfg, (1 + i * 3) * 4) for i in range(n)]


MAP = load_map()
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
MM = {b: mmap.mmap(fd, 0x10000, mmap.MAP_SHARED, mmap.PROT_READ, offset=BASE[b])
      for b in BASE}


def words(i, cap=4096):
    bank, off, by = MAP[i]
    if bank not in BN or by == 0 or off + by > SAFE[bank]:
        return None
    by = min(by, cap)
    m = MM[bank]
    return [struct.unpack_from("<I", m, off + j)[0] for j in range(0, by - 3, 4)]


def s24(v):
    """The ABE stores 24-bit samples left-justified in a 32-bit word."""
    v >>= 8
    return v - (1 << 24) if v & (1 << 23) else v


def sweep():
    a = [words(i) for i in range(len(MAP))]
    time.sleep(0.4)
    b = [words(i) for i in range(len(MAP))]
    print("%-4s %-16s %-5s %-8s %-6s %-8s %s"
          % ("id", "name", "bank", "offset", "words", "non-zero", "changed/0.4s"))
    for i, (x, y) in enumerate(zip(a, b)):
        if x is None:
            continue
        ch = sum(1 for p, q in zip(x, y) if p != q)
        if not ch:
            continue
        bank, off, _by = MAP[i]
        print("%-4d %-16s %-5s 0x%06x %-6d %-8d %d"
              % (i, NAMED.get(i, ""), BN[bank], off, len(y),
                 sum(1 for q in y if q), ch))
    print("\nOnly buffers that changed are listed. A path that is running shows a")
    print("continuous chain; the first silent link is where to look.")


def fifo():
    w = words(12)
    if w is None:
        sys.exit("McPDM DL FIFO not mapped")
    print("McPDM downlink FIFO, %d words, as 6-slot frames." % len(w))
    print("Slots carrying +/-0x7fffff or 0x800000 every sample are SATURATED:")
    print("that is a full-scale pattern at Nyquist, which is inaudible.\n")
    for r in range(min(12, len(w) // 6)):
        fr = w[r * 6:(r + 1) * 6]
        print("  " + " ".join("%08x" % v for v in fr)
              + "   " + " ".join("%+8d" % s24(v) for v in fr))


def gains():
    w = words(57)
    if w is None:
        sys.exit("GTARGET1 not mapped")
    for i, v in enumerate(w):
        note = "UNITY" if v == UNITY else ("zero/mute" if v == 0 else "")
        print("  %-10s id %2d  0x%08x  %s" % (GAINS.get(i, "?"), i, v, note))


def sched():
    w = words(0)
    u16 = []
    for x in w:
        u16 += [x & 0xFFFF, (x >> 16) & 0xFFFF]
    print("MultiFrame is u16[25][8]; %d of %d slots hold a task."
          % (sum(1 for x in u16 if x), len(u16)))
    for f in range(25):
        row = u16[f * 8:(f + 1) * 8]
        if any(row):
            print("  frame %-2d  %s" % (f, " ".join("%04x" % v for v in row)))


{"sweep": sweep, "fifo": fifo, "gains": gains, "sched": sched}[
    sys.argv[1] if len(sys.argv) > 1 else "sweep"]()
