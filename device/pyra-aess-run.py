#!/usr/bin/env python3
"""pyra-aess-run.py -- load the AESS firmware and run the OMAP5 audio DSP.

    sudo ./pyra-aess-run.py

Proves the AESS DSP core executes, by building the scheduler table the kernel
driver never builds, starting the engine, and measuring its loop rate. Nothing
here is permanent: it touches no kernel state, plays no audio, and puts the
module back under ti-sysc when it finishes. `pyra-aess-probe.sh` is the cheaper
question -- is the silicon there at all -- and should be run first.

Why this exists in userspace rather than as a driver fix: the in-kernel path is
dead three times over. omap_abe_add_aess_dai_links() is an empty stub, the aess
device never calls pm_runtime_enable() so every write in aess_mem.h is dropped
by its pm_runtime_active() guard, and the AESS init in omap_aess_pcm_probe() is
inside an #if 0. Driving it from /dev/mem sidesteps all three and answers the
only question worth money: does the hardware work? It does.

What it measures. The ABE runs a scheduling loop at 4 kHz, clocked by an event
generator whose divisor selects the sample-rate family. Both are checked:

    counter 2047 (48 kHz family)  -> expect ~4000 loops/s
    counter 2227 (44.1 kHz family)-> expect ~3676, a ratio of 2048/2228

The ratio is the real evidence. A free-running counter, or memory changing for
any reason other than the DSP, would not track the divisor to four decimals.

TWO HAZARDS, both learned by causing them on 2026-09-20, both guarded here.

  1. Reading past a bank's real size raises an asynchronous external abort that
     wedges the L4 ABE interconnect. Every access goes through Bank._ck() and
     is clamped to SAFE[] below. Those sizes are proven -- each is a length the
     firmware image writes and reads back byte-identical -- never guessed. The
     device tree is NOT a safe source for them: it maps PMEM and CMEM as 0x1000
     when both are at least 8 KiB, and says "CHECKME" while doing it.

  2. Once the interconnect is wedged, handing the module back to ti-sysc oopses
     in sysc_disable_module, leaves the device in RPM_SUSPENDING forever, and
     then hangs shutdown for minutes because systemd waits on it. Recovering
     that needs a forced power-off, which costs you an unclean unmount.
     Shutdown here follows the driver's own order -- EVENT_STOP, DMAENABLE_CLR,
     MCU_IRQENABLE_CLR, then a settle longer than its udelay(250) -- and then
     verifies runtime_status actually reaches "suspended". If it sticks, it
     forces power/control back to "on" and says so: a module left clocked
     costs idle power, a wedged one costs you the next reboot.

Clean shutdown works as long as no abort happened, which is what guard 1 is
for. Do not remove either one.
"""
import mmap, os, struct, sys, time

FW   = "/lib/firmware/omap_aess-adfw.bin"
TM   = "/sys/bus/platform/drivers/ti-sysc/401f1000.target-module"
BASE = {"DMEM":0x40180000, "CMEM":0x401A0000, "SMEM":0x401C0000, "PMEM":0x401E0000}
SAFE = {"DMEM":0x10000, "CMEM":7852, "SMEM":21600, "PMEM":8192}   # proven, not assumed
IRQRAW, IRQENCLR, DMAENCLR = 0x24, 0x40, 0x64
EVT_COUNTER, EVT_START, EVT_SRC, SCHED, AUTOGATE = 0x68, 0x6C, 0x70, 0x74, 0x7C
BANKNAME = {0:"DMEM", 1:"CMEM", 2:"SMEM", 3:"PMEM", 4:"IP"}

def sysfs(p, v=None): return open(p).read().strip() if v is None else open(p,"w").write(v)

class Bank:
    def __init__(s, fd, base, limit):
        s.m = mmap.mmap(fd, 0x10000, mmap.MAP_SHARED, mmap.PROT_READ|mmap.PROT_WRITE, offset=base)
        s.limit = limit
    def _ck(s, o, n):
        if o < 0 or o + n > s.limit:
            raise SystemExit("REFUSING access at 0x%x+%d, past proven-safe %d" % (o, n, s.limit))
    def r32(s, o):    s._ck(o,4); return struct.unpack_from("<I", s.m, o)[0]
    def w32(s, o, v): s._ck(o,4); struct.pack_into("<I", s.m, o, v & 0xFFFFFFFF)
    def blk(s, o, n): s._ck(o,n); return bytes(s.m[o:o+n])
    def load(s, o, data):
        s._ck(o, len(data))
        for i in range(0, len(data)-3, 4):
            struct.pack_into("<I", s.m, o+i, struct.unpack_from("<I", data, i)[0])

