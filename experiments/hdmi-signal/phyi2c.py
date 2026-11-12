#!/usr/bin/env python3
# Probe the OMAP5 HDMI core's PHY I2C master (DesignWare HDMI TX), read-only on the far side.
# Run only while HDMI holds a mode: the core at 0x58060000 is unclocked when the encoder is suspended.
# The core spaces dw-hdmi's byte registers 4 bytes apart (dw offset * 4).
# phyi2c.py regs                 dump the core's PHY and I2CM registers
# phyi2c.py read SLAVE REG...    I2C reads through the PHY I2C master (dw-hdmi PHY GEN2: 0x69, HEAC: 0x49)
import mmap, os, struct, sys, time
CORE = 0x58060000
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x20000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=CORE)
def rd(dw): o = dw * 4; return struct.unpack("<I", m[o:o+4])[0] & 0xff
def wr(dw, v): o = dw * 4; m[o:o+4] = struct.pack("<I", v & 0xff)
REGS = (("IH_PHY_STAT0", 0x0104), ("IH_I2CMPHY_STAT0", 0x0108), ("IH_MUTE_I2CMPHY_STAT0", 0x0188),
        ("IH_MUTE", 0x01ff), ("PHY_CONF0", 0x3000), ("PHY_TST0", 0x3001), ("PHY_STAT0", 0x3004),
        ("PHY_MASK0", 0x3006), ("I2CM_SLAVE", 0x3020), ("I2CM_ADDRESS", 0x3021),
        ("I2CM_DATAI_1", 0x3024), ("I2CM_DATAI_0", 0x3025), ("I2CM_OPERATION", 0x3026),
        ("I2CM_INT", 0x3027), ("I2CM_CTLINT", 0x3028), ("I2CM_DIV", 0x3029), ("MC_PHYRSTZ", 0x4005))
STAT, SLAVE, ADDR, DI1, DI0, OP = 0x0108, 0x3020, 0x3021, 0x3024, 0x3025, 0x3026
c = sys.argv[1]; x = lambda s: int(s, 0)
if c == "regs":
    for n, a in REGS: print("%-22s %05x  %02x" % (n, a * 4, rd(a)))
elif c == "read":
    wp = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x58040000)
    if struct.unpack("<I", wp[0x2c:0x30])[0] & 1: sys.exit("WP forwards the core interrupt; not probing")
    mute = rd(0x0188); wr(0x0188, 0x3)        # mute I2CM done/error for the probe, restored below
    slave = x(sys.argv[2])
    for r in map(x, sys.argv[3:]):
        wr(STAT, 0xff); wr(SLAVE, slave); wr(ADDR, r); wr(OP, 0x01)
        t = time.monotonic()
        while (s := rd(STAT) & 0x3) == 0 and time.monotonic() - t < 0.05: pass
        wr(STAT, 0xff)
        res = {0: "timeout", 1: "error", 2: "done", 3: "done+error"}[s]
        print("slave %02x reg %02x: %-10s data %02x%02x" % (slave, r, res, rd(DI1), rd(DI0)))
    wr(0x0188, mute)
