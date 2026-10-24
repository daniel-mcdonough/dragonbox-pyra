# AESS: our 5.6 patches against letux 7.3

Written 2026-10-20 from reading the code. **Nothing here has been built or booted
on 7.3.** Everything marked "on hardware" comes from the 5.6.19-m4 kernel; on 7.3
it is a code-reading finding until it is run.

This answers three questions: is upstream's AESS work in letux 7.3 "finished",
is it better than ours, and what it would take to move the Pyra to it. For what
the AESS is and how the 5.6 path is used day to day, read `audio.md` first. For
patch-by-patch history, read `experiments/aess/README.md`. The upstream report
drafts are in `reports/letux-aess-*.md`, starting with `reports/letux-aess-INDEX.md`.

## Short answer

- **The work is in the newest letux branch, not in `master`.** `master` is the
  6.18.y LTS line and carries an older AESS series. The current one is in
  `letux-7.3` (= `letux-current`) and in `omap-aess-7.3`.
- **"Finished" is not supported by the code.** The October 2026 commits are
  still bring-up work: debugfs, `pm_runtime` balance, range comments, an
  OMAP4 clock. The modem link, McASP/SPDIF and suspend paths are still under
  `#ifdef FIXME`.
- **Their work is not better than ours on anything that affects playback on
  the Pyra.** None of the six faults we found, and that 7.2 still had, is
  fixed in 7.3. What 7.3 has over our tree is the same thing 7.2 had: a
  current kernel and a cleaner design. In that design McPDM owns the ABE
  ports, and the firmware comes through the standard topology loader.
- **The way forward is to port our six fixes onto 7.3**, not to choose one
  tree over the other.

## Where everything is

| what | where |
| --- | --- |
| letux kernel clone | `../dragonbox-pyra-supporing-repos/letux-kernel` (origin = goldelico/letux-kernel) |
| latest letux kernel | `origin/letux-7.3`, identical to `origin/letux-current` (2026-10-19) |
| AESS-only merge branch | `origin/omap-aess-7.3` = `letux/aess-v19` + `aess-asoc-fw-v6` + `aess-audio-test-v3` + `aess-abefw-v5` |
| previous one, what our reports checked | `origin/omap-aess-7.2` (`aess-v17`, `asoc-fw-v5`, `abefw-v4`) |
| `master` | `letux-6.18.y`, 6.18.56. Its merge commit names `aess-v17`, but that is an older, pre-rebase version of that branch. Not the code to test. |
| `omap-aess` clone | `../dragonbox-pyra-supporing-repos/omap-aess`. **Only fetched up to 7.2.** Use the letux-kernel clone for 7.3, or fetch first. |
| our patches | `experiments/aess/0013`-`0032`, applied by `pc/pyra-crossbuild.sh kernel-m4` on 5.6.19 |
| driver | `sound/soc/ti/aess/`, `sound/soc/ti/omap-mcpdm.c`, `sound/soc/ti/omap-abe-twl6040.c` |
| device tree | `arch/arm/boot/dts/ti/omap/omap5-l4-abe.dtsi` (AESS node), `omap5-board-common.dtsi` (sound card, `&aess { status = "okay"; }`) |
| config | `arch/arm/configs/pyra_defconfig` on 7.3: `SND_SOC_OMAP_AESS=m`, `SND_SOC_OMAP_ABE_TWL6040=m` |
| firmware build | `Letux/root/build-aess-fw`. Runs on the device, clones the letux branch that matches `uname -r`, builds a topology-format `omap_aess-adfw.bin` |

The letux-kernel clone's local `master` was reset to `origin/master` on
2026-10-20. Its only local commit was upstream's own, and upstream later
replaced it. The old tip is kept as branch `backup/pre-reset-2026-10-20`.

To recheck any of this:

    cd ../dragonbox-pyra-supporing-repos/letux-kernel && git fetch origin
    git diff --stat origin/omap-aess-7.2 origin/omap-aess-7.3 -- sound/soc/ti

The log between those two branches is mostly 2012-2023 commits replayed by
rebases. Read the diff, not the log.

## What actually changed from 7.2 to 7.3