def parse():
    d = open(FW,"rb").read(); off=0; bl={}
    while off < len(d):
        m,a,t,vt,v,sz = struct.unpack_from("<6I", d, off)
        if m != 0x41536F43: raise SystemExit("container sync lost")
        bl.setdefault(t,[]).append(d[off+24:off+24+sz]); off += 24+sz
    fw = bl[1000][0]
    ver,pm,cm,dm,sm = struct.unpack_from("<5I", fw, 0); p=20; imgs={}
    for n,sz in (("PMEM",pm),("CMEM",cm),("DMEM",dm),("SMEM",sm)): imgs[n]=fw[p:p+sz]; p+=sz
    cfg = bl[1001][0]; w = lambda i: struct.unpack_from("<I", cfg, i*4)[0]
    o=0
    n=w(o); mo=o+1; o=mo+n*3
    MAP=[struct.unpack_from("<iII", cfg, (mo+i*3)*4) for i in range(n)]
    n=w(o); lo=o+1; o=lo+n
    LAB=[w(lo+i) for i in range(n)]
    n=w(o); o=o+1+n                                   # functions, unused here
    n=w(o); to=o+1
    TASK=[struct.unpack_from("<BBH", cfg, (to+i)*4) for i in range(n)]
    return ver, imgs, MAP, LAB, TASK

ver, imgs, MAP, LAB, TASK = parse()
MULTIFRAME, AUPLINK, LOOPCOUNTER = MAP[0], MAP[68], MAP[77]
print("firmware 0x%x   tasks=%d  labels=%d  map=%d" % (ver, len(TASK), len(LAB), len(MAP)))
for nm, e in (("MULTIFRAME",MULTIFRAME), ("AUPLINKROUTING",AUPLINK), ("LOOPCOUNTER",LOOPCOUNTER)):
    print("  %-15s bank=%s offset=0x%04x bytes=%d" % (nm, BANKNAME[e[0]], e[1], e[2]))
assert MULTIFRAME[2] == 25*8*2, "MultiFrame is not u16[25][8]"

prev = sysfs(TM+"/power/control"); sysfs(TM+"/power/control","on"); time.sleep(1)
if sysfs(TM+"/power/runtime_status") != "active":
    sysfs(TM+"/power/control", prev); raise SystemExit("module would not come active")
fd = os.open("/dev/mem", os.O_RDWR|os.O_SYNC)
B  = {k: Bank(fd, BASE[k], SAFE[k]) for k in BASE}
ip = Bank(fd, 0x401F1000, 0x1000)
PRCM = Bank(fd, 0x4A004000, 0x1000)   # CM_CORE_AON, read-only use

# CM_ABE_AESS_CLKCTRL, so we can ask the PRCM whether the module is willing to
# idle BEFORE handing it back to ti-sysc. Gating a module that cannot idle is
# what oopsed sysc_disable_module and wedged the device in RPM_SUSPENDING.
IDLEST = {0:"functional", 1:"in transition", 2:"idle", 3:"disabled"}
def clkctrl():
    v = struct.unpack_from("<I", PRCM.m, 0x528)[0]
    return v, IDLEST[(v >> 16) & 3]

def shutdown():
    """The driver's own order: stop generator, drop DMA/IRQ, then settle."""
    try:
        ip.w32(EVT_START, 0)
        ip.w32(DMAENCLR, 0x7F)
        ip.w32(IRQENCLR, 0x01)
        time.sleep(0.1)                 # driver uses udelay(250); be generous
        print("\nengine stopped: EVENT_GENERATOR_START=%d" % ip.r32(EVT_START))
    except Exception as e:
        print("\nshutdown write failed: %s" % e)
    # IDLEST is not a useful precondition: while power/control is "on" ti-sysc
    # holds MODULEMODE enabled, so it reads "functional" whatever the AESS
    # wants. Hand the module back and check the result instead.
    sysfs(TM+"/power/control", prev)
    st = "suspending"
    for _ in range(20):
        st = sysfs(TM+"/power/runtime_status")
        if st != "suspending": break
        time.sleep(0.25)
    print("power/control=%s runtime_status=%s" % (sysfs(TM+"/power/control"), st))
    if st == "suspending":
        sysfs(TM+"/power/control", "on")
        print("!! stuck in RPM_SUSPENDING -- forced power/control back to 'on'.")
        print("!! Do NOT reboot from here: systemd will wait on this device and")
        print("!! you will end up holding the power button. Investigate first.")
    else:
        v, st_name = clkctrl()
        print("CM_ABE_AESS_CLKCTRL = 0x%08x  IDLEST=%s  (expect 'disabled')" % (v, st_name))

