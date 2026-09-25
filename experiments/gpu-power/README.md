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
