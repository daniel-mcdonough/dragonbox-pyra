# What the stuck-on GPU costs at idle

The SGX544 never powers down, because `pvr_probe` holds a runtime-PM reference until the
module is removed (`docs/handoff/gpu-power-PROGRESS.md` §6). This measures the most that
fixing it can save at desktop idle, without building anything. With no GL client,
unloading `pvrsrvkm_omap5_sgx544_116` drops that reference, and PD_GPU is then free to go OFF.

- `gpuoff.sh check`: one unload/reload cycle, registers printed.
- `gpuoff.sh`: the measurement. On battery, CPU pinned at 1000 MHz (userspace governor),
  90 s blocks in the order on/off/off/on, twice. *on* means the module is loaded;
  *off* means it is unloaded.
- `sample.py`: one row a second: gauge, temperatures, and PM_GPU_PWRSTST / CM_GPU_CLKSTCTRL
  sampled 100 times across the second, all read-only through `/dev/mem`.
- `analyse.py gpuoff.csv gpuoff.log [cutoff_s]`: per-block means, and the step at each on/off
  switch (45 s before against 15–60 s after), which cancels the slow drift.

## Run of 2026-09-26, 5.6.19-m4-uprobe-kprobe *(measured)*

Desktop idle, screen backlight 5/15 and keyboard backlight 8/8 (read after the run), on battery (`bq24297/online` 0
throughout), over wifi. `gpuoff.csv`, `gpuoff.log`.

The registers confirm both states in every sample: *off* blocks read PD_GPU OFF 100% and
GPU clock activity 0%; *on* blocks read ON 100% and activity 100%.

| switch | at | before W | after W | GPU held ON costs | gpu_thermal |
| --- | --- | --- | --- | --- | --- |
| on → off | 90 s | 3.874 | 3.640 | **0.234 W** | +1.7 °C |
| off → on | 270 s | 3.644 | 3.835 | **0.192 W** | +1.2 °C |
| on → off | 450 s | 3.804 | 3.580 | **0.224 W** | +1.4 °C |

**The GPU held ON costs 0.22 W at desktop idle (0.19–0.23), about 6% of the 3.6–3.9 W
floor.** Nothing else in the machine changed between the arms.

- The temperature column is the 45 s change only, not a steady state. The die's time
  constant is longer than that, so the settled difference will be larger.
- **MATE blanked the panel at 618 s** (on battery, ten idle minutes), which alone took
  0.45 W off. Everything after 615 s is excluded above. One more switch landed in the
  dark, off → on at 630 s, 3.12 → 3.32 W, and agrees at about 0.20 W, but only 12 s of
  "before" exist, so it is not counted.
- Unexplained: a 0.07 W step down inside an *on* block at about 345 s. It does not touch
  the switch windows.
- The script now resets X's idle timer every 20 s and logs `MONITOR-OFF` if the panel
  still goes dark. The first attempt was also discarded: a kill signal ran the restore
  trap without ending the script, which then carried on with no sampler. The trap now exits.

## What this does and does not say *(reasoned)*

- It is the idle saving of any fix that lets the domain reach OFF, because the unloaded
  state is exactly that. A fixed driver will also pay for power-cycling on each wake.
- It says nothing about games. There the GPU is busy for much of each frame, and APM at
  its current 2 ms latency would cycle the domain between frames (23 times in a 3 s fill
  test). Whether that saves power or costs frame time needs its own measurement once a fixed
  module exists.

## The fix: 0034, and what it does *(measured, 2026-09-26, 5.6.19-m4-uprobe-kprobe)*

`0034-pvrsgx-let-the-sgx-power-domain-go-off-at-idle.patch` changes two files:
- `pvr_probe` drops its runtime-PM reference once the driver is up, and `pvr_remove` stops
  putting it back.
- APM's `DisableSGXClocks` releases through autosuspend, 100 ms by default and tunable
  through `56000000.gpu/power/autosuspend_delay_ms`. The DDK keeps its 2 ms APM cycle,
  which already ran before the patch, and only the power domain waits 100 ms of quiet.

`build-module.sh` builds it for the booted test kernel and leaves that kernel's source
unpatched.