try:
    print("\n== loading firmware ==")
    for n in ("PMEM","CMEM","SMEM","DMEM"):
        B[n].load(0, imgs[n])
        ok = B[n].blk(0, len(imgs[n]) & ~3) == imgs[n][:len(imgs[n]) & ~3]
        print("  %s %6d bytes  read-back %s" % (n, len(imgs[n]), "identical" if ok else "DIFFERS (24-bit bank)"))

    print("\n== building the scheduler table (the stub the driver never fills in) ==")
    mf = bytearray(400)
    for frame, slot, task in TASK:
        struct.pack_into("<H", mf, (frame*8+slot)*2, task)
    B[BANKNAME[MULTIFRAME[0]]].load(MULTIFRAME[1], bytes(mf))
    nonzero = sum(1 for i in range(0,400,2) if struct.unpack_from("<H",mf,i)[0])
    print("  MultiFrame[25][8]: %d of 200 slots populated from %d tasks" % (nonzero, len(TASK)))
    mux = b"".join(struct.pack("<H", LAB[0] & 0xFFFF) for _ in range(AUPLINK[2]//2))
    B[BANKNAME[AUPLINK[0]]].load(AUPLINK[1], mux)
    print("  uplink router: %d entries reset to ZERO label 0x%x" % (AUPLINK[2]//2, LAB[0]))

    LC = B[BANKNAME[LOOPCOUNTER[0]]]; lco = LOOPCOUNTER[1]
    print("\n== control: engine stopped ==")
    ip.w32(EVT_START, 0); time.sleep(0.3)
    a = LC.r32(lco); d0 = B["DMEM"].blk(0, SAFE["DMEM"]); time.sleep(1.0)
    b_ = LC.r32(lco); d1 = B["DMEM"].blk(0, SAFE["DMEM"])
    chg = sum(1 for i in range(0,SAFE["DMEM"],4) if d0[i:i+4]!=d1[i:i+4])
    print("  LOOPCOUNTER %d -> %d   DMEM words changed in 1 s: %d" % (a, b_, chg))

    print("\n== starting the audio engine ==")
    ip.w32(AUTOGATE, 1); ip.w32(EVT_COUNTER, 2047); ip.w32(EVT_SRC, 1)
    ip.w32(EVT_START, 1); ip.w32(SCHED, 0)
    time.sleep(0.5)
    for t in range(5):
        time.sleep(0.4)
        print("  t=%.1fs  LOOPCOUNTER=%-10d IRQRAW=0x%08x" % (0.5+(t+1)*0.4, LC.r32(lco), ip.r32(IRQRAW)))

    def rate(counter, secs=2.0):
        ip.w32(EVT_START,0); time.sleep(0.15)
        ip.w32(EVT_COUNTER, counter); ip.w32(EVT_SRC,1); ip.w32(EVT_START,1); ip.w32(SCHED,0)
        time.sleep(0.3)
        t0=time.time(); v0=LC.r32(lco); time.sleep(secs); v1=LC.r32(lco); dt=time.time()-t0
        return ((v1-v0) & 0xFFFFFFFF)/dt
    r48 = rate(2047); r44 = rate(2227)
    print("\n== does the loop rate follow the event generator? ==")
    print("  counter 2047 (48k family)  : %9.1f loops/s" % r48)
    print("  counter 2227 (44.1k family): %9.1f loops/s" % r44)
    print("  measured ratio %.4f   expected 2048/2228 = %.4f" % ((r44/r48 if r48 else 0), 2048/2228))

    ip.w32(EVT_START,0); time.sleep(0.3)
    x = LC.r32(lco); time.sleep(0.7); y = LC.r32(lco)
    print("\n  stopped: LOOPCOUNTER %d -> %d  (%s)" % (x, y, "frozen" if x==y else "STILL RUNNING"))
    d2 = B["DMEM"].blk(0, SAFE["DMEM"])
    ip.w32(EVT_COUNTER,2047); ip.w32(EVT_SRC,1); ip.w32(EVT_START,1); ip.w32(SCHED,0)
    time.sleep(1.0)
    d3 = B["DMEM"].blk(0, SAFE["DMEM"])
    chg2 = sum(1 for i in range(0,SAFE["DMEM"],4) if d2[i:i+4]!=d3[i:i+4])
    print("  restarted: DMEM words changed in 1 s: %d (stopped control was %d)" % (chg2, chg))

    print("\n%s" % ("THE AESS DSP IS RUNNING ITS SCHEDULER LOOP."
                    if r48 > 100 and abs((r44/r48 if r48 else 0) - 2048/2228) < 0.02
                    else "Engine did not demonstrate a clocked loop; see numbers above."))
finally:
    shutdown()
