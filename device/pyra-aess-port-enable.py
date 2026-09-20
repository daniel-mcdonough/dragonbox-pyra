#!/usr/bin/env python3
"""pyra-aess-port-enable.py -- enable AESS ports and look for sample movement.

    sudo ./pyra-aess-port-enable.py 6        # MM_DL
    sudo ./pyra-aess-port-enable.py 6,11     # MM_DL + PDM_DL

Run pyra-aess-probe.sh, pyra-aess-run.py and pyra-aess-dl-probe.py first.

ANSWER, 2026-09-20: still nothing moves. This is a NEGATIVE result that bounds
how far the /dev/mem approach can go, and it is the reason the work should move
into the driver rather than continue here.

It decodes the config blob's port table -- 17 ports of struct omap_aess_port,
228 bytes each, a stride confirmed because the decoded fields are obviously
sane (rates of 96000/48000/8000, plausible protocols, small SMEM indices) and
because the entries that follow land exactly inside the blob. Then it adds a
port's scheduling tasks to MultiFrame, which is the update_scheduling_table()
half of omap_aess_enable_data_transfer() (aess_port.c:1159).

That half is not enough. MM_DL's task appears at MultiFrame[18][0] = 0x0d14 and
the engine dispatches it, but no data moves, because a port must first be
*connected*: omap_aess_connect_cbpr_dmareq_port() -> omap_aess_init_io_tasks()
and omap_aess_init_atc() write the port's IO descriptor and ATC descriptors
into DMEM. Reimplementing those from userspace means init_atc (~104 lines),
clean_temporary_buffers (~114), init_io_tasks, plus the IO-descriptor and ATC
descriptor layouts -- 400+ lines of intricate undocumented work, in a place
where every mistake is an asynchronous external abort.

The kernel already contains all of it, working, in aess_port.c's 1683 lines.
It is unreachable for ONE reason: omap_abe_add_aess_dai_links() in
sound/soc/ti/omap-abe-twl6040.c:451 is an empty stub, so no DAI link references
the AESS component, so the component is never bound into a card, so
omap_aess_pcm_probe() never runs -- and that is where pm_runtime_enable() is
called (omap-aess-pcm.c:475) and where the AESS init sequence sits behind its
#if 0. With runtime PM never enabled, pm_runtime_active() is false and every
accessor in aess_mem.h silently drops its writes.

So the fix is to fill in that stub, not to keep reimplementing the ABE here.

Port table for reference (id, name, rate, direction, protocol, tasks):
    6  MM_DL   48000 in  DMAREQ   MultiFrame[18][0] = 0x0d14
   11  PDM_DL  96000 out MCPDMDL  MultiFrame[7][0] and [19][0] = 0x0d64
   ping_pong   48000 in           MultiFrame[18][0] = 0x0ca4

ALL ABE memory access is 32-bit: byte-wise slice reads raise asynchronous
external aborts. Accesses are clamped to sizes proven by firmware read-back.
Shutdown quiesces before handing the module back to ti-sysc.
"""
import mmap, os, struct, sys, time
PORTS=[int(x) for x in (sys.argv[1] if len(sys.argv)>1 else "6").split(",") if x!=""]
FW="/lib/firmware/omap_aess-adfw.bin"; TM="/sys/bus/platform/drivers/ti-sysc/401f1000.target-module"
BASE={"DMEM":0x40180000,"CMEM":0x401A0000,"SMEM":0x401C0000,"PMEM":0x401E0000}
SAFE={"DMEM":0x10000,"CMEM":7852,"SMEM":21600,"PMEM":8192}; BN={0:"DMEM",1:"CMEM",2:"SMEM",3:"PMEM"}
EVT_COUNTER,EVT_START,EVT_SRC,SCHED,AUTOGATE,IRQENCLR,DMAENCLR=0x68,0x6C,0x70,0x74,0x7C,0x40,0x64
GT,MMDL_FIFO,MM_DL,DL1_EQ,EARP,IHF,MCPDM_DL,LOOPC=57,7,31,51,52,53,12,77
NM={MMDL_FIFO:"DMEM_MM_DL_FIFO",MM_DL:"SMEM_MM_DL",DL1_EQ:"SMEM_DL1_M_EQ",
    EARP:"SMEM_EARP_48_96",IHF:"SMEM_IHF_48_96",MCPDM_DL:"DMEM_MCPDM_DL_FIFO"}
PNAMES=["DMIC","PDM_UL","BT_VX_UL","MM_UL","MM_UL2","VX_UL","MM_DL","VX_DL","TONES_DL",
        "MCASP_DL","BT_VX_DL","PDM_DL","MM_EXT_OUT","MM_EXT_IN","TDM_DL","TDM_UL","DEBUG"]
