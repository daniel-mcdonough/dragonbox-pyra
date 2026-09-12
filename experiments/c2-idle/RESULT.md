# Result: it hangs the machine

Tried on a Pyra V5.3 on 2026-09-12, on `5.6.19-c2`, which is the six-patch
kernel plus `0007` and nothing else.

**The change does what it says.** Both idle states appear and the governor
uses the deeper one heavily. One minute after boot, on the first core:

| state | entries | time in state |
| --- | --- | --- |
| `C1`, `CPUx WFI, MPUSS ON` | 24150 | 15.9 s |
| `C2`, `CPUx CSWR, MPUSS CSWR` | 25367 | 31.7 s |

More than half the idle entries went to retention, and more wall clock was
spent there than in the shallow state. The average idle stretch on this machine
is around two milliseconds and the state asks for a hundred microseconds, so
that is what should happen.

**And then the machine stops.** Two boots, two hangs, 48 seconds and 74 seconds
after boot. No warning, no backtrace, no watchdog message, no response on
either network interface. The same kernel without this patch runs for hours.

**Nothing was logged, and two things that look like evidence are not.** The
`L3 Custom Error` warning from the interconnect and a hung task in the USB
ethernet adapter's probe both occur on these boots, and both also occur on
every stock and fix boot including the one running now. They are unrelated.

**This is not the display hang.** That one spins a core and leaves the machine
reachable over the network, which is how its backtrace trap captures anything
at all. This takes the whole machine with no log.

**Conclusion.** The two `#if 0` blocks in the Pyra's kernel tree are best read
as somebody having found exactly this. The patch is kept because the reasoning
behind trying it was sound and because the next person will otherwise repeat
the experiment; it is not kept as something to enable.

Reopening it needs a serial console. Whatever goes wrong takes the machine
before it can write anything to disk.

See `docs/improvements.md` item 12 and `docs/verification-log.md`.