**Installed on the device 2026-09-26, after the soak** (~7 h, all evening's SoH play and
battery runs, no L3/PVR error/recovery/lockup/oops line): `pvrsrvkm-apm.ko` (srcversion
`533BB7E5866E52F63B9ACCB`) is `/lib/modules/5.6.19-m4-kbdled/updates/pvrsrvkm_omap5_sgx544_116.ko`,
and `depmod` resolves the module there, ahead of the stock one in `kernel/`. It is not in the
initramfs. Only m4-kbdled (l5, the default, and l1) has it; the fallback l4 (`5.6.19-m4`)
keeps the stock module. Undo: delete that file and `depmod -a 5.6.19-m4-kbdled`.
**Trap:** the installer extracts over the module tree, so a *rebuilt* m4-kbdled still loads
this module from `updates/`. Rebuild it with the kernel (`PYRA_KERNEL_SUFFIX=m4-kbdled
./build-module.sh`) or delete it. The durable form is still 0034 in `patches/`.

**Idle:** usage 0, `suspended`, parent suspended, PD_GPU OFF, clocks gated, all with
the driver loaded.

**Wake from OFF:** 40 GL runs with gaps of 0.02, 0.08, 0.12, 0.3 and 1.5 s. None failed,
the fill rate stayed in a tight 480–508 Mpix/s at 640×360, and there were 12
resume/17 suspend cycles of the ti-sysc parent (gaps under 100 ms keep it up). At
1280×720 it gave 860–867 Mpix/s, the same as stock (860). No new L3 errors, and no SGX
recovery.

**`apmcompare.sh`, stock module against fixed, both loaded, on battery, CPU pinned at
1000 MHz:**

| | stock | fixed | fixed − stock |
| --- | --- | --- | --- |
| desktop idle, ABBA×2, 75 s (run1) | 3.820 / 3.859 / 3.851 / 3.860 W | 3.598 / 3.593 / 3.668 / 3.622 W | **−0.227 W** (pairs −0.222 −0.266 −0.183 −0.238) |
| PD_GPU OFF, idle | 0% | 100% | |
| SoH Market, 30 fps cap, ABBA, 150 s (run2) | 5.232 / 5.246 W | 5.261 / 5.243 W | **+0.012 W** (pairs +0.028 −0.003) |
| SoH fps | 29.74 / 29.77 | 29.75 / 29.80 | none |
| SoH render wall, median ms | 58.88 / 58.83 | 59.25 / 58.23 | none |
| PD_GPU OFF, game | 0% | 0% | |

- **The fix delivers the whole idle saving, and costs nothing measurable in the game.** The
  game's noise floor comes from run1: a bug meant all four of its game blocks ran the
  stock module, so they form an A/A check, and it reads +0.011 W (pairs +0.037
  −0.015). Run2's +0.012 W is inside that.
- In the game the domain never goes off. Frames come every 33 ms, inside the 100 ms delay,
  so play takes the same power path as before.
- Two bugs in the script, both now fixed. The game takes several seconds to exit, so a swap 2 s
  after killing it failed with "in use" (run1's game half). And the wait for it to exit
  was logged into the block it ended (run2's raw blocks; `apmanalyse.py` now windows game
  blocks to the 150 s the game actually runs). The script now checks which module is loaded
  (the fixed one is unsigned, so its taint reads `E`) and logs `WRONG-MODULE` on a mismatch.
- Pre-existing, not from the patch: the udev rule that runs `pvrsrvctl --start` on module
  add races the probe, and fails about half the time with the stock module as well.
  `apmcompare.sh` runs it again by hand when it has not reported.

## Suspend and resume with the fix *(measured, 2026-09-26)*

`gpusleep.sh` runs `device/pyra-sleep-test.sh` (RTC wake, freeze then mem, 20 s each) three
times, detached. The results and each sleep test's log are in `sleep/`.

| case | before suspend | freeze | mem (`deep`) | GL after resume | 1 s later |
| --- | --- | --- | --- | --- | --- |
| stock module | active, usage 1, PD_GPU ON | ok | ok | 866 Mpix/s | active, ON |
| fixed, GPU idle | suspended, usage 0, PD_GPU **OFF** | ok | ok | 856 Mpix/s | suspended, OFF |
| fixed, GL rendering in a loop through both suspends | active, usage 1, ON | ok | ok | 853 Mpix/s | suspended, OFF |

- In the third case the fill loop kept running across both suspends, and was
  still active with usage 1 right after resume. The run that spanned them reports
  13.9 fps only because its wall time includes about 40 s asleep. The next run gave 854 Mpix/s.
- No new L3, external abort, PVR error, SGX recovery or lockup messages: the count
  stayed at 6, all from before the test (the boot-time L3 warning and three
  init-race messages).
- This was the first suspend with the GPU driver exercised on this machine, the stock
  module included. It works on this kernel.

**Not yet tested:** hours of ordinary use.