UNITY=0x00040000
def sf(p,v=None): return open(p).read().strip() if v is None else open(p,"w").write(v)
def step(m): print("  .. %s"%m, flush=True)
class Bank:
    def __init__(s,fd,b,l): s.m=mmap.mmap(fd,0x10000,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b); s.l=l
    def _ck(s,o,n):
        if o<0 or o+n>s.l: raise SystemExit("REFUSING 0x%x+%d past %d"%(o,n,s.l))
    def r32(s,o): s._ck(o,4); return struct.unpack_from("<I",s.m,o)[0]
    def w32(s,o,v): s._ck(o,4); struct.pack_into("<I",s.m,o,v&0xFFFFFFFF)
    def words(s,o,n): s._ck(o,n); return [struct.unpack_from("<I",s.m,o+i)[0] for i in range(0,n-3,4)]
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
o=0; n=w(o); mo=o+1; o=mo+n*3
MAP=[struct.unpack_from("<iII",cfg,(mo+i*3)*4) for i in range(n)]
n=w(o); lo=o+1; o=lo+n; LAB=[w(lo+i) for i in range(n)]
n=w(o); o=o+1+n; n=w(o); to=o+1; o=to+n
TASK=[struct.unpack_from("<BBH",cfg,(to+i)*4) for i in range(n)]
nport=w(o); po=o+1
def ptasks(i):
    b=po*4+i*228; nbt,=struct.unpack_from("<I",cfg,b+56)
    return [struct.unpack_from("<BBH",cfg,b+60+k*4) for k in range(nbt)]

prev=sf(TM+"/power/control"); sf(TM+"/power/control","on"); time.sleep(1)
if sf(TM+"/power/runtime_status")!="active": sf(TM+"/power/control",prev); raise SystemExit("not active")
fd=os.open("/dev/mem",os.O_RDWR|os.O_SYNC)
B={k:Bank(fd,BASE[k],SAFE[k]) for k in BASE}; ip=Bank(fd,0x401F1000,0x1000)
def ent(i): b,of,by=MAP[i]; return B[BN[b]],of,by
def imgw(i):
    b,of,by=MAP[i]; return [struct.unpack_from("<I",img[BN[b]],of+k)[0] for k in range(0,by-3,4)]
try:
    print("enabling ports: %s"%", ".join("%d=%s"%(i,PNAMES[i]) for i in PORTS))
    ip.w32(EVT_START,0); time.sleep(0.2)
    for nm in ("PMEM","CMEM","DMEM","SMEM"): B[nm].load(0,img[nm])
    mf=bytearray(400)
    for f,sl,tk in TASK: struct.pack_into("<H",mf,(f*8+sl)*2,tk)
    step("base schedule: %d tasks"%len(TASK))
    for i in PORTS:
        for f,sl,tk in ptasks(i):
            struct.pack_into("<H",mf,(f*8+sl)*2,tk)
            step("port %-9s -> MultiFrame[%2d][%d] = 0x%04x"%(PNAMES[i],f,sl,tk))
    bk,of,_=ent(0); bk.load(of,bytes(mf))
    bk,of,by=ent(68); bk.load(of,b"".join(struct.pack("<H",LAB[0]&0xFFFF) for _ in range(by//2)))
    gof=MAP[GT][1]
    for g in (8,9,10,11,14,18): B["SMEM"].w32(gof+(g<<2),UNITY)
    step("gains 8-11,14,18 = 0 dB")
    bk,of,by=ent(MMDL_FIFO); bk.fill(of,by,0x00ABCD); step("DMEM_MM_DL_FIFO <- 0x00ABCD (%d bytes)"%by)
    bk,of,by=ent(MM_DL);     bk.fill(of,by,0x100000); step("SMEM_MM_DL      <- 0x100000 (%d bytes)"%by)
    ip.w32(AUTOGATE,1); ip.w32(EVT_COUNTER,2047); ip.w32(EVT_SRC,1); ip.w32(EVT_START,1); ip.w32(SCHED,0)
    step("engine started")
    time.sleep(1.0)
    lb,lof,_=ent(LOOPC); loops=lb.r32(lof)
    ip.w32(EVT_START,0); time.sleep(0.2)
    print("  loops: %d"%loops)
    for i in (MMDL_FIFO,MM_DL,DL1_EQ,EARP,IHF,MCPDM_DL):
        bk,of,by=ent(i); now=bk.words(of,by); im=imgw(i)
        nz=sum(1 for v in now if v)
        uniq=len(set(now))
        tag="DIFFERS from image" if now!=im else "unchanged from image"
        print("  %-20s %-40s nz %3d/%-3d uniq %-3d %s"%(
            NM[i]," ".join("%06x"%(v&0xFFFFFF) for v in now[:6]),nz,len(now),uniq,tag))
finally:
    try:
        ip.w32(EVT_START,0); ip.w32(DMAENCLR,0x7F); ip.w32(IRQENCLR,0x01); time.sleep(0.15)
    except Exception as e: print("quiesce failed: %s"%e)
    sf(TM+"/power/control",prev); st="suspending"
    for _ in range(20):
        st=sf(TM+"/power/runtime_status")
        if st!="suspending": break
        time.sleep(0.25)
    if st=="suspending": sf(TM+"/power/control","on"); print("!! stuck -- left control=on, do not reboot")
    else: print("cleanup: control=%s status=%s"%(sf(TM+"/power/control"),st), flush=True)
