#!/usr/bin/env python3
# One row a second: battery, temperatures, and the GPU power/clock state, read-only.
#   sample.py <csv> <phasefile>
# One long-lived process, so the sampler itself costs the same in every phase.
import mmap, os, struct, sys, time

PWRSTST = 0x4AE07504      # PM_GPU_PWRSTST: POWERSTATEST bits 1:0 (0 OFF, 1 RET, 2 INACTIVE, 3 ON)
CLKSTCTRL = 0x4A009500    # CM_GPU_CLKSTCTRL: CLKACTIVITY bits 8-10
CLKCTRL = 0x4A009520      # CM_GPU_GPU_CLKCTRL: IDLEST 17:16, STBYST 18
PS = "/sys/class/power_supply/bq27421-0/"
RPM = "/sys/bus/platform/devices/56000000.gpu/power/runtime_status"

fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
pages = {}
def rd(a):
    base = a & ~0xFFF
    if base not in pages:
        pages[base] = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    m = pages[base]; o = a - base
    return struct.unpack("<I", m[o:o + 4])[0]

def cat(p):
    try:
        with open(p) as f: return f.read().strip()
    except OSError: return ""

csv, phasefile = sys.argv[1], sys.argv[2]
with open(csv, "w") as out:
    out.write("t,phase,current_ua,voltage_uv,cpu_mc,gpu_mc,core_mc,online,loaded,"
              "pwrst_off_frac,clkact_frac,pwrstst,clkstctrl,clkctrl,rpm_suspended_frac\n")
    while True:
        t0 = time.time()
        # 100 register reads across the second, so a state that flickers is seen as a fraction.
        off = act = susp = 0
        for _ in range(100):
            if rd(PWRSTST) & 3 == 0: off += 1
            if rd(CLKSTCTRL) & 0x700: act += 1
            if cat(RPM) == "suspended": susp += 1
            time.sleep(0.0095)
        out.write(",".join(str(x) for x in (
            int(t0), cat(phasefile), cat(PS + "current_now"), cat(PS + "voltage_now"),
            cat("/sys/class/thermal/thermal_zone0/temp"), cat("/sys/class/thermal/thermal_zone1/temp"),
            cat("/sys/class/thermal/thermal_zone2/temp"), cat("/sys/class/power_supply/bq24297/online"),
            int(os.path.isdir("/sys/module/pvrsrvkm_omap5_sgx544_116")),
            off / 100, act / 100, hex(rd(PWRSTST)), hex(rd(CLKSTCTRL)), hex(rd(CLKCTRL)),
            susp / 100)) + "\n")
        out.flush()
