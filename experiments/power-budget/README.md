# Where the power goes while a game runs

## 2026-09-29: the present quad (Shipwright NEXT.md item F's prize)

`./thermcost.sh present` on a benchmark build: 30/750 in `RenderThread` 2 at 870 mV (the shipped state), the
Market fixture, the game's own harness flipping `gSettings.ProbeSkipFlat` between 0 (the shipped picture) and 1024
(the game's 1280×720 quad left out of the present pass, a black window) in 60 s segments, 8 ABBA pairs in one
process. The harness writes each segment's arm into `thermcost.phase` through `SOH_BENCH_ARM_FILE`, so every row
of `thermcost-present.csv` is labelled. `./thermcost.sh panel` is its control, with no game: `xwud` showing a
Market frame or the black screen in one window, 750 MHz. Screen backlight 6. `python3 thermclock.py . present`
and `. panel` give the summaries.

| arm | ABBA watts | Δ W (t, MDE) |
| --- | --- | --- |
| 30/750 mode 2, quad drawn | 4.045 | reference |
| 30/750 mode 2, quad skipped | 3.886 | **−0.158 (−21.7, 0.017)** |
| no game: a Market frame on screen | (floor moved, see below) | reference |
| no game: black on screen | | −0.009 (−0.9, ~0.024) |

**The quad is 0.13-0.16 W**, as much as the undervolt; the panel drawing black is worth at most ~0.03 W, and the
keyboard backlight's pulse ~0.007 W of imbalance between the arms. Frames unchanged (period +7 µs, t 0.4). Shipwright
report 08 §8.52 has the rest, including why no plane is reachable under X.

The panel run's floor fell 0.77 W halfway (2.69 → 1.92 W, every arm alike): the desktop's idle timeout took the
keyboard backlight from 12 to 0 (the `kbl` column). Pairs survive it; absolutes across the step do not.

## 2026-09-28, later: the 750 MHz point undervolted

`./thermcost.sh undervolt`: 30/750 in `RenderThread` 2 (the build's default since report 11 §11.15),
one game process, the 750 MHz operating point at its table 950 mV against 870 mV, switched live with
`../undervolt/undervolt.sh set`. Screen backlight 9, as the run above. `python3 thermclock.py . undervolt`
gives `thermcost-undervolt-summary.txt` (its ABBA table labels the arms "MHz"; they are mV).

| arm | ABBA watts | Δ W (t) | hold watts | cpu / gpu / core °C (hold) | frames lost |
| --- | --- | --- | --- | --- | --- |
| desktop idle, ondemand | | | 2.76 | 46 / 49 / 48 | |
| 30/750 mode 2, 950 mV | 4.174 | reference | 4.212, then 4.144 | 63.0 / 65.4 / 63.1, then 63.8 / 66.3 / 64.1 | 0.71%, 0.57% |
| 30/750 mode 2, 870 mV | 4.015 | **−0.159 (−18.7)** | 4.024 | 61.9 / 64.7 / 62.5 | 0.68% |

**870 mV is −0.16 W and −1.5 °C** (the CPU die against the mean of the two stock holds, which
bracket it), frames unchanged. The stepping that chose 870 is in `../undervolt/README.md`.

## 2026-09-28: the GL thread (Shipwright report 11) through a lower clock

`./thermcost.sh twocore`, the same kernel, module, fixture and method as 09-26 below, but screen
backlight 9 (the desktop idle reads 2.73 W, against 2.62 at 5). Shipwright branch
`feature/pyra-two-core` at 30f9261 (libultraship 1b0ccaa8). `gSettings.RenderThread` 2 is set through
the harness's one-valued A/B CVar, so it is applied after the settle in a running game (launching
with it in the config is not safe yet, report 11). Mode 0 against mode 2 at 750 MHz is ABBA by
process (one game per 180 s block, the first 60 s after each launch a separate phase and the next
30 s dropped); 750 against 625 in mode 2 is ABBA in one process as on 09-26. frames lost are counted
from the BENCH split windows after the arm is applied. `python3 thermclock.py . twocore` gives
`thermcost-twocore-summary.txt`; the frames-lost column below drops two more windows (the arm's
first ~10 s), which the summary's raw column does not.

| arm | ABBA watts | Δ W | hold watts | cpu / gpu / core °C (hold) | frames lost at the Market |
| --- | --- | --- | --- | --- | --- |
| desktop idle, ondemand | | | 2.73 | 44 / 46 / 46 | |
| 30 fps, 1000 MHz, mode 0 | | | 4.51 | 67.6 / 69.9 / 67.7 | 0.8% |
| 30 fps, 750 MHz, mode 0 | 4.071, 4.101 | reference | not held | 58.0, 61.2 (blocks) | **4.3%, 3.2%** |
| 30 fps, 750 MHz, mode 2 | 4.177, 4.177 | +0.091 (+0.106, +0.076) | 4.21 | 64.3 / 66.7 / 64.2 | 0.8% |
| 30 fps, 625 MHz, mode 2 | 4.067 | −0.137 against mode 2 at 750 (t −38.6) | 4.07 | 62.3 / 64.9 / 62.7 | 1.5% (27.8 fps worst window) |
| 20 fps, 625 MHz, mode 0 | | | 3.71 | 60.5 / 63.4 / 61.3 | 0.9% |

**What it says**

- **The GL thread costs 0.09 W at the same clock** (two ABBA pairs, +0.106 and +0.076 W; ~+1 °C),
  its ~2 ms of extra machine CPU per frame. It pays only through the clock, and it does: at
  30/750 it holds the fixture as well as mode 0 at 1000 MHz (0.8% lost against 4.3/3.2% in mode 0
  at 750, the 09-26 run's 3.9%).
- **Against 30 fps at 1000 MHz: 30/750 in mode 2 is −0.30 W and −3.3 °C, 30/625 in mode 2 is
  −0.44 W and −5.3 °C** (holds; 1.5% of frames lost at 625). Mode 2 at 625 draws what mode 0 at 750
  drew (4.07 against 4.07-4.10 W) and holds 30 fps where mode 0 at 750 did not.
- **20 fps at 625 MHz is still 0.36 W and ~1.8 °C below the best 30 fps arm.** The design makes
  30 fps affordable; it does not make it as cheap as 20.
- The holds ran once each, in the order 625-m2, 750-m2, 1000-m0, 20/625, so their temperatures carry
  the run's drift (≤0.12 °C/min over the last 5 minutes of each). 30/1000 read 4.51 W against 4.43 on
  09-26: the brighter screen accounts for most of it (idle +0.11 W).
- **The keyboard backlight pulses while the game runs**, 50/100 for ~9 s then 12 for ~19 s, in every
  game phase and not at the desktop. The 09-26 run shows the same (1,480 of its samples at 50), so
  its "keyboard backlight 12/100" is only the desktop's. It is ~0.09 W while up (~0.03 W averaged),
  the same in every arm. What drives it is not yet known.

## 2026-09-26: the lowest clock that holds the game

`./thermcost.sh clock` on `5.6.19-m4-kbdled` #10 (keyboard backlight in
`/sys/class/leds/pyra::kbd_backlight`) with the GPU idle-power module
(`experiments/gpu-power/0034`) loaded by hand for its soak since 16:19, so the
GPU runtime-suspends (71% of uptime at the desktop), on battery, screen backlight 5, keyboard
backlight 12/100, wifi on. The load is SoH's Market fixture with game logic
running (`SOH_BENCH_STATIC=0`, fixed camera) at the game's frame cap. Watts are
from ABBA 60 s blocks inside one game process (first 15 s dropped, n = 4 blocks
per arm); die temperatures from 10-minute holds (last 3 minutes; the slope over
the last 5 is ≤0.2 °C/min in every hold). fps is the game's own count per ~5 s
window (`thermcost-clock-split.log`). `python3 thermclock.py .` reproduces every
number below from the files here (`thermcost-clock-summary.txt`).

| arm | ABBA watts | Δ W (t) | hold watts | cpu / gpu / core °C | frames lost at the Market |
| --- | --- | --- | --- | --- | --- |
| desktop idle, ondemand | | | 2.62 | 47 / 50 / 49 | |
| 30 fps, 1000 MHz | 4.352 | reference | 4.43 (4.39 at the end) | 67.7 / 69.9 / 67.5 (67.8 at the end) | 1.0% |
| 30 fps, 875 MHz | 4.179 | −0.173 (−51) | not held | | 1.4% |
| 30 fps, 750 MHz | 4.016 | −0.336 (−73) | 4.03 | 65.0 / 67.7 / 65.1 | **3.9%** (28.8 fps) |
| 20 fps, 750 MHz | 3.712 | reference | 3.73 | 62.1 / 64.9 / 62.8 | 0.6% |
| 20 fps, 625 MHz | 3.597 | −0.115 (−10.5) | not held | | 0.8% |
| 20 fps, 500 MHz | 3.504 | −0.208 (−35) | 3.51 | 59.5 / 62.7 / 60.6 | **2.4%** (19.5 fps) |

The 30 and 20 fps runs are separate game processes, so the step between them
is from the holds only: at 750 MHz, 20 fps is −0.30 W and −2.9 °C against 30.
The last hold repeated the first (30 fps, 1000 MHz) after 70 minutes and read
−0.04 W and +0.1 °C, so the holds are comparable.

**What it says**

- **The game costs 1.8 W above the desktop at 30 fps and 1000 MHz.** The
  cheapest arm that holds 20 fps, 750 MHz, cuts that to 1.1 W, and 500 MHz
  halves it (0.9 W). Die temperature follows at 7-9 °C per watt: 67.7 °C at
  30/1000, 65.0 at 30/750, 62.1 at 20/750, 59.5 at 20/500.
- **At 30 fps the clock is worth 0.17 W per 125 MHz step (≈ 1.2 °C).**
  875 MHz holds the Market (1.4% lost against 1.0% at 1000); 750 does not
  (3.9%, every window under 29.5 fps), even though the render thread averages
  only 19.2 ms per frame there: the tick runs logic, then 1.5 frames, then
  waits on the swap, and the busy windows (p95 40 ms per 50 ms tick) miss vsync.
- **Dropping to 20 fps is worth more than any clock step at 30**: −0.30 W at
  the same clock, and it lets the clock go to 625-750 MHz with fewer frames lost
  than 30 fps at 1000. 500 MHz at 20 fps loses 2.4%.
- **Render CPU scales slightly less than the clock** (×1.28 from 1000 to 750
  MHz, ×1.46 from 750 to 500), as it should with memory stalls.
- **The idle floor has dropped**: 2.62 W and 47-50 °C at the desktop, against
  3.75 W and 56-60 °C on 2026-09-25. Two things changed: the GPU now runtime-
  suspends (the 0034 module on its soak; section below), and both backlights are lower.
  This run did not separate the two.
- The fixture is the Market with a fixed camera. Whether 875 MHz holds 30 fps in
  real play is still to be checked in the heavy scenes (Shipwright report 08
  §8.43: the Market, Kokiri Forest, Hyrule Field).

## 2026-09-25: the first run


Measured on 2026-09-25 on `5.6.19-m4`, on battery, with Ship of Harkinian's
Market fixture as the load: game logic running, 30 fps cap, 640×360. The only
instrument this machine has is the battery gauge
(`bq27421-0/current_now`, `voltage_now`). It measures the whole machine, so every
figure here is a difference between two arms. The arms alternate in ABBA
blocks of 60 s, and the first 15 s of each block is dropped.

`thermcost.sh` runs entirely on the device, so USB networking can go away
when the cable is pulled. It waits for `bq24297/online` to read 0 before
starting. `thermcost.csv` holds one row per second.

## Result

| condition | battery power | cpu / gpu / core °C |
| --- | --- | --- |
| desktop idle, ondemand | 3.75 W | 56 / 59 / 58 |
| desktop idle, pinned 1250 MHz | 4.09 W | 58 / 60 / 60 |
| SoH, 1250 MHz (warm-up, then the 1.5 GHz blocks after the daemon capped them) | 5.58–5.82 W | 69–74 / 71–76 / 69–73 |
| SoH, 1000 MHz | 5.37–5.45 W | 70–73 / 72–74 / 70–72 |
| idle again after the game, pinned 1250 MHz | 4.23 W | 66 / 69 / 67 |

(The keyboard backlight values below are the old 0-8 scale of
`/sys/class/backlight/keyboard-backlight`; the kbdled kernels use `leds`, 0-100.)

Screen backlight 7/15 and keyboard backlight 8/8 throughout, except in the
two backlight arms:

| arm | A | B | Δ | Δ die temperature |
| --- | --- | --- | --- | --- |
| keyboard backlight 0 → 8 | 4.51 / 4.52 W | 5.71 W | **+1.19 W** | none on die; battery +1.1 °C |
| screen backlight 1 → 15 | 5.57 / 5.59 W | 6.43 W | **+0.85 W** | none on die |
| CPU 1000 → ~1250 MHz | 5.37–5.45 W | 5.69–5.82 W | **+0.3 W** | about +2–3 °C |

Both repeats of each A arm agree within 0.02 W.

## What it says

**For the battery, the keyboard backlight is the largest single item.** At
full brightness it costs 1.2 W, more than the game's whole CPU clock
choice and about a fifth of the total draw while playing. Turning it off
takes a game session from about 5.7 W to 4.5 W: 3.7 h to 4.7 h on the
21.3 Wh pack. The screen backlight is next, at 0.85 W between minimum and
maximum.

**For die temperature, those two do not register.** Both are off-die LEDs.
The SoC sensors did not move between the backlight arms. The keyboard
backlight warmed the battery by 1.1 °C instead. That would reach the die
through the case over a longer run, but it is not what the thermal daemon
reacts to.

**What sets die temperature is mostly the idle floor.** At desktop idle the
die already sits at 56–60 °C. Assuming a room at 25 °C, that is roughly 33
of the 48 or so degrees above ambient the die reaches during play. The game
adds about 1.5 W and 11–15 °C on top. The floor is high because the A15s have
one usable idle state (`C1`, MPUSS on; `C2` hangs the machine, see
`experiments/c2-idle/`). The GPU sensor is the hottest of the three in every
phase, idle included.

**1.5 GHz is not sustainable even at a 30 fps cap.** The CPU sensor went from
71 °C to 77.7 °C in ten seconds at 1.5 GHz, and `pyra-thermal` capped the clock
at 1.25 GHz for the rest of both blocks. Its 5 °C release hysteresis never
let it go. So both 1500 MHz arms were in effect 1250 MHz arms, and the clock
comparison is 1000 against 1250.

**1000 MHz is free for this game.** SoH held 30 fps at 1000 MHz throughout
(`SOH_BENCH_SPLIT` windows in `thermcost-split.log`: 29.4–30.0 fps), for 0.3 W and
about 2–3 °C less than at 1250 MHz.

**Not separated.** The game's remaining ~1.2 W above idle is GPU, DDR and CPU
activity together. The SGX has no devfreq node and no rail monitor, so it
cannot be isolated with this instrument. Leakage rises with temperature: the
same pinned idle cost 0.14 W more at 66 °C than at 58 °C. The ABBA arms bracket
this, but the idle-versus-game rows are at different temperatures. The
sampler itself forks about a dozen `cat`s a second, which is a small constant
load on every arm.

## The GPU never powers down (added the same day; fixed by `experiments/gpu-power/0034`, on soak since 2026-09-26, not yet the default)

Sampled at 200 Hz for 15 s at desktop idle, with no GL client running, using
`experiments/gpu-clock/`'s register access (TRM addresses):

| register | reads | meaning |
| --- | --- | --- |
| `PM_GPU_PWRSTCTRL` (0x4AE07500) | `0x00030000` | target power state **OFF** |
| `PM_GPU_PWRSTST` (0x4AE07504) | POWERSTATEST 3, logic ON, 100% of samples | domain **ON-ACTIVE**, never left |
| `CM_GPU_CLKSTCTRL` (0x4A009500) | `0x603` | clock domain HW_AUTO; `GPU_CORE_GCLK` and `GPU_HYD_GCLK` **running**, 100% of samples |
| `CM_GPU_GPU_CLKCTRL` (0x4A009520) | IDLEST 2, STBYST 1 | module idle and in standby |
| `CM_DIV_H14_DPLL_CORE` | 63 (÷5) throughout | 425.47 MHz; no frequency scaling |

`/sys/bus/platform/devices/56000000.gpu/power`: `runtime_status active`,
**`runtime_suspended_time 0`** after 8857 s of uptime. The SGX completes its
idle handshake, but nothing on the kernel side ever releases it. The power
domain is programmed to go OFF and stays ON with its functional clocks running.
This is consistent with `gpu_thermal` being the hottest sensor in every phase,
idle included. What it costs is **not measured**. Getting it back would need
`pvrsrvkm`'s active power management to call `pm_runtime_put`; whether this DDK
build has that support compiled in is the next thing to check.
