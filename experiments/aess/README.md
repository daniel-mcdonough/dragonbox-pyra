# Waking up the AESS, the OMAP5's audio DSP

The SoC has a dedicated audio DSP that would take PulseAudio's resampling off
the A15s. Its front ends accept 44100 and 48000 S16_LE stereo — what
applications actually produce — where the TWL6040 behind it accepts only
88200/96000 S32_LE, which is why every stream on this machine is resampled and
widened in software at a cost of 15–18% of a core. The numbers are
`docs/improvements.md` item 10.

**The hardware works. That was the open question and it is answered.** In
order, each step verified on the running unit:

| question | answer | tool |
| --- | --- | --- |
| Is the AESS real silicon? | yes | `device/pyra-aess-probe.sh` |
| Does the firmware load? | yes | `device/pyra-aess-run.py` |
| Does the DSP execute? | yes, 3999 loops/s against a specified 4 kHz | `device/pyra-aess-run.py` |
| Does the 44.1/48 kHz family switch work? | yes, ratio 0.9193 vs 0.9192 expected | `device/pyra-aess-run.py` |
| Do samples flow? | **no** | `device/pyra-aess-dl-probe.py` |

Everything between here and working audio is software, and it is all present
in the tree — 9210 lines under `sound/soc/ti/aess/` plus 1683 in
`aess_port.c` — switched off rather than missing.

## The patch

    0013-asoc-ti-omap-abe-twl6040-build-the-aess-dai-links.patch

fills in `omap_abe_add_aess_dai_links()`, which was an empty stub: four locals
declared, none used, `return 0`. That emptiness is the root cause of the whole
dead path, and not in the obvious way. An ASoC component's `.probe` runs when
the component is bound **into a card**, not when `snd_soc_register_component()`
is called. With no DAI link naming the AESS component it is never bound, so
`omap_aess_pcm_probe()` never runs, so its `pm_runtime_enable()` is never
called, so `pm_runtime_active()` is false — and every accessor in
`aess/aess_mem.h` is wrapped in that test, so **every driver write is silently
dropped and every read returns 0**. Several symptoms, one cause.

The link definitions were never written from scratch here. They were stranded:
`sound/soc/omap/omap-abe-twl6040.c` still carries `abe_fe_dai[]` and
`abe_be_mcpdm_dai[]`, but that directory is referenced from neither
`sound/soc/Makefile` nor `Kconfig` and is not built, and the definitions use
`.cpu_dai_name`/`.codec_name`/`.platform_name`, which 5.6 replaced with
`snd_soc_dai_link_component` arrays. The patch converts them. The placeholder
`SND_SOC_DAILINK_DEFS(link_fe, …)` blocks already in the built file — carrying
literal `COMP_CODEC("abc", "def")` — are what the conversion was evidently
meant to fill in.

Six front ends and three McPDM back ends. The legacy direct-McPDM link stops
being added unconditionally, because it would fight the AESS back ends over
the same McPDM node; it is added only when the AESS does not come up, so a
machine where the AESS fails behaves exactly as it does today.

**Built, not booted.** `make sound/soc/ti/` under `arm-linux-gnueabihf` exits 0
with no errors, and warnings in the file drop from 34 to 14 because the
placeholder DEFS are gone. It has not been run on hardware.

## What is still needed, in order

1. **A firmware container shim.** `snd_soc_tplg_component_load()` rejects the
   blob with `invalid header size for type 0 at offset 0x0 size 0x1a5e8`.
   0x1a5e8 is 108008 — the whole file. The firmware is **not** a changed or
   broken format, which is the conclusion recorded upstream. It is a container
   of 17 blocks each with a 24-byte header — `magic, abi, type, vendor_type,
   version, size` — that walks to EOF exactly. 5.6's `snd_soc_tplg_hdr` is 36
   bytes with a different field order, so the parser reads `size` from the
   wrong offset. Block type 1000 is the firmware (PMEM 8192, CMEM 7852, DMEM
   16384, SMEM 21600, summing to its own block size) and 1001 the config.
   Parsing it by hand and loading those four images is what makes the DSP run
   at 4 kHz, so the format is proven good.
2. **The PCM ops conversion.** `omap_aess_platform` has `.ops =
   &omap_aess_pcm_ops` commented out, and it cannot simply be restored:
   `snd_soc_component_driver` has no `.ops` member in 5.6, the `snd_pcm_ops`
   having been flattened into per-callback members. Same class of conversion
   as this patch.
3. **The `#if 0` init sequence** in `omap_aess_pcm_probe()`, which needs 1 to
   succeed first.
4. **McPDM multiplexing.** All three back ends here name the single DAI that
   `omap-mcpdm.c` registers. TI's design expected an `mcpdm-abe` DAI beside
   the legacy one, and the stranded original carries a FIXME saying exactly
   that. This is the one piece with no existing implementation to draw on.
5. **The device tree.** `omap5-board-common.dtsi` already has the AESS routes
   — `"Headset Playback", "PDM_DL1"` and `"Handsfree Playback", "PDM_DL2"` —
   and `omap5-letux-cortex15-common.dtsi` overrides `ti,audio-routing` and
   drops them. They have to go back for the AESS path to route.

## Hazards, if you go back to poking the hardware directly

Both were caused here on 2026-09-20 and both are guarded in the device scripts.
All ABE memory access must be **32-bit**; a byte-wise slice copy raises an
asynchronous external abort, and because the aborts are asynchronous they
surface at whatever access happens next and blame innocent reads. And quiesce
the engine before letting ti-sysc gate the module — `EVENT_GENERATOR_START=0`,
`DMAENABLE_CLR`, `MCU_IRQENABLE_CLR`, settle — or `sysc_disable_module()` oopses
and wedges the device in `RPM_SUSPENDING`, which then hangs shutdown until the
power button is held. Do not take bank sizes from the device tree: it maps
PMEM and CMEM as `0x1000` when both are at least 8 KiB, and says `CHECKME`.
