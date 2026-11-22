# Which Pyra do I have: mainboard, CPU board and RAM

> **Type: reference.** How to read the revision off your unit; not a procedure.

A Pyra is two boards: the mainboard (keyboard, controls, ports, battery) and
the CPU board on top of it (OMAP5, RAM, eMMC). Each has its own revision
number, V5.x, and the RAM is 2 GB or 4 GB. Forum posts, bug reports and the
device-tree file names all use these numbers, so it helps to know yours.

Everything below was read on this project's unit (CPU board V5.3, mainboard
V5.3, 4 GB) on 2026-11-22, booted from the trixie card with kernel
`5.6.19-m4-kbdled`, or comes from the source of the card's U-Boot
(`u-boot-pyra` 0.1.5, `board/dragonbox/omap5_pyra/`) and the kernel's device
trees. The log is `verification-log.md`, 2026-11-22.

## From a running card

    tr '\0' '\n' < /proc/device-tree/model
    tr '\0' '\n' < /proc/device-tree/compatible | head -1
    grep MemTotal /proc/meminfo

On this unit:

    Pyra-Handheld-V5.3
    goldelico,lc15-v5.3
    MemTotal:        4034760 kB

| Line | Tells you | Why |
|---|---|---|
| `model`, `Pyra-Handheld-V5.3` | the **mainboard** revision | each `pyra-mainboard-v5.x.dtsi` sets the model; dmesg prints it as `OF: fdt: Machine model:` |
| first `compatible` entry, `goldelico,lc15-v5.3` | the **CPU board** revision ("Letux Cortex 15", lc15) | each `omap5-letux-cortex15-v5.x.dts` sets it |
| `MemTotal` | what U-Boot told the kernel, **not** a measurement | see below |

These are trustworthy because U-Boot picks the device tree from the board's
own revision resistors. At every boot it reads the CPU board's (`gpio2_32`,
`gpio2_34`) and the mainboard's (`gpio6_160`, `gpio6_182`, `gpio6_185`),
builds the file name `omap5-letux-cortex15-v<CPU>+pyra-v<mainboard>.dtb` into
`$fdtfile`, and the card's `extlinux` entries load that name from their
`fdtdir`. So the tree the kernel runs is the one for your boards, and its
strings name them. The model strings are not uniform: older mainboards say
`Pyra-Mainboard V5.0` or `Pyra-Mainboard-V5.1`, later ones
`Pyra-Handheld-V5.x`.

**RAM size: MemTotal can't tell you on this card.** The kernel gets its memory
map from U-Boot, which overwrites the device tree's memory node. The card's
U-Boot is built from `omap5_pyra_4gb_defconfig` (the package's
`debian/rules`), and that build declares two fixed banks, 2032 MiB at
`0x80000000` and 2048 MiB at `0x2_0000_0000`
(`dram.c`, `dram_init_banksize`), whatever is fitted. This unit's
`/proc/device-tree/memory@80000000/reg` reads back exactly those two banks,
and `MemTotal` (about 3.85 GiB, the rest reserved by the kernel and CMA) is
what follows from them. The resistor that says how much RAM is really there
(`gpio2_33`) is read only by U-Boot, which uses it for a printout and nothing
else. **No 2 GB unit has been tried with this card**; whether one boots it at
all is open. For the real size, use U-Boot's serial line below.

The resistor pins can't be read safely from Linux: reading them means
changing their pull-ups, and `gpio2_33` is claimed by another driver in the
running kernel (`/sys/kernel/debug/gpio` lists it as `encoder`).

## From U-Boot's serial lines (also when the card won't boot)

U-Boot prints the revisions before it loads anything from the card's
filesystem, so this works on a unit that stops at a missing device tree or a
kernel panic. Connect to the serial console (the micro-USB beside the USB3
port, 1500000 baud with the card's U-Boot 0.1.5; `troubleshooting.md`, "No
LED at all") and power on. The lines come from `get_cpuboard_revision` and
`set_fdtfile` in `board.c`:

    ram code 0x0
    version code 0xa
    Found Pyra V5.3 with 4GB RAM
    HW Revision: CPU: v5.3 Mainboard: v5.3

That is this unit, captured on 2026-11-22 from a reboot of the trixie card.
A few lines later U-Boot loads
`/dtb/linux-image-5.6.19-m4-kbdled/omap5-letux-cortex15-v5.3+pyra-v5.3.dtb`,
the file those two numbers name.

- `Found Pyra V<x> with <n>GB RAM`: `V<x>` is the **CPU board**, `<n>` the
  RAM from the resistor on `gpio2_33`: floating 2 GB, pulled down 4 GB,
  pulled up 8 GB. Older U-Boot builds print the same line as
  `Found LC15 V5.3 with 4GB RAM`, after the same two codes (ljones,
  https://pyra-handheld.com/boards/posts/1695576/; bennr01,
  https://pyra-handheld.com/boards/posts/1711241/).
- `ram code` and `version code` are the raw resistor reads, two bits per pin
  (00 pulled down, 10 floating, 11 pulled up). `ram code 0x0` is 4 GB;
  `version code 0xa` is both CPU-board pins floating, which is V5.3.
- `HW Revision`: CPU board and mainboard. This is the pair in `$fdtfile`.
- CPU board codes U-Boot knows: V5.1 to V5.5. Mainboards: V5.0 to V5.6 (some
  V5.0 boards read as V4.9, and U-Boot maps those to V5.0). U-Boot never
  names a V5.1.2 mainboard, so the `+pyra-v5.1.2` trees are used only by an
  entry with its own `fdt` line.
- An unknown code prints `v0.0`, and the `.dtb` it asks for doesn't exist.
  The same happens for a pair that has no device tree in the kernel. Kernel
  5.6.19 ships Pyra trees only for some pairs of CPU V4.9 to V5.3 and
  mainboard V5.0 to V5.3; list them with
  `ls /boot/dtb/linux-image-*/omap5-letux-cortex15-*+pyra-*`. U-Boot then
  prints `Skipping l5 for failure retrieving fdt` and tries the next entry
  (`cmd/pxe.c`, read from source; not seen on hardware).
- Nothing at all on serial, or eight `READBACK` lines and `Memory test
  failed`: the RAM check failed before U-Boot proper ran
  (`troubleshooting.md`, "No LED at all").

## What the revisions mean

Only one forum post says which revisions went out: "all the production
models out there should be v5.3/v5.3" (aTc, 2022, whose own unit had a V5.2
mainboard, https://pyra-handheld.com/boards/posts/1706189/). The post hedges it,
and nobody has published a list. The same thread shows the `model` check
(pimaster, https://pyra-handheld.com/boards/posts/1706207/).

- **2 GB.** Only 22 were ordered, and the team offered to upgrade them to
  4 GB for free (EvilDragon, 2020,
  https://pyra-handheld.com/boards/posts/1677341/). Some early units were
  built with 2 GB of Micron RAM (hns, 2022,
  https://pyra-handheld.com/boards/posts/1711954/). So a 2 GB Pyra exists
  but is rare, and it is the case this card has not been tried on (above).
- **No sticker or print to go by.** A forum user found "PYRA - V1.0" on the
  label under the battery (https://pyra-handheld.com/boards/posts/1726905/);
  nobody has said what it refers to, and it doesn't match either board
  number.
- **Fixes tied to a CPU board revision.** The white-noise burst on audio
  start was to be fixed "for a later revision of CPU boards" (EvilDragon,
  2021, https://pyra-handheld.com/boards/posts/1688403/). No post
  says which revision has the fix or that one shipped.
