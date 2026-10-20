# Waking up the AESS, the OMAP5's audio DSP

The SoC has a dedicated audio DSP that would take PulseAudio's resampling off
the A15s. Its front ends accept 44100 and 48000 S16_LE stereo — what
applications actually produce — where the TWL6040 behind it accepts only
88200/96000 S32_LE, which is why every stream on this machine is resampled and
widened in software at a cost of 15–18% of a core. The numbers are
`docs/improvements.md` item 10.

**Status, 2026-09-24: it plays, and it is the audio path of the `-m4`
kernel.** 0013-0032 below are what it took; `docs/audio.md` is how it is used
and diagnosed. The rest of this section is where the work started, on
2026-09-20.

**The hardware works. That was the open question and it is answered.** In
order, each step verified on the running unit:

| question | answer | tool |
| --- | --- | --- |
| Is the AESS real silicon? | yes | `device/pyra-aess-probe.sh` |
| Does the firmware load? | yes | `device/pyra-aess-run.py` |
| Does the DSP execute? | yes, 3999 loops/s against a specified 4 kHz | `device/pyra-aess-run.py` |
| Does the 44.1/48 kHz family switch work? | yes, ratio 0.9193 vs 0.9192 expected | `device/pyra-aess-run.py` |
| Do samples flow? | **no** on 2026-09-20; yes from 0023, audible from 0025 | `device/pyra-aess-dl-probe.py` |

Everything between here and working audio is software, and it is all present
in the tree — 9210 lines under `sound/soc/ti/aess/` plus 1683 in
`aess_port.c` — switched off rather than missing.

## The patches

Applied in name order by `pc/pyra-crossbuild.sh kernel-m4`, on top of
`patches/` and the M4 series. "Entry" is the dated entry in the development log
(private notes, not published), "§" its numbered section.

| patch | what it does | history |
| --- | --- | --- |
| 0013 | build the AESS DAI links (an empty stub before) | below |
| 0014 | load the firmware's own container format | below |
| 0015 | add the AESS mixer controls | below |
| 0016 | McPDM: one DAI per path | below |
| 0017 | run the AESS init sequence (an `#if 0` block) | 19th entry |
| 0018 | the memory banks are 8 KiB, not 4 | 19th entry |
| 0019 | add the DAPM graph | 20th entry |
| 0020 | dts: restore the AESS audio routes the LC15 dtsi dropped | 20th entry |
| 0021 | convert the PCM ops to 5.6 component callbacks | 21st entry |
| 0022 | open the McPDM back-end ports | 21st entry, §22 |
| 0023 | enable the McPDM back-end ports | §22, §23 |
| 0024 | keep the direct McPDM link as `hw:L15,9`, a reference | §23, §24, §34 |
| 0025 | start McPDM after the AESS port, not before -- **first sound** | §24, §25 |
| 0026 | size the ping-pong buffer from the firmware | §27 |
| 0027 | McPDM: stop the ABE back ends from the trigger | §27 |
| 0028 | do not write uninitialised equaliser coefficients | §27, §29 |
| 0029 | do not advertise 44.1 kHz; the engine has one timebase | §29 |
| 0030 | McPDM: pop every downlink slot, plus the command word -- the tinny sound | §32 |
| 0031 | never report the pointer going backwards (phantom buffer laps) | §35 |
| 0032 | do not map DMEM into userspace; write it with 32-bit stores -- the crackle on music | §35 |
| 0036 | keep OPP100 when no widget reports a level -- **the speakers** | 2026-10-20, in the patch |

Tools that ship beside them:

`container-check.c` is the 0014 walker lifted out so it can be compiled and
run against a real firmware file with no kernel involved:

    cc -O1 -Wall container-check.c -o container-check
    ./container-check /lib/firmware/omap_aess-adfw.bin

`dmem-store-width.c` writes the MM1 LP ring through the PCM mmap with 32-, 16-
and 8-bit stores and reads it back, which is how 0032's premise was measured.
On a kernel with 0032 it fails at `mmap_begin`, which is the point.

The sections below describe 0013-0016 as they were written, before anything
had booted.

### 0013

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

### 0014

Makes the firmware load. `snd_soc_tplg_component_load()` rejected the blob
with `invalid header size for type 0 at offset 0x0 size 0x1a5e8`, and the
failure was swallowed by an `#if 0` whose comment concluded the format had
changed. 0x1a5e8 is 108008 — the whole file — which is the giveaway: the
loader is reading `size` from the wrong offset. `snd_soc_tplg_hdr` is 36 bytes
(`magic, abi, version, type, size, vendor_type, payload_size, index, count`);
every block here carries 24 (`magic, abi, type, vendor_type, version, size`).

