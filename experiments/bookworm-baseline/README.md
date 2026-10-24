# Stock bookworm-7 as a baseline

What the stock image does on this hardware, captured so the trixie work has
something to compare against that is not taken from memory or from the
development log.

**The card.** `pyra-bookworm-7` (2025-06-10) from
`packages.pyra-handheld.com/images/bookworm/`, written to a second SD card and
booted on the V5.3 unit (`Pyra-Handheld-V5.3`, `goldelico,lc15-v5.3`) on
2026-10-23. The eMMC was not touched. The kernel is
`5.6.19-pyradef #10`, the same build the trixie card uses, so the differences
below come from userland, not the kernel.

**Changed on the card before capture:** `mesa-utils`, `evtest` and `i2c-tools`
were installed (they appear in `packages.txt`). Nothing else was configured.
The X log is from the first session, before any of those were installed.

## Files

| file | what it is |
| --- | --- |
| `Xorg.0.log` | The full server log from a normal boot to the lightdm/MATE desktop |
| `glxinfo-B.txt` | `glxinfo -B` on that desktop |
| `dmesg.txt` | The full kernel log of the same boot |
| `asoc.txt` | `/sys/kernel/debug/asoc/components` and `/proc/asound/pcm` |
| `packages.txt` | Every installed package and version |

## What it shows

**GLX is software, through llvmpipe.** The server tries the DDX's DRI2
driver, does not find it, and falls back to software GLX:

    (EE) AIGLX error: dlopen of /usr/lib/arm-linux-gnueabihf/dri/armsoc_dri.so failed
    (EE) AIGLX error: unable to load driver armsoc
    (II) IGLX: Loaded and initialized swrast
    (II) GLX: Initialized DRISWRAST GL provider for screen 0

The client side asks Mesa for `omapdrm_dri.so`, which bookworm does not ship
either, and settles on `llvmpipe (LLVM 15.0.6, 128 bits)`, Mesa 22.3.6,
`Accelerated: no`, GL 4.5 core. On trixie the same missing-driver path
crashes the server, which is why fix 4 turns GLX off
(`reports/xorg-aiglx-dri2-null-deref.md`). This log is the bookworm evidence
that report and `reports/mesa-dril-omapdrm-no-fallback.md` said they lacked.

**Audio does not use the AESS.** The kernel has `CONFIG_SND_SOC_OMAP_AESS=y`
and `401f1000.aess` registers as an ASoC component, but the card exposes one
PCM, `04-00: TWL6040 twl6040-legacy-0`, the direct McPDM link. No AESS
firmware is requested during boot. The front-end DAIs (`MultiMedia1`,
`Voice`, `Tones`, ...) are registered and nothing is bound to them. Stock
audio is the direct path described in `docs/audio.md`; the AESS path is only
on our kernels.

**The headphone jack reads "inserted" with nothing plugged in**, the same
fault the trixie card has. It is stock, and it predates every AESS patch. The
cause is traced in `experiments/jack-detect/`.

**The thermal daemon has its tool.** Bookworm ships `cpufrequtils`, so
`/usr/bin/cpufreq-set` exists and `pyra-thermal.service` (pyra-hacks 0.37)
can apply the caps it decides. Trixie cannot install it, which is fix 6. No
load test was run here, so there is no stock peak temperature to set against
the 107°C / 84°C figures yet.

**Packages are almost all the same as trixie's.** The DDK (`1.14.3699939-15`),
the armsoc DDX (`0.6`), gl4es (`1.1.7.1`), `pyra-config` (`0.39`),
`funkeymonkey-pyrainput` (`0.1.19`) and `led-config-pyra` (`0.12`) match the
trixie suite. `dri3wsegl-pyra` is 0.5 (trixie 0.4, same code). `pyra-hacks` is
0.37 (trixie 0.38). The large differences are Debian's: xserver 21.1.7,
Mesa 22.3.6. Every Pyra package here is already in `pyra-packages-archive`.

**Boot noise, for diffing against our kernels.** `dmesg.txt` already has,
on stock: the i2c sensor probes failing with `-121` (bmc150, bmp280, bno055),
the `txs02612` stub-node warnings that `patches/0003` deals with,
`usb3503 SP_ILOCK failed (-121)`, both `ti_abb` regions failing with `-16`, and
the TS3A227E IRQ failure.

## Not captured

- The eMMC (`mmcblk0`). It was idle while this card ran, so it can be imaged
  from here; `docs/reproduce.md` still lists it as not captured.
- A thermal load run, suspend/resume, and the display-wedge DPMS loop on
  stock.