| change | where | matters for the Pyra? |
| --- | --- | --- |
| debugfs memory dumps read with 32-bit `readl()` and are bounded by the DT region size (new `aess->io_size[]`), not by the firmware header | `omap-aess-dbg.c`, `omap-aess-core.c`, `omap-aess-priv.h` | Debugging only. It agrees with our finding that DMEM accepts only 32-bit access (0032), but 7.3 applies that rule to debugfs reads only, not to the playback path. |
| second `pm_runtime_enable()` in `omap_aess_pcm_probe()` compiled out (`KEEPME_DESPITE_PROBLEM`) | `omap-aess-pcm.c:602-647` | **Correct.** `omap_aess_engine_probe()` already enables runtime PM (`omap-aess-core.c:173`), so the second call was the unbalanced one. Their comment ties its removal to "`CPU DAI mcpdm-abe not registered`"; see *Probe order* below. |
| `platform_set_drvdata()` moved to just before component registration | `omap-aess-core.c`, `omap-mcpdm.c` | Harmless, and it is the usual pattern. It means `dev_get_drvdata()` on the AESS device returns NULL for longer during probe; see *Probe order*. |
| `dpll_abe_m2x2_ck` rate set at clock init | `drivers/clk/ti/clk-44xx.c` | **No.** OMAP4 only; `clk-54xx.c` is unchanged. |
| asoc-fw generator: a TLV `memcpy` that copied `length * sizeof(int)` (4x too much) now copies `length`; local copy of `struct soc_enum` / `soc_mixer_control` synced to v7.3 (`max` → `items`, `num_channels`) | `firmware/asoc-fw/src/lib.c`, `socfw.h` | Yes, if the firmware is built with `build-aess-fw`. Topology files built with the 7.2 generator can have wrong enum item counts. Rebuild the firmware rather than reuse an old one. |
| abefw / audio-test build cleanup, `#if FIXME` → `#ifdef FIXME`, `fallthrough;`, `__maybe_unused`, CHECKME/FIXME comments on the DT ranges | various | No functional change. The new DT comments raise the `0xfff`/`0xffff` sizes and the `0x490ce000` SMEM address that `reports/letux-aess-firmware-container.md` already notes. |

## Our open findings, checked on 7.3

All six "class c" items from `reports/letux-aess-INDEX.md` are unchanged. Line
numbers are on `origin/omap-aess-7.3`.

| patch | fault | 7.3 | report |
| --- | --- | --- | --- |
| 0032 | DMEM mapped into userspace; 8/16-bit stores silently dropped | `SNDRV_PCM_INFO_MMAP` at `omap-aess-pcm.c:71`, `io_remap_pfn_range()` at `:441` | `letux-aess-dmem-mmap.md` |
| 0026 | four periods from `D_PING` overrun the 24576-byte region | `period_bytes_max = 24 * 1024` at `omap-aess-pcm.c:80` | `letux-aess-pingpong-window.md` |
| 0029 | 44.1 kHz advertised, `EVENT_44100` never requested | `omap-aess-dai.c:1052, 1108, 1142`, file unchanged | `letux-aess-44k1.md` |
| 0031 | pointer steps back one period before the ping-pong IRQ | `omap_aess_pcm_pointer()` unchanged; `aess_port.c` gained only `fallthrough;` | `letux-aess-pointer-backwards.md` |
| 0014 | linux-firmware `omap_aess-adfw.bin` rejected by the topology loader | `snd_soc_tplg_component_load()` only, `omap-aess-pcm.c:488` | `letux-aess-firmware-container.md` |
| 0028 | equaliser coefficients written from an uninitialised stack local | `omap-aess-fw.c` unchanged | `letux-aess-equaliser-coefficients.md` |

**0036, found 2026-10-20 after this comparison, is a seventh, but only
partly.** 7.3's `aess_opp_recalc_level()` (`aess_opp.c:240`) is identical:
with no `opp.widget[]` bit set it computes `(1 << (fls(0) - 1)) * 25`, a
shift by -1, and drops the firmware to OPP50, where the speakers are silent.
What differs is who fills `opp.widget[]`. On 5.6 nothing does, because our
DAPM graph (0019) is hand-written. On 7.3 the topology loader sets it from
the firmware's widgets (`omap-aess-fw.c:135, 268`), so whether the fault
shows depends on what the topology declares. The shift is undefined behaviour
either way, and the one-line guard ports unchanged. Check on hardware: during
playback `/sys/kernel/debug/omap-aess/opp_level` should read 100.

The smaller leftovers also stand: `aess_gain_to_val()` uses `val`, not its
parameter (`omap-aess-fw.c:53`); `omap_aess_load_fw_param()` copies images
without checking them against the bank size (`aess_ini.c`); and
`omap_aess_write()`/`omap_aess_clear()` still use plain `memcpy`/`memset`
on DMEM (`aess_utils.c`). Only the last one is new, and it is the same rule
as 0032.

