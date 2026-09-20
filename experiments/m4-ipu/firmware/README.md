# A test program for the two Cortex-M4s

This is the first thing that has actually **run** on the Pyra's M4s. Everything
in the parent directory makes them visible to Linux; this makes one of them
execute instructions and prove it.

    make                                            # builds omap5-ipu-fw.xem4
    scp omap5-ipu-fw.xem4 ../../../device/pyra-m4-run.sh pyra:/tmp/
    ssh pyra 'sudo /tmp/pyra-m4-run.sh /tmp/omap5-ipu-fw.xem4'

Needs the `5.6.19-m4` kernel. `arm-none-eabi-gcc` is the only build
dependency.

## What it does

Writes a heartbeat into a buffer the kernel exports as
`/sys/kernel/debug/remoteproc/remoteproc1/trace0`:

    pyra-m4-hello: running on the OMAP5432 IPU (2 x Cortex-M4)
    text carveout da=0x00000000 len=0x00100000
    trace da=0x00002368 len=4096
    core0: state=alive beats=0000000247
    core1: state=alive beats=0000000247

That is deliberately the smallest thing that cannot pass by accident. Three
separate claims are being made and each one is defended:

**The M4 wrote this, not the loader.** `m4_trace` lives in `.bss`, so it is not
in the ELF file. The one PT_LOAD segment has `filesz 0x368, memsz 0x3368`, and
`rproc_elf_load_segments()` memsets the difference to zero. So the buffer is
zero at every boot and every byte in it afterwards came from a core.

**It is still executing, not just once.** The counters are sampled a second
apart and must have advanced. Text alone would also be produced by a core that
wrote one line and then died, or faulted, or hung.

**Both M4s are running.** `core1`'s counter starts at zero and is only ever
touched by the second core. That is the only direct evidence that the second
processor left reset, which matters because the device tree asks for both and
nothing else in this repository would have noticed if only one came up.

## Why it needs no AMMU programming, and no TI toolchain

The IPU's unicache has an Attribute MMU in front of the L2 IOMMU, and TI's
`IpuAmmu_omap5.cfg` is 176 lines of it. None of that is needed here, because
of what the reset state has to be: the M4s fetch their vector table from
logical address 0 through the AMMU, and SYS/BIOS's own AMMU-programming code
is itself code at a low logical address. Large page 0 — logical `0x00000000`,
512 MB, translation disabled — therefore cannot require programming, or
nothing could ever boot. TI's config only adds cacheability to it.

So everything here stays inside `0x00000000..0x000fffff`, touches no
peripheral, and leaves the AMMU and the unicache exactly as reset left them.
The cache being off is also why Linux can see these writes at all without any
flushing.

The cost of that choice is that this firmware cannot reach the mailbox
(`0x4a0f4000`) or anything else outside the reset window, so it cannot answer
the `RP_MBOX_ECHO_REQUEST` that `omap_rproc_start()` leaves sitting in the
FIFO, and it cannot do rpmsg. Both are reachable without touching the AMMU by
mapping a `TYPE_DEVMEM` resource at a low device address — the IOMMU can
translate `da 0x10000000 -> pa 0x4a0f4000` while the AMMU passes the low
address through untouched — but that is the next program, not this one.

TI's own route is XDCtools + SYS/BIOS + IPC + the TI CGT ARM compiler, about a
gigabyte behind a login, and it produces a MessageQ/rpmsg firmware. That is
the right answer once there is something to communicate and the wrong one for
finding out whether the kernel half works.

## Both cores run the same code

`resets = <&prm_core 0>, <&prm_core 1>` on the IPU node are RM_IPU_RSTCTRL
bits 0 and 1, CPU0 and CPU1 (bit 2 is the MMU/cache reset and belongs to
omap-iommu). `omap_rproc_start()` deasserts both, so every instruction in
`start.S` runs twice. TI answered this with `BIOS.smpEnabled = true`.

Neither core can ask the hardware which one it is, so the first one to arrive
claims core 0 by writing `m4_core_claim`. That read-modify-write is not
atomic and does not need to be: `reset_control_array_deassert()` deasserts one
line at a time and `omap_reset_deassert()` polls RSTST until the first reset
has completed before writing the second, so core 0 is microseconds ahead
rather than cycles. If that ever stopped holding, both cores would claim 0 and
the test would report "core1 never ran" — a visible failure, not a hazard.

The two stacks are one array so their order is defined, which is what lets
`m4_fault()` work out which core faulted from its own stack pointer.

## What it found

The firmware works. The kernel does not, quite: starting the IPU produces two
`BUG: scheduling while atomic` splats every time, because `omap-iommu` sleeps
while holding two spinlocks. That is an unfixed upstream bug, not something
0009-0011 introduced — mainline today is identical — and
`0012-iommu-omap-do-not-sleep-while-holding-the-iommu-spinlocks.patch` is the
fix. See that patch's header; it is compile-tested and not yet booted.

The first version of `pyra-m4-run.sh` reported "10 ok, 0 failed" straight
through both splats, because it grepped the kernel log by subsystem keyword
and a backtrace does not repeat the subsystem name on every line. It now
checks for `BUG:`/`WARNING:` by line prefix, separately from anything
topical.

## Files

| | |
|---|---|
| `start.S` | Vector table, the core-0/core-1 claim, per-core stacks, fault entry |
| `main.c` | The trace buffer and the heartbeat |
| `resource_table.c` | The `TYPE_CARVEOUT` + `TYPE_TRACE` contract with remoteproc |
| `m4.ld` | Everything inside the 1 MiB carveout at device address 0 |

`make info` prints the ELF header, the segment, the reset vector and a hex
dump of the resource table, which is the quickest way to check a change did
what you meant.
