# Headphone jack detection

The card always reports a headset plugged in, so PulseAudio cannot switch
between speakers and headphones on its own. This is the diagnosis and the plan
to fix it.

**Status: diagnosed on hardware 2026-10-23, on the stock bookworm-7 card
(`experiments/bookworm-baseline/`). Step 1 (0037) built and passing on five
warm and five cold boots. Step 2 (0038) follows the plug on both cards.
Suspend found a third fault, fixed by 0039, which passes on the trixie card.
All three are in `kernel-m4-kbdled`, the kernel the trixie card runs, since
2026-10-24. 4-pole headsets and the buttons are untested. Step 3 switches to
the headphones on plug-in but not back on unplug: the TS3A227E cannot see a
removal while the headset amplifier is on. Step 4 not done.**

## The fault

`Headset Stereophone Jack` and `Headset Mic Jack` both read `on`, and the
`Letux Cortex 15 Headset Jack` input device reports `SW_HEADPHONE_INSERT 1`,
whether or not anything is in the jack. It does this on stock bookworm with
the stock kernel, on the trixie card, and on every kernel of ours. It is not
caused by the AESS work.

## Two faults, not one

The Pyra has a dedicated jack-detect chip, a **TS3A227E** on i2c5 at `0x3b`
(`4-003b`). Its interrupt goes to pin 14 of the **PCAL6524** GPIO expander at
`4-0022` (the line the DT names `mic-int`, `P16` in the expander's own
numbering). Two separate things stop it reaching the sound card.

### 1. The chip never probes: its interrupt pin is an output

Every boot:

    gpio gpiochip10: (4-0022): gpiochip_lock_as_irq: tried to flag a GPIO set as output for IRQ
    gpio gpiochip10: (4-0022): unable to lock HW IRQ 14 for IRQ
    genirq: Failed to request resources for TS3A227E (irq 197) on irqchip 4-0022
    ts3a227e 4-003b: Cannot request irq 197 (-5)
    ts3a227e: probe of 4-003b failed with error -5

The expander's configuration registers, read raw right after a fresh boot
(`i2ctransfer -f -y 4 w1@0x22 0x8c r3`):

| bank | config (1 = input) | pin 14 |
| --- | --- | --- |
| 0 | `0xfc` | |
| 1 | `0x08` | P16 = bit 6 = **0, output** |
| 2 | `0xf2` | |

Bank 1 has only P13 (`chg-int`) as an input. The PCAL6524 resets to all
inputs, so something writes `0x08` before the kernel probes the expander. The
kernel reads that direction once at `gpiochip_add`, and because the expander
is an i2c device (`can_sleep`), `gpiochip_lock_as_irq()` trusts the cached
flag rather than re-reading. `pca953x_irq_bus_sync_unlock()` would make the
line an input, but it runs only after the resource request, which has
already failed.

**Who writes `0x08` is not established.** The obvious suspect is U-Boot: the
Pyra board file in `u-boot-pyra` 0.1.5
(`board/pandora/pyra+lc15/pyra+lc15.c`) pulses the peripheral reset and then
writes an initial state to the expander. But its table makes P16 an input
(`P16_MICPRES | P13_CHG_INT`, `0x48`), and the compiled table could not be
found in the SPL or `u-boot.img` to confirm which version is running. The SPL
on the bookworm card is byte-identical to the packaged
`/usr/lib/u-boot/pyra/MLO`; the eMMC has an older 2016.11 build from 2020. A
`i2c md` from the U-Boot prompt over serial would settle it. The fix below
does not depend on the answer.

**Setting the pin to input by hand makes it work.** On the running stock
system:

    echo 490 > /sys/class/gpio/export
    echo in  > /sys/class/gpio/gpio490/direction
    echo 490 > /sys/class/gpio/unexport
    echo 4-003b > /sys/bus/i2c/drivers/ts3a227e/bind