The patch keeps trying the topology container first and falls back to walking
the legacy one, so a future firmware that really is a topology file still
takes the normal path. Detection is "walks to EOF exactly", because a
mis-parse desynchronises within a block or two. `aess_load_fw_data()` also
gains a check the topology path never had: the four image sizes plus the
header must equal the block exactly.

The standard block types the container also carries — mixers, enums, bytes,
DAPM widgets — are deliberately not handled; the old container does not carry
the element count the topology loader wants. So this makes the DSP loadable
and runnable but does not create the topology's kcontrols.

### 0015

Adds the mixer controls, without which the DSP runs and nothing is audible:
the firmware image ships all 36 gains at `GAIN_MUTE`, `omap_aess_init_gains()`
leaves every mixer input muted deliberately, and 0014 does not parse the
container's control blocks so the topology creates none.

The values are recovered, not invented. The container's MIXER block holds 26
elements decoding to a name plus two id pairs — `(reg, reg)` and
`(shift, rshift)`. Mixer volumes carry the gain id in `reg`; the microphone
and Bluetooth volumes are stereo and carry left/right ids in `shift/rshift`.
Every id matches the `OMAP_AESS_*` constants in `aess-fw.h`: DL1 Media is 14
which is `OMAP_AESS_MIXDL1_MM_DL`, Tones 17, Voice 16, Capture 15, and so on
through all 26. That agreement across 26 independent elements is what makes
the decode trustworthy. `max` is 149 and the TLV floor is −12000, matching the
driver's own db2lin table of 151 entries from −120 dB.

The existing `aess_vol_get_mixer()` and friends could not be reused: they call
`snd_soc_dapm_kcontrol_dapm()`, so they only work on DAPM widget controls, and
this driver defines no DAPM widgets at all — in this design the whole graph
was meant to come from the topology. Component equivalents sit beside them.

The three `* Mono Mixer` switches are omitted (also DAPM bound, and not needed
for playback). The DL1/DL2 output gains are added although they are not in the
MIXER block, because `omap_aess_init_gains()` sets them once and nothing could
otherwise change them.

### 0016

Splits McPDM into one DAI per path. It carries the headset pair, the handsfree
pair and the uplink on a single PDM link and registered one DAI for all of it,
deriving the link mask from the channel count counting up from the first slot
— so it could express DL1, and DL1+DL2, but never DL2 alone. The AESS needs
DL1 and DL2 as independently fed back ends, so each must own its own slots
while the others may or may not be running.

Four DAIs now: `mcpdm-legacy` unchanged, plus `mcpdm-abe-dl1`, `-dl2`, `-ul1`
with fixed masks. The driver keeps what each DAI claims in
`dai_link_mask[dai][direction]` and programs the OR, so starting or stopping
one only adds or removes its own slots. Three things that are easy to miss are
handled: startup/shutdown are refcounted across DAIs rather than on
`dai->active`; the ABE DAIs do no CPU-side DMA, because the ABE feeds the link
through its own port; and the per-DAI `.probe` now runs four times, so the
one-time `pm_runtime_enable()`/`request_irq()` is guarded.

**This is the patch to distrust.** 0013 and 0015 converted or recovered code
that already existed and 0014 decoded a format checkable against a real file.
This one is new code written against the register model and the slot layout,
with no reference implementation and no way to observe a PDM link from a
compiler.

## What was still needed on 2026-09-20

All done; kept because it says why each later patch exists. Item 1 is 0021,
item 3 is 0017, item 4 is 0016 with 0022 and 0023, and item 5 is 0020. What
remained after them -- the start order, the slot mask, the pointer and the
store width -- nobody predicted; that is 0025 onward.

1. **The PCM ops conversion.** `omap_aess_platform` has `.ops =
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
All ABE memory access must be **32-bit**. The PCM driver itself broke this
rule until 0032: it mapped the MM1 LP ring in DMEM into userspace, where 16-
and 8-bit stores are dropped rather than faulting, and music crackled for it
(§35). From userspace, a byte-wise slice copy raises an
asynchronous external abort, and because the aborts are asynchronous they
surface at whatever access happens next and blame innocent reads. And quiesce
the engine before letting ti-sysc gate the module — `EVENT_GENERATOR_START=0`,
`DMAENABLE_CLR`, `MCU_IRQENABLE_CLR`, settle — or `sysc_disable_module()` oopses
and wedges the device in `RPM_SUSPENDING`, which then hangs shutdown until the
power button is held. Do not take bank sizes from the device tree: it maps
PMEM and CMEM as `0x1000` when both are at least 8 KiB, and says `CHECKME`.
