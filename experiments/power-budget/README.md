# Where the power goes while a game runs

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

## The GPU never powers down (added the same day)

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
