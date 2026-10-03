# Measuring power on the Pyra

How to measure what something costs in watts on this machine, what has been
measured, what went wrong along the way, and the runs still to do. Written
2026-09-26 for a later session to pick up and act on. Most of it came out of
the GPU idle-power work in `experiments/gpu-power/`.

Tags as elsewhere: **measured** on the device, **spec** from the TRM,
**reasoned** from those.

## The short version

- The only instrument is the battery fuel gauge. It sees the whole machine and
  only while it runs on battery.
- So every result is a **difference between two arms**, alternated in ABBA
  blocks, measured on battery, by a script that runs entirely on the device.
- The noise floor at that scale is about **±0.03 W** *(measured: A/A check,
  150 s blocks)*. Anything smaller than about 0.05 W needs more blocks.

## The instrument

| what | where | notes |
| --- | --- | --- |
| battery current | `/sys/class/power_supply/bq27421-0/current_now` | µA, **signed: negative while discharging** |
| battery voltage | `/sys/class/power_supply/bq27421-0/voltage_now` | µV. Power = −current × voltage |
| on USB power? | `/sys/class/power_supply/bq24297/online` | must read **0**, or the charger carries the load and the gauge sees nothing useful |
| temperatures | `/sys/class/thermal/thermal_zone{0,1,2}/temp` | cpu, gpu, core, m°C. Zone 3 is the gauge die, zone 4 the charger |

- **It averages over its own window.** A step change takes several seconds to show.
  Drop the first 15 s of every block *(measured: the switch steps in
  `experiments/gpu-power/` settle within that)*.
- **It is whole-machine only.** There is no per-rail measurement. The board's one
  INA231 is on the modem rail, and no modem is fitted (`device/pyra-modem-power.sh`
  explains). Attribution comes only from switching one thing at a time.
- **`bq24297/online` has read 0 with the USB cable plugged in** *(measured,
  2026-09-26)*: the port was supplying data and no charge. Check it rather than
  assuming. The memory note `pyra-battery-charging` has the background.

## Method

1. **Run on the device, detached**, with `setsid nohup … &`, stdout redirected. Unplugging the
   cable, switching wifi off or suspending cuts the ssh session, and the run must
   not care. Reach the device over wifi (`<wlan-address>`) when the USB network has
   to go. `. ./pyra-local.conf` sets `PYRA_HOST` and the ssh agent.
2. **Wait for `bq24297/online` = 0** before measuring, then settle 20–30 s.
3. **Pin the CPU**: userspace governor + `scaling_setspeed`, both cores, and put
   `ondemand` back on exit. Never pin with min == max: `pyra-thermal` rewrites
   `scaling_max_freq` every 2 s. 1000 MHz
   is the default here, since Ship of Harkinian holds 30 fps there.
4. **Keep the panel on.** MATE blanks it after 10 idle minutes on battery, and that
   alone is a 0.45 W step *(measured)*. Run `xset s reset` as the `pyra` user every
   20 s, and log `MONITOR-OFF` if `xset q` still reports it off (see `gpuoff.sh`).
5. **ABBA, twice when you can**: A B B A A B B A. It cancels a linear drift (battery
   voltage falling, the die cooling). Blocks of 60–90 s for idle arms, 150 s for a
   game (drop its first 45 s: loading, settling, GPU warm-up).
6. **Report the steps as well as the block means.** At each A→B switch, compare the
   mean of the 45 s before it with 15–60 s after it. Steps cancel drift better
   than block means, and three switches that agree to within ±0.02 W are a result
   (`experiments/gpu-power/analyse.py`).
7. **Sample state, not just power.** One long-lived sampler writes one row a
   second (`experiments/gpu-power/sample.py`): gauge, temperatures, `online`, and
   whatever proves each arm really was in the state it claims. For the GPU: the
   PD_GPU power state and clock activity 100 times a second, and `runtime_status`.
8. **Record the settings at the start**: screen and keyboard backlight, CPU
   frequency, kernel, loaded modules, wifi. They drift between sessions *(on
   2026-09-26 they were 5/15 and 8/8 during the runs, and 4/15 and 1/8 afterwards)*.
