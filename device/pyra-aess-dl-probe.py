#!/usr/bin/env python3
"""pyra-aess-dl-probe.py -- does anything come out of the AESS downlink path?

    sudo ./pyra-aess-dl-probe.py [phase]   # phase 0, 1 (default), 2 or 3

Run pyra-aess-probe.sh and pyra-aess-run.py first; this assumes both pass.
It injects a known constant into SMEM_MM_DL, runs the engine, and reads the
downlink buffers -- SMEM_DL1_M_EQ, SMEM_EARP_48_96, SMEM_IHF_48_96 and
DMEM_MCPDM_DL_FIFO -- comparing each against the firmware image rather than
poisoning anything.

    phase 0  no injection at all: the engine on the plain firmware image
    phase 1  inject at SMEM_MM_DL, write no gains
    phase 2  + output gains DL1_L/R, DL2_L/R (ids 8-11)
    phase 3  + mixer gains MIXDL1_MM_DL / MIXDL2_MM_DL (ids 14, 18)

ANSWER, 2026-09-20: nothing comes out, in any phase. The engine runs at the
correct 4000 loops/s and the injected value stays put in SMEM_MM_DL, but every
downstream buffer reads exactly the firmware image. This is a NEGATIVE result
and it is expected once you see why.

The 42 tasks in the config's init_table are only the always-resident base
schedule. A port's processing tasks are written into MultiFrame when the port
is *enabled*, by omap_aess_enable_data_transfer() (sound/soc/ti/aess/
aess_port.c:1159) via omap_aess_update_scheduling_table() and
omap_aess_update_io_task() at lines 234 and 250. No port is enabled here, so
no DL task is ever dispatched and the mixer gains have nothing to act on.
Getting audio out therefore needs the port-enable path, which means decoding
struct omap_aess_port out of the config blob -- status, data_format,
smem_buffer1/2, port_protocol, dma_offset, init_task and asrc_port tsk_freq[4]
-- and writing the IO descriptors. That is the next piece of work and it is a
large one.

Two things this script had to get right, both learned by getting them wrong:

  * ALL ABE memory access must be 32-bit. A byte-wise slice copy --
    bytes(mmap[a:b]) -- raises asynchronous external aborts. Six were traced to
    exactly that. Because the aborts are ASYNCHRONOUS they surface at whatever
    access happens next, so they appear to blame innocent reads and bisecting
    by "which access died" sends you somewhere wrong. Read words, always.
  * Quiesce before letting ti-sysc gate the module: EVENT_GENERATOR_START=0,
    DMAENABLE_CLR, MCU_IRQENABLE_CLR, settle, and only then restore
    power/control. Done in that order, none of the six aborts produced a
    kernel oops. Skipped, one of them oopsed sysc_disable_module, wedged the
    device in RPM_SUSPENDING and hung shutdown until the power button was held.

Every access is clamped to SAFE[] -- sizes proven by byte-identical firmware
read-back, never taken from the device tree, which undersizes PMEM and CMEM.
"""
import mmap, os, struct, sys, time
PHASE=int(sys.argv[1]) if len(sys.argv)>1 else 1
FW="/lib/firmware/omap_aess-adfw.bin"; TM="/sys/bus/platform/drivers/ti-sysc/401f1000.target-module"
BASE={"DMEM":0x40180000,"CMEM":0x401A0000,"SMEM":0x401C0000,"PMEM":0x401E0000}
SAFE={"DMEM":0x10000,"CMEM":7852,"SMEM":21600,"PMEM":8192}
BN={0:"DMEM",1:"CMEM",2:"SMEM",3:"PMEM"}
EVT_COUNTER,EVT_START,EVT_SRC,SCHED,AUTOGATE,IRQENCLR,DMAENCLR=0x68,0x6C,0x70,0x74,0x7C,0x40,0x64
GT,MM_DL,DL1_EQ,EARP,IHF,MCPDM_DL,LOOPC=57,31,51,52,53,12,77
UNITY=0x00040000
def sf(p,v=None): return open(p).read().strip() if v is None else open(p,"w").write(v)
def step(m): print("  .. %s"%m, flush=True)
class Bank:
    def __init__(s,fd,b,l): s.m=mmap.mmap(fd,0x10000,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b); s.l=l
    def _ck(s,o,n):
        if o<0 or o+n>s.l: raise SystemExit("REFUSING 0x%x+%d past %d"%(o,n,s.l))
    def r32(s,o): s._ck(o,4); return struct.unpack_from("<I",s.m,o)[0]
    def w32(s,o,v): s._ck(o,4); struct.pack_into("<I",s.m,o,v&0xFFFFFFFF)
    def blk(s,o,n):
        # 32-bit reads only. A byte-wise slice copy of SMEM (24-bit memory)
        # is a strong suspect for the asynchronous external aborts.
        s._ck(o,n)
        return [struct.unpack_from("<I",s.m,o+i)[0] for i in range(0,n-3,4)]
    def fill(s,o,n,v):
        s._ck(o,n)
        for i in range(0,n-3,4): struct.pack_into("<I",s.m,o+i,v&0xFFFFFFFF)
    def load(s,o,d):
        s._ck(o,len(d))
        for i in range(0,len(d)-3,4): struct.pack_into("<I",s.m,o+i,struct.unpack_from("<I",d,i)[0])