The driver binds, IRQ 197 appears in `/proc/interrupts`, and the chip is
right. Its accessory status register (`0x0b`) reads `0x00` with the jack
empty and `0x09` (`JACK_INSERTED | TYPE_3_POLE`) with 3-pole headphones in.
Three unplug/replug cycles, logged every 200 ms (`plug-cycle-20261023.log`):

    22:31:28.204 acc=09 irq=0 twl_hp=10
    22:31:59.354 acc=00 irq=1 twl_hp=10
    22:32:04.202 acc=09 irq=2 twl_hp=10
    22:32:08.983 acc=00 irq=3 twl_hp=10
    22:32:13.171 acc=09 irq=4 twl_hp=10
    22:32:20.660 acc=00 irq=5 twl_hp=10
    22:32:23.892 acc=09 irq=6 twl_hp=10

One interrupt per transition, no storm, no missed edge. `twl_hp=10` is
`evtest --query` saying the card's jack is still "inserted" throughout, which
is the second fault.

The TS3A227E driver asks for `IRQF_TRIGGER_LOW`; the PCAL6524 driver only
does edges and turns a low-level request into falling-edge. The log shows
that is enough for one event at a time. Two events closer together than the
handler can read the chip have not been tested.

### 2. The sound card does not use the chip

`sound/soc/ti/omap-abe-twl6040.c` takes jack state from the codec:

    snd_soc_card_jack_new(rtd->card, "Headset Jack", SND_JACK_HEADSET, &hs_jack, ...);
    twl6040_hs_jack_detect(component, &hs_jack, SND_JACK_HEADSET);

The TWL6040's own plug comparator says "inserted" at boot and never changes.
On stock its `twl6040_irq_plug` count stays at 0. On our AESS kernel it had
counted 44598 after two hours (`docs/audio.md`), so there it fires, or
bounces, without ever reporting removal. Either way the Pyra does not route
jack detection through the codec. Nothing in the tree calls
`ts3a227e_enable_jack_detect()` for this card.

**letux has not fixed this.** In `letux-7.3`, `letux-current` and master
(checked 2026-10-23) `omap-abe-twl6040.c` still calls only
`twl6040_hs_jack_detect()`, and no Pyra dtsi hogs the pin. The v5.2 and
v5.3 mainboard dtsi there carry the TS3A227E interrupt with the comment
"interrupts now working with pcal6524", but nothing consumes the chip's
reports.

## The plan

Patch numbers are the next free ones. Each step is tested before the next.

### Step 1: `0037` arm: dts: pyra: make the jack-detect line an input

In `pyra-mainboard-v5.2.dtsi` and `pyra-mainboard-v5.3.dtsi` (the two that
give the TS3A227E an interrupt), add a GPIO hog on `gpio99` line 14:

    &gpio99 {
        mic-int-hog {
            gpio-hog;
            gpios = <14 GPIO_ACTIVE_HIGH>;
            input;
            line-name = "mic-int";
        };
    };

Hogs are applied inside `gpiochip_add`, after the initial direction read and
before any consumer probes, and `gpiochip_lock_as_irq()` only refuses lines
flagged as outputs. A hogged input can still be used as an IRQ.

- **Why not the driver.** Making `pca953x` set a line to input in its
  `irq_request_resources` is the more general fix, and worth proposing
  upstream, but it changes behaviour for every board using that driver. The
  hog only touches the Pyra.
- **Why not the bootloader.** We cannot show which table the running SPL
  uses, and a fix there does nothing for anyone who has not reflashed it.

**Test:** cold boot and warm boot, 5 each. `ts3a227e` bound, IRQ 197 present,
no `gpiochip_lock_as_irq` line in `dmesg`, register `0x0b` follows the plug.
Confirm in `/sys/kernel/debug/gpio` that the line shows as an input hog and
nothing else on the expander changed direction.

**Result, 2026-10-23.** Built as `kernel-jack` (stock source + 0037 only,
`5.6.19-jack`) and booted on the stock bookworm card through the l1 slot.
Five warm boots, every one identical:

    boot N: 5.6.19-jack hog=1 lockerr=0 drv=ts3a227e irq=1 cfg=0xfc,0x48,0xf2 acc=09

- `GPIO line 490 (mic-int) hogged as input`, and no `gpiochip_lock_as_irq`
  error.
- `ts3a227e` bound, IRQ 197 registered, the line shown as `in ... IRQ`.
- Bank 1's config is `0x48` instead of `0x08`; banks 0 and 2 are unchanged
  from stock (`0xfc`, `0xf2`). Nothing else on the expander moved.
- Accessory status `0x09`, with 3-pole headphones in throughout.