9. **Restore everything in a trap that exits**: `trap restore EXIT` plus `trap 'exit 1'
   INT TERM HUP`. A trap that only restores lets the script carry on without its
   sampler.

## Results so far

| what | cost | conditions | source |
| --- | --- | --- | --- |
| desktop idle floor, GPU fix loaded | **3.60 W** | 1000 MHz pinned, backlight 5/15, keyboard 8/8, USB Ethernet adapter attached | `experiments/gpu-power/run1` |
| desktop idle, ondemand, GPU held on | 3.75 W | backlight 7/15, keyboard 8/8 | `experiments/power-budget` |
| keyboard backlight 0 → 8 | **+1.19 W** | during SoH | `experiments/power-budget` |
| screen backlight 1 → 15 | **+0.85 W** | during SoH | `experiments/power-budget` |
| CPU 1000 → ~1250 MHz | +0.3 W, +2–3 °C | during SoH | `experiments/power-budget` |
| GPU held on at idle (stock pvrsrvkm) | **+0.22 W** | unload test: 0.234 / 0.192 / 0.224 W | `experiments/gpu-power/gpuoff.*` |
| GPU fix (0034) against stock, idle | **−0.227 W** | four ABBA pairs | `experiments/gpu-power/run1` |
| GPU fix against stock, SoH 30 fps | +0.012 W (noise) | A/A noise +0.011 W | `experiments/gpu-power/run2` |
| screen blanked by DPMS | −0.45 W | idle, GPU off | `experiments/gpu-power/gpuoff.csv` at 618 s |
| Ship of Harkinian, Market, 30 fps cap | 5.2–5.8 W | 1000–1250 MHz, backlights on | both |

*(All measured.)* Estimated from those, not measured: idle with the keyboard
backlight off and the screen at minimum would be about **2.2–2.4 W**.

**Not measured:** the USB Ethernet adapter (attached in every run above), wifi,
the screen at levels between 1 and 15, suspend-to-RAM, and the GPU at 384 MHz.

## Pitfalls, and the guard for each

| what went wrong | effect | guard now in the scripts |
| --- | --- | --- |
| MATE blanked the panel mid-run | −0.45 W step, block lost | `xset s reset` loop + `MONITOR-OFF` log |
| a signal ran the restore trap, which did not exit | script continued with no sampler and the CPU pinned | `trap restore EXIT` + `trap 'exit 1' INT TERM HUP` |
| `pkill -f <pattern>` over ssh | matched the ssh command line itself and killed the session | bracket trick: `pgrep -f "[g]puoff"` |
| module swap 2 s after killing the game | "in use", swap failed silently, all game arms ran stock | wait for the process, then for `refcnt` 0; verify taint afterwards |
| swap time logged under the previous block | 6 s of the wrong state per block | analysis drops each block's last 8 s |
| wait for game exit logged under the game block | idle power mixed into the game mean | game blocks windowed to the game's own 150 s |
| `ssh … & sleep; cat` hung | ssh held open by the background job | `(setsid nohup … > out 2>&1 < /dev/null &)` |
| scp dropped the exec bit | "Permission denied" | `chmod +x` locally before copying |
| charger status assumed | — | wait loop on `bq24297/online` |
| kprobes on m4 / m4-uprobe | kernel `BUG()` in the optprobe code | `echo 0 > /proc/sys/debug/kprobes-optimization`, or a kernel with `patches/0033` |
| `udevadm`/`dmesg` from the `pyra` user | empty or permission errors, which look like results | run the checks with sudo |
| ssh after a reboot | 2–4 min before it answers (r8152 firmware timeout) | poll, don't assume the boot failed |

## Tools