d=open(FW,"rb").read(); off=0; bl={}
while off<len(d):
    m,a,t,vt,v,sz=struct.unpack_from("<6I",d,off); bl.setdefault(t,[]).append(d[off+24:off+24+sz]); off+=24+sz
fw=bl[1000][0]; ver,pm,cm,dm,sm=struct.unpack_from("<5I",fw,0); p=20; img={}
for n,z in (("PMEM",pm),("CMEM",cm),("DMEM",dm),("SMEM",sm)): img[n]=fw[p:p+z]; p+=z
cfg=bl[1001][0]; w=lambda i: struct.unpack_from("<I",cfg,i*4)[0]
o=0;n=w(o);mo=o+1;o=mo+n*3
MAP=[struct.unpack_from("<iII",cfg,(mo+i*3)*4) for i in range(n)]
n=w(o);lo=o+1;o=lo+n; LAB=[w(lo+i) for i in range(n)]
n=w(o);o=o+1+n; n=w(o);to=o+1
TASK=[struct.unpack_from("<BBH",cfg,(to+i)*4) for i in range(n)]
NM={MM_DL:"SMEM_MM_DL",DL1_EQ:"SMEM_DL1_M_EQ",EARP:"SMEM_EARP_48_96",IHF:"SMEM_IHF_48_96",MCPDM_DL:"DMEM_MCPDM_DL_FIFO"}

prev=sf(TM+"/power/control"); sf(TM+"/power/control","on"); time.sleep(1)
if sf(TM+"/power/runtime_status")!="active": sf(TM+"/power/control",prev); raise SystemExit("not active")
fd=os.open("/dev/mem",os.O_RDWR|os.O_SYNC)
B={k:Bank(fd,BASE[k],SAFE[k]) for k in BASE}; ip=Bank(fd,0x401F1000,0x1000)
def ent(i): b,of,by=MAP[i]; return B[BN[b]],of,by
def imgbytes(i):
    b,of,by=MAP[i]; return img[BN[b]][of:of+by]
try:
    print("PHASE %d"%PHASE)
    step("stop engine"); ip.w32(EVT_START,0); time.sleep(0.2)
    for nm in ("PMEM","CMEM","DMEM","SMEM"): B[nm].load(0,img[nm])
    step("firmware loaded")
    mf=bytearray(400)
    for f,sl,tk in TASK: struct.pack_into("<H",mf,(f*8+sl)*2,tk)
    bk,of,_=ent(0); bk.load(of,bytes(mf))
    bk,of,by=ent(68); bk.load(of,b"".join(struct.pack("<H",LAB[0]&0xFFFF) for _ in range(by//2)))
    step("scheduler table + uplink router")
    if PHASE>=2:
        gof=MAP[GT][1]
        for g in (8,9,10,11): B["SMEM"].w32(gof+(g<<2),UNITY)
        step("output gains ids 8-11 set to 0 dB (within GTARGET1)")
    if PHASE>=3:
        gof=MAP[GT][1]
        for g in (14,18): B["SMEM"].w32(gof+(g<<2),UNITY)
        step("mixer gains ids 14,18 set to 0 dB (PAST GTARGET1's declared end)")
    if PHASE>=1:
        bk,of,by=ent(MM_DL); bk.fill(of,by,0x100000)
        step("injected 0x100000 into SMEM_MM_DL (%d bytes)"%by)
    else:
        step("PHASE 0: no injection, engine runs on the plain firmware image")
    step("start engine")
    ip.w32(AUTOGATE,1); ip.w32(EVT_COUNTER,2047); ip.w32(EVT_SRC,1); ip.w32(EVT_START,1); ip.w32(SCHED,0)
    time.sleep(1.0)
    lb,lof,_=ent(LOOPC); loops=lb.r32(lof)
    # Stop before reading SMEM. SMEM is the DSP's tightly coupled sample
    # memory; MPU reads of it while the engine runs fault the ABE.
    step("stopping engine BEFORE reading SMEM")
    ip.w32(EVT_START,0); time.sleep(0.2)
    step("engine stopped, reading back")
    print("  loops: %d"%loops)
    for i in (MCPDM_DL,MM_DL,DL1_EQ,EARP,IHF):        # DMEM first, then SMEM
        bk,of,by=ent(i)
        step("reading %s (%s 0x%x+%d)"%(NM[i],BN[MAP[i][0]],of,by))
        now=bk.blk(of,by)
        im=[struct.unpack_from("<I",imgbytes(i),k)[0] for k in range(0,by-3,4)]
        nz=sum(1 for v in now if v)
        tag="differs from loaded image" if now!=im else "unchanged from image"
        print("  %-20s %-40s nonzero %3d/%-3d  %s"%(
            NM[i]," ".join("%06x"%(v&0xFFFFFF) for v in now[:6]),nz,len(now),tag))
    ip.w32(EVT_START,0)
finally:
    try:
        ip.w32(EVT_START,0); ip.w32(DMAENCLR,0x7F); ip.w32(IRQENCLR,0x01); time.sleep(0.15)
    except Exception as e: print("quiesce failed: %s"%e)
    sf(TM+"/power/control",prev); st="suspending"
    for _ in range(20):
        st=sf(TM+"/power/runtime_status")
        if st!="suspending": break
        time.sleep(0.25)
    print("cleanup: control=%s status=%s"%(sf(TM+"/power/control"),st), flush=True)