**Cold boots, 2026-10-23, five from power off.** Boots 1-3 empty at boot,
headphones in for a few seconds after login, then out; boot 4 plugged in
through boot and poweroff; boot 5 empty throughout. From the journal, all
five: the line hogged as an input, no `gpiochip_lock_as_irq`, no `ts3a227e`
probe failure. With or without a plug at boot makes no difference to the
probe.

The plugging itself left no record and could not: until 0038 nothing listens
to the chip, and its state is not logged. The sysfs test before this one is
still the evidence that the chip follows the plug once probed. The first plug
test with a record is step 2's, where the card's own jack control should
change.

**Hung-task warnings on every `5.6.19-jack` boot, and at poweroff.** Not 0037.
They are `mmc_rescan` -> `sdio_reset` workers on `mmc1` and `mmc2`, the two
phantom `txs02612` hosts that `patches/0003` removes. `kernel-jack` leaves
`patches/` out on purpose, so it has them, as stock does; stock just has no
hung-task detector to say so, and every `build_kernel_variant` build turns
one on. Poweroff waits on the same stuck `udev-worker`. A
`driver_set_config_work` worker (USB configuration) is also reported blocked;
not looked at.

PulseAudio came up with only `auto_null` on four of the six jack boots. That
is not 0037: a stock boot did the same, and the cause is the lightdm
greeter's own PulseAudio still holding `hw:L15` when the user's starts. A
restart loads all three sinks. Trixie cards get `device/pyra-greeter-audio.sh`
for it; stock bookworm does not have it.

### Step 2: `0038` ASoC: ti: omap-abe-twl6040: use the TS3A227E for the jack

The pattern is `sound/soc/rockchip/rockchip_max98090.c`: the detector is a
card auxiliary device, and its `init` callback hands it the jack.

1. DT: add `ti,jack-detect = <&ts3a227>;` to the `sound` node (a label on
   the `ts3a227@3b` node in `pyra-mainboard-common.dtsi`), only in the
   v5.2/v5.3 mainboard dtsi. Boards without it keep the TWL6040 path.
2. Probe: if the phandle is present, add one `snd_soc_aux_dev` with
   `dlc.of_node` set to it and `init` set to a new
   `omap_abe_ts3a227e_init()`.
3. `omap_abe_ts3a227e_init()`: create `hs_jack` there with
   `SND_JACK_HEADSET | SND_JACK_BTN_0..3` and the existing `hs_jack_pins`, map
   the buttons to `KEY_PLAYPAUSE`, `KEY_VOICECOMMAND`, `KEY_VOLUMEUP`,
   `KEY_VOLUMEDOWN` as rockchip does, and call
   `ts3a227e_enable_jack_detect()`. In 5.6 `snd_soc_bind_card()` probes aux
   devices before it runs the DAI links' `init`
   (`soc_probe_aux_devices()` then `soc_init_pcm_runtime()`), so the jack
   exists by the time the link init runs.
4. `omap_abe_twl6040_init()`: when the TS3A227E path is active, skip
   `snd_soc_card_jack_new()` and `twl6040_hs_jack_detect()`.
5. Kconfig: `select SND_SOC_TS3A227E` from `SND_SOC_OMAP_ABE_TWL6040`, since
   the call is now a hard symbol dependency. It is already built as a module
   in `pyradef`; check the defconfig still agrees.

This must work on both of our link layouts: the direct McPDM link and the
AESS DL1 link. Both run `omap_abe_twl6040_init()` (and the AESS reference
link deliberately runs no init, see the comment at `ADD_DAILINK(...
"McPDM-direct" ...)`), so the change is in one place.

**Test:**

- Empty jack at boot reads `off`; plugged at boot reads `on`. Plug and unplug
  20 times on each of `-m4-kbdled` (AESS) and a direct-link kernel.
- A 4-pole headset sets `Headset Mic Jack` as well, and its buttons produce
  key events in `evtest`. 3-pole headphones do not set the mic.
- Suspend with headphones in, unplug while asleep, resume: state must be
  correct after resume. Then the reverse. The TS3A227E driver has
  no suspend/resume handling of its own, so this is the step most likely to
  find something.
- `twl6040_irq_plug` count after an hour of uptime on the AESS kernel, to
  see whether the 44598-count bouncing still happens and needs masking.