| script | runs on | what it does |
| --- | --- | --- |
| `experiments/gpu-power/sample.py` | device | the sampler: gauge, temps, `online`, PD_GPU / GPU clock / runtime-PM fractions, one row a second |
| `experiments/gpu-power/gpuoff.sh` | device | GPU driver loaded against unloaded, ABBA×2, 90 s; `check` = one cycle with registers printed |
| `experiments/gpu-power/analyse.py` | PC | block means + switch steps for `gpuoff.sh` output |
| `experiments/gpu-power/apmcompare.sh` | device | stock against fixed pvrsrvkm: idle ABBA×2, then SoH ABBA; `soh` = game half only |
| `experiments/gpu-power/apmanalyse.py` | PC | block means, ABBA pairs and SoH frame stats for `apmcompare.sh` |
| `experiments/gpu-power/gpusleep.sh` | device | suspend/resume cases through `device/pyra-sleep-test.sh` |
| `experiments/power-budget/thermcost.sh` | device | the first budget run: idle, SoH, CPU clock, both backlights |
| `experiments/gpu-clock/gpumux.py` | device | read or switch the GPU clock source (425 ↔ 384 MHz) |
| `device/pyra-sleep-test.sh` | device | RTC-woken freeze-then-mem suspend test, detached |

Copy the scripts to `~/gpu-power/` on the device, and the `.py` next to them.
Registers are read through `/dev/mem` with Python `mmap`: `devmem2` returns zeros
on this kernel.

## Next runs

Each is independent. Ask the user before anything that changes hardware state
beyond backlights, wifi and the CPU governor. Anything the user must do by hand
(unplugging) goes in the plan with a time.

### 1. The idle budget

**Question:** where does the 3.6 W go? One run on battery, the desktop idle, CPU
pinned at 1000 MHz, the GPU fix loaded if the booted kernel has a build of it.
ABBA×2 per arm, 75 s blocks, about 35 min for all of it.

| arm | how to switch it | notes |
| --- | --- | --- |
| keyboard backlight 0 / 8 | `/sys/class/backlight/keyboard-backlight/brightness` | expect about 1.2 W; confirms the in-game number at idle |
| screen backlight 1 / 8 / 15 | `/sys/class/backlight/backlight/brightness` (max 15) | gives the curve, not just the ends |
| wifi on / off | `nmcli radio wifi off` / `on` (no `rfkill` installed) | cuts the ssh session: the script must run detached and restore wifi in its trap |
| USB Ethernet adapter | sits at `1-2.1` on the internal hub, driver `r8152` | `echo 0 > /sys/bus/usb/devices/1-2.1/authorized` unbinds it, but the port stays powered *(reasoned; untested)*. This 5.6 kernel has no per-port `disable` attribute *(checked: `1-2-port1/` has none)*. So the real number needs a physical-unplug arm done by hand, at times the script prints. Use the `authorized` arm only to see what unbinding the driver alone saves. |

Output: one table, cost per arm, with the switch steps. Add it to "Results so far"
above, and to `docs/improvements.md` where an item is concerned.

### 2. GPU clock 384 against 425 MHz, in a game

**Question:** does a lower GPU clock save power when a game holds its cap? This
decides whether GPU frequency scaling (porting the DDK's unbuilt `sgxfreq`
governors) is worth building. Ship of Harkinian, the Market fixture from
`apmcompare.sh`, 30 fps cap, CPU at 1000 MHz. Switch with `gpumux.py set per` /
`set core` (only at module idle; the script waits for it). ABBA×2, 150 s blocks.
Record the fps and render wall time as well as the power, because 384 MHz costs
9.2% of fill rate *(measured)*. Decision rule: under about 0.05 W, record it and
stop; 0.2 W or more, the governor port is worth it.
Voltage stays at VDD_MM nominal either way. Do not touch the voltage.

### 3. Suspend-to-RAM draw

**Question:** what does a suspended Pyra draw? Nobody has measured it
(`docs/troubleshooting.md`, "What it saves"). The gauge cannot be sampled while
the machine sleeps, so use its coulomb counter instead: read `charge_now` (µAh)
before and after a long `mem` suspend (30–60 min, RTC wake through
`pyra-sleep-test.sh --mode mem --seconds N`). Compare with the same span awake
at idle. The counter's resolution is coarse, which is why the span is long.

### 4. The GPU fix's wake cost

The cost of waking the GPU from OFF (resume latency, and the power spike) is not
measured. It is the next task in the GPU idle-power work. Listed here because
the method is this document's.
