# Where the power goes while a game runs

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