**Result, 2026-10-23.** Built into `kernel-jack` (stock + 0037 + 0038) and
booted on the bookworm card. It applies cleanly on stock + 0037, and on the
AESS tree (`src-m4-kbdled` + 0037) with one hunk at fuzz 1, the struct, whose
trailing context the AESS series changed.

- With the jack empty at boot, `Headset Stereophone Jack` and `Headset Mic
  Jack` read `off` and `SW_HEADPHONE_INSERT` is 0. The first time either has
  said so on this hardware.
- The input device now advertises `SW_HEADPHONE_INSERT`,
  `SW_MICROPHONE_INSERT` and the four button keys.
- Three plug/unplug cycles (`plug-cycle-0038-20261023.log`): the control and
  the input switch follow the chip every time, one interrupt and one event
  per change.
- The third plug was a Bluetooth headset's 3.5 mm cable. The chip read
  `0x09`, 3-pole, so its cable carries no mic contact (or the chip did not
  find one) and `Headset Mic Jack` stayed `off`. That is the right answer for
  what was plugged in, but it means the mic and the buttons are untested.
- PulseAudio loaded its sinks; the card registered once, with no deferral
  noise in `dmesg`.

**On the trixie card, 2026-10-24.** 0037 and 0038 added to
`kernel-m4-kbdled` (the AESS kernel, with `patches/`), built in the real tree
and installed over the running `5.6.19-m4-kbdled`; the previous build is kept
on the card as `/home/pyra/m4-kbdled-before-0037-20261024.tar.gz`. The AESS
path came up as before (10 DAI links, PulseAudio's `aess` sink), the card
registered 6.6 s after the kernel started, as before, and five plug changes
were each reported once. `twl6040_irq_plug` stays at 0; the 44598 count in
`docs/audio.md` came from the TWL6040 jack path that 0038 no longer uses.

### Step 2b: `0039` ASoC: ts3a227e: clear pending events at probe and resume

Suspend found a third fault, in the TS3A227E driver itself.

**Plugging or unplugging while asleep kills the jack until reboot.**
Headphones in, suspend to RAM, unplug, resume: the chip reads `0x00` but the
card still says `on`, and its interrupt count has not moved. The chip raised
INTB for the unplug while its interrupt was disabled, and the expander only
interrupts on a change of the line, which is now over. INTB stays low until
the interrupt register is read, and nothing reads it: `ts3a227e_resume()`
only calls `enable_irq()`. So no later edge can arrive either. Two more
plug/unplug cycles: the chip follows, the expander's own interrupt fires,
the TS3A227E handler never runs, `mic-int` stays `lo`.

**And it survives a warm reboot.** The chip is not reset, the event is still
pending, and probe reads only the accessory status, so the next boot comes
up with INTB low and the jack dead for the whole boot
(`dead-after-reboot-0038-20261024.log`). letux 7.3's driver has the same
bare `enable_irq()` resume and the same probe.

A logger trap, found on the way: dumping
`/sys/kernel/debug/regmap/4-003b/registers` reads `0x01` and `0x02`, which
clear on read, so a logger doing that steals the driver's events. It made the
first suspend run look like a recovery. `jacklog.sh` reads only `0x0b`, with
`i2ctransfer`.

**The fix.** At resume, read both event registers to release INTB, read the
accessory status as it is now, report it, then enable the interrupt. Buttons
pressed during sleep are dropped. At probe, read both event registers before
the accessory status.

**Result, 2026-10-24, trixie card** (`suspend-0039-20261024.log`):

- After a warm reboot following a lost event, INTB comes up `hi`; the boot
  before it came up `lo`.
- Unplugged while asleep: `off` at resume, without an interrupt.
- Plugged in while asleep: `on` at resume, likewise.
- Plug changes while awake are reported before, between and after the two
  suspends: six, each once. Both suspends `RESULT mem: ok`.

**Not yet tested:**
- A wired 4-pole headset: `Headset Mic Jack` and the buttons, including a
  button held across suspend.
- Cold boot with 0039.

### Step 3: PulseAudio switches on plug

With the switch working, PulseAudio's `module-switch-on-port-available` does
the rest once the paths know about the jack. In
`device/pulse/alsa-mixer/paths/`:

- `pyra-headphones.conf`: `[Jack Headset Stereophone]`, `required-any = any`,
  so the port is available only when plugged.
- `pyra-speaker.conf`: `[Jack Headset Stereophone]`, `state.plugged = no`,
  `state.unplugged = unknown`, so the speakers become unavailable when
  headphones go in.

**Test:** plug in during playback; the sound moves to the headphones within a
second and comes back to the speakers on unplug. A manual port choice in MATE's
sound preferences still works.

This covers the AESS path only, which is the one with ports. The direct-link
setup uses two remap sinks instead of ports, so on that path the switch would
need a small udev or `module-switch-on-connect` arrangement. Not planned
unless the direct link is still in use when steps 1 and 2 land.

**Result, 2026-10-24, trixie card: plug-in switches, unplug does not.**
Installed on the card with the old files kept as `*.before-jack`.
Plug-in moves the sink to the headphones within a poll (0.3 s), and the
Connector choice in MATE's sound preferences still works both ways. Unplug
never switches back, because the jack itself never reports the removal
(`amp-blinds-removal-20261024.log`, `ports-20261024.log`):

    07:19:57.439 acc=0x09 ts_irq=11 hs_amp=On  hp=on     plug-in, headphones active
       ... play, unplug while playing, stop, plug and unplug idle: nothing ...
    07:21:38.983 acc=0x00 ts_irq=12 hs_amp=Off hp=off    190 ms after the port
                                                         was set to speakers by hand

**The TS3A227E cannot see a removal while the headset amplifier is
powered.** It detects both insertion and removal on one pin, DET_TRIGGER:
internal pull-up of about 1 MOhm to VDD, high above 0.65 x VDD, a high-to-low
edge starts detection (90 ms debounce), a low-to-high one is a removal (50-65
ms). If the Pyra wires DET_TRIGGER to the jack's tip, or to a switch onto it,
the TWL6040's headset amplifier, which is ground-centred with a low output
impedance, holds that line near 0 V whenever it is on, and a 1 MOhm pull-up
cannot lift it. That fits everything seen: insertions always detected,
removals detected with the amplifier off, never with it on, and caught up
within the removal wait once it powers down. Not confirmed against the board
schematic, which is not in the repository.

With `module-suspend-on-idle timeout=300` the amplifier stays on for five
minutes after the last sound, so in practice an unplug during or shortly
after playback leaves the sink on the unplugged headphones, silent, until
the user picks Speakers or five idle minutes pass. Before step 3 the switch
was manual both ways, so this is no worse for unplugging and better for
plugging in. It is not what the step promised.

Options (2026-10-24: option 1 is what ships, and option 3 is being looked
into):

1. Ship as is, and document the unplug half as manual. **Done:**
   `docs/audio.md`, `docs/known-limitations.md` 2.9.
2. A shorter idle timeout, so the amplifier goes off sooner after playback
  stops. Brings the codec's power-up pop back (`docs/audio.md`), and does
  nothing for an unplug during playback.
3. Find another removal signal on the board. The TWL6040 has its own plug
  comparator, which reads "inserted" on stock and bounced on the old AESS
  kernel; what its input is wired to is unknown. Needs the schematic.
4. Drop the speaker side (`state.plugged = no`), so plugging in switches but
   the speakers stay selectable as "available". Does not fix unplug either.

### Step 4: carry it forward

- Done: 0037-0039 are in `docs/kernel-changes.md`, `kernel-jack` and
  `kernel-m4-kbdled`. Still to do: regenerate `linux-pyra-5.6.19`
  (`pc/pyra-kernel-tree.sh`), probably as a new `pyra/jack` branch on
  `pyra/device`.
- The same three changes apply to letux 7.3 almost unchanged. Add them to the
  porting list in `docs/aess-letux-7.3.md`.
- Draft `reports/letux-pyra-jack-detect.md`, and a separate one for 0039,
  which is a generic TS3A227E driver bug and belongs upstream in ASoC. Not to
  be sent without asking.

## Open

- What leaves P16 as an output: U-Boot (which build), or something else
  before the kernel. Needs the serial console.
- Why the TWL6040 plug interrupt bounced on the AESS kernel and was silent on
  stock. Moot while 0038 is in: it reads 0 on the AESS kernel too.