**On 7.3, 0014 decides whether there is a sound card at all.** With
`SND_SOC_OMAP_AESS=m`, `omap_aess_pcm_probe()` treats a missing firmware
file as fine (`-ENOENT` → return 0). A file that exists but fails to load is
an error (`"firmware exists but was not loaded"`), and the component probe
fails with it. If `/lib/firmware/omap_aess-adfw.bin` is the linux-firmware
copy, the version our 5.6 image uses, stock 7.3 should lose the AESS
component, and with it the card, until 0014 is ported or the file is
replaced with one built by `build-aess-fw`. This follows from the code and
has not been seen on hardware.

## Porting our fixes to 7.3

Base the work on `origin/omap-aess-7.3`, because that is the tree a submission
to goldelico/omap-aess would be checked against. Test it on `origin/letux-7.3`,
which has the rest of the Pyra support. The two have the same AESS files, so a
series made on one applies to the other.

The 5.6 patches **will not `git am` onto 7.3**. They were written against a
5.6 tree where McPDM knew nothing about the ABE, and many of their hunks lean
on 0013-0025, which 7.3 does not need. Rewrite each fix against 7.3's code,
reusing the commit message and the evidence. Suggested order, cheapest and
most self-contained first:

1. **0029, drop 44.1 kHz.** Three `.rates` lines in `omap-aess-dai.c`. No
   dependencies.
2. **0028, skip the equaliser write when no coefficients are loaded.** One
   guard in `aess_mixer_set_equ_profile()`. Latent on 7.3, because the
   topology supplies coefficients, but cheap. Fix `aess_gain_to_val()` in the
   same file while you are there.
3. **0031, pointer never goes backwards.** `omap_aess_pcm_pointer()` is the
   same function; this should port almost unchanged. It needs a per-substream
   "last position" field reset at `prepare`/`hw_params`.
4. **0026, cap the period at a quarter of `D_PING`.** Same function in 7.3.
   Read the region size from the firmware map at `open()`, as 0026 does, not
   as a new constant.
5. **0032, no mmap; 32-bit copy.** Drop `SNDRV_PCM_INFO_MMAP`/`MMAP_VALID`
   and the `.mmap` op. Add a `.copy` component callback that uses
   `__iowrite32_copy()` for MM1 LP (DMEM-backed) and a plain copy for the
   other front ends. 7.3 uses the 6.x+ `copy(..., struct iov_iter *, ...)`
   signature, not 5.6's `copy_user`, so this is the patch that needs the most
   rewriting. Check `omap_aess_write()`/`omap_aess_clear()` for sub-word
   access in the same pass.
6. **0014, legacy container loader, as a fallback.** Keep
   `snd_soc_tplg_component_load()` as the primary path. When it fails,
   recognise the 24-byte block header and load the firmware and config
   blocks directly, as 0014 does. Without this, a Pyra with the linux-firmware
   file has no card at all on 7.3 (see above). Upstream may reasonably prefer
   "use `build-aess-fw`". Ask them before writing the full fallback; the
   container report makes the case.

7. **0036, keep OPP100 when no widget reports a level.** The same
   `if (opp) ... else opp = 100;` guard in `aess_opp_recalc_level()`. Port it
   regardless, for the shift by -1, but first read `opp_level` during
   playback on 7.3: if it already reads 100 there, the topology fills in
   `opp.widget[]` and the speakers will not show the fault.

Not AESS, but due on the same tree: the headphone jack. `letux-7.3` (and master) still
takes it from `twl6040_hs_jack_detect()`, so the Pyra's TS3A227E is never
used, and its interrupt pin needs the same DT hog. Both changes are planned
as 0037 and 0038 in `experiments/jack-detect/` and should port almost
unchanged.

Not to port, because 7.3 already covers them: 0013, 0015-0025, 0027 and 0030
(classes a and b in the INDEX). The PulseAudio side (`device/pulse/pyra-aess.pa`
with `timeout=300`, `mmap=no`, and the profile set in `device/pulse/alsa-mixer/`) still applies on 7.3. `mmap=no` becomes
unnecessary once 0032 is in, but it does no harm.

The bounds check in `omap_aess_load_fw_param()` and the DT size/address
comments are hardening, not fixes. Fold them into the 0014 work or the
container report, not a separate patch.

## Testing the probe order on 7.3

The question: does the sound card reliably come up, with the AESS links, on
every boot and every module reload? 7.3's own comment says that without the
second `pm_runtime_enable()` they "often see `ASoC: CPU DAI mcpdm-abe not
registered`".

Why that message probably is not the `pm_runtime` change:

- `mcpdm-abe` is a DAI of the **McPDM** driver (`omap-mcpdm.c:690`). It
  exists once `asoc_mcpdm_probe()` has registered its component. Nothing in
  the AESS `pm_runtime` code affects that.
- The machine driver (`omap-abe-twl6040.c:1008-1016`) adds the AESS DAI links
  as soon as the AESS device has a driver attached (`aess_dev->driver`). The
  driver core sets that **before** the AESS probe finishes, and it does not
  wait for McPDM. If the card registers before McPDM has, ASoC prints exactly
  this line and returns `-EPROBE_DEFER`. That is normal, provided the card
  binds on a later retry.
- McPDM's component probe (`omap-mcpdm.c:525-546`) finds the AESS by the
  hard-coded name `401f1000.aess` and takes `dev_get_drvdata()`. If that is
  still NULL, it **silently skips opening the PDM_DL1/UL1 AESS ports** and
  carries on. The card would then bind with McPDM not connected to the ABE:
  audio routed to the AESS goes nowhere, and the log shows no error. 7.3's
  later `platform_set_drvdata()` makes that window wider. This is the failure
  worth looking for, and it is quieter than the one their comment describes.
- Two smaller issues seen on the way: `bus_find_device()` in both drivers
  takes a device reference that the success path never drops, and the
  machine driver's own FIXME notes that deferring on the AESS prevents any
  fall-back to the legacy links if the AESS never binds.

What to run, once a 7.3 kernel is installed. Check `docs/building.md` for
installing beside the 5.6 kernels. **Ask before SSHing in**: the unit may be
in use for profiling. Put a firmware built by `build-aess-fw` in
`/lib/firmware`, or port 0014 first; with the linux-firmware file the card
is expected not to appear at all (see above).

1. **Cold boot, 10 times.** Each time, record:

       dmesg | grep -E 'aess|mcpdm|abe-twl6040|pm_runtime|not registered|deferred'
       cat /proc/asound/cards
       grep -q 'MultiMedia1 LP' /proc/asound/pcm && echo AESS || echo direct
       cat /sys/kernel/debug/devices_deferred 2>/dev/null

   Pass: the card is present and `MultiMedia1 LP` exists on every boot. A
   "`not registered`" line followed by a bound card counts as a pass.
   `devices_deferred` must be empty once boot has finished.

2. **Module reload, 20 rounds.** This tests the other order, where AESS
   arrives after McPDM:

       for i in $(seq 20); do
         modprobe -r snd-soc-omap-abe-twl6040 snd-soc-omap-aess snd-soc-omap-mcpdm
         modprobe snd-soc-omap-mcpdm; modprobe snd-soc-omap-aess; modprobe snd-soc-omap-abe-twl6040
         sleep 2; grep -c 'MultiMedia1 LP' /proc/asound/pcm
       done

   Then repeat with the load order reversed: `snd-soc-omap-aess` first, then
   `snd-soc-omap-mcpdm`. Stop PulseAudio first, or it holds the card open.
   Watch for "Unbalanced pm_runtime_enable", which should be gone on 7.3,
   and for `-EBUSY` on reload, which could come from the leaked
   `bus_find_device()` references.

3. **Check the AESS is actually in the path.** A bound card is not enough.
   For each passing boot in step 1, play a 48 kHz file to the AESS front
   end, `hw:L15,5` or whatever `aplay -l` lists as MultiMedia1 LP, and
   confirm sound comes out. Then check the AESS ports were opened:
   `cat /sys/kernel/debug/aess/*`, plus the audio-test `abe_check` tool if
   built. A card that binds but stays silent is the skipped-`port_open` case
   above.

4. **Runtime PM.** After playback stops, the AESS should go idle:

       cat /sys/bus/platform/devices/401f1000.aess/power/runtime_status   # expect: suspended
       cat /sys/bus/platform/devices/401f1000.aess/power/runtime_enabled  # expect: enabled

5. **Then the six faults.** Each report in `reports/letux-aess-*.md` has a
   "how to reproduce" section. Running them on 7.3 turns them from
   code-reading findings into confirmed ones, which is what the INDEX needs
   before it is sent.

## Still open

- None of this has been built. The first step is a `letux-7.3` +
  `pyra_defconfig` cross-build. `pc/pyra-crossbuild.sh` only knows the 5.6
  targets.
- Whether 7.3's `build-aess-fw` firmware plays correctly on the Pyra, and
  whether our 5.6 measurements (ping-pong overrun, pointer race) reproduce
  with it.
- The reports still say "checked against omap-aess-7.2". Their findings all
  hold on 7.3; the header lines need updating before anything is sent.
