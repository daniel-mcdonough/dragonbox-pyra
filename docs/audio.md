# Audio on the Pyra: the chain, the limits, and how to diagnose silence

Verified 2026-09-20 on the running unit, kernel `5.6.19-freq`, Debian 13
(trixie). Sound works on this machine as of fixes 9 and 10.

This is the map. The repair instructions for the two faults that make the
machine silent are fix 9 and fix 10 in `fixes.md`; the performance survey and
its numbers are item 10 in `improvements.md`. This document is what you want
open when someone says "there is no sound" and you do not yet know which of
those you are looking at — or when you are about to write something that
touches audio and need to know what the hardware will and will not do.

## The chain, end to end

    app  ->  PulseAudio  ->  remap sink  ->  ALSA sink  ->  McPDM  ->  TWL6040  ->  amp
                             speakers/        4ch                      routing
                             headphones       88200 Hz                 enums

**The codec is a TWL6040**, on i2c, reached over OMAP5's McPDM link. ALSA
enumerates it as `Letux Cortex 15`, addressed by name as `hw:CARD=L15`. It is
one PCM device carrying **four channels**, and the pairs are not
interchangeable:

| channels | codec path | output |
| --- | --- | --- |
| front-left, front-right | HS DAC, `Headset *` controls | headphones |
| rear-left, rear-right | HF DAC, `Handsfree *` controls | speakers |

**PulseAudio is configured unusually, and deliberately.**
`/etc/pulse/daemon.conf.d/pyra.conf` points it at `/etc/pulse/pyra.pa`
instead of the stock `default.pa`, and sets `resample-method = trivial`.
`pyra.pa` skips `module-udev-detect` entirely and opens the card with a raw
`module-alsa-sink` at 4 channels, then stacks two `module-remap-sink`
instances on it to publish `speakers` (rear pair) and `headphones` (front
pair) as separate sinks. `speakers` is the default.

That design decision is the root of several things that look like bugs and
are not — see *Consequences of the 4-channel design* below.

**`pyra_volumed`** (from `pyra-hacks`, enabled by default) reads the encoder
wheel on `palmas-gpadc` and writes **`Handsfree Playback Volume` only**, via
`snd_mixer_selem_set_playback_volume_all` on `hw:CARD=L15`. It sets a volume
and never sets a route. The wheel therefore controls the **speakers and
nothing else** — it does not reach the headphones, which have only
PulseAudio's software volume and the `Headset Playback Volume` control.

## What the hardware will not do

From `aplay -D hw:CARD=L15,DEV=0 --dump-hw-params /dev/zero`, with the device
free (stop PulseAudio first or it will report the device busy):

    ACCESS:   MMAP_INTERLEAVED RW_INTERLEAVED
    FORMAT:   S32_LE
    CHANNELS: [1 5]
    RATE:     [88200 96000]

Three constraints follow and none of them are configurable away:

* **There is no 44100 and no 48000.** The link is PDM, which is inherently a
  fixed high-rate interface. Every ordinary stream is resampled before it can
  be played. This is the single largest cost in audio playback on this machine
  and it cannot be removed, only avoided per-app by an app that will render at
  the link rate.
* **There is no `S16_LE`.** Everything is widened to 32 bits.
* **The two rates are modes, not a range.** `PLL Selection` and `TWL6040 Power
  Mode` select Low-Power (88200) or High-Performance (96000). This machine
  ships in Low-Power.

## What playback costs

Full numbers, method and the negative results are in `improvements.md` item
10. The short version, because it is the thing most often misread:

| condition | pulseaudio |
| --- | --- |
| nothing playing | ~0% — `module-suspend-on-idle` suspends the sink |
| one stereo stream, 44100 or 48000 | ~10% of a core at 1.5 GHz |
| one stereo stream already at 88200 | ~2% of a core |
| the same 44100 stream under `ondemand` | **26%**, because the clock sags to 625 MHz |

**A report of "pulseaudio is using 20-30%" is the governor, not a leak.** The
work is identical; `ondemand` reads a small steady load as idle and settles at
625-750 MHz, so the percentage roughly doubles. Check
`/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq` before believing any
audio CPU figure.

**A real game, measured under load rather than at idle.** Ship of Harkinian
asks for `s16le 2ch 32000Hz` and pulse resamples it `trivial` to 88200. With
the game running and the thermal profile holding the clock at 1.0 GHz,
`pulseaudio` takes **15.3% of a core** (536 jiffies in a 35 s window). Taken
system-wide with `perf record -a`, the whole audio stack — `alsa-sink`,
`pulseaudio` and `PulseMainloop` together — is **18.4% of all busy CPU**
against the game's own 55.4%. Killing audio outright returns about 18 points
to the game, which is the ceiling on anything audio-side.

Two further things worth knowing before anyone optimises:

* **Muting saves nothing.** The stream is still resampled and mixed; the
  multiply by zero happens at the end. `SDL_AUDIODRIVER=dummy` is what
  actually removes the cost, per app.
* **`trivial` is the cheapest resampler and also the worst.** It picks the
  nearest source sample. At an exact 2:1 ratio that is a clean zero-order
  hold; at a ragged ratio it duplicates irregularly and is audible. Under
  Low-Power/88200 that makes 44.1 kHz music clean and 48 kHz game audio
  ragged. Nobody chose this trade deliberately; it was inherited.

## Diagnosing silence, in order

Work down. Each step is cheap and rules out a whole class.

**0. Is something holding the sinks suspended?**

    pactl list short sinks

If all three read `SUSPENDED` while something is playing, nothing is broken
downstream — the sinks have simply been left suspended. `pasuspender` does this
deliberately for the life of its child and resumes on exit, so a `pasuspender`
that was killed rather than allowed to exit leaves the machine silent
indefinitely. Any stream started afterwards plays into a dead sink and is never
heard. Resume with:

    for s in alsa_output.hw_CARD_L15_DEV_0 speakers headphones; do
      pactl suspend-sink "$s" 0
    done

`SUSPENDED` with **nothing** playing is normal and expected — that is
`module-suspend-on-idle` doing its job. Only suspended-while-playing is a fault.

**1. Is there a real sink, or the silent fallback?**

    pactl list short sinks

Healthy is three entries — `alsa_output.hw_CARD_L15_DEV_0`, `speakers`,
`headphones`. A single `auto_null` means PulseAudio failed to open the card
and fell back to a dummy; the session is silent for its whole life because
PulseAudio never retries. That is **fix 10** (the lightdm greeter took the
card). Confirm in the journal:

    journalctl --user -u pulseaudio.service -b | grep -i "module-alsa-sink"

`systemctl --user restart pulseaudio.service` recovers the running session.

**2. Are the codec's output routes on?**

    for c in 'Handsfree Left Playback' 'Handsfree Right Playback' \
             'Headset Left Playback'   'Headset Right Playback'; do
      printf '%-26s ' "$c"; amixer -c L15 cget name="$c" | sed -n 's/^[[:space:]]*: values=//p'
    done

`1` is on (`HF DAC` / `HS DAC`), `0` is `Off`. All zeros is **fix 9** — the
shipped `asound.state` has every route off. `sudo /usr/local/sbin/pyra-audio-route-apply`
sets them; if that file does not exist the fix is not installed.

**3. Is the PCM actually moving?**

    cat /proc/asound/L15/pcm0p/sub0/status

`/proc/asound/L15` is a symlink to whichever `cardN` the codec landed on this
boot, which is the reason to use it rather than a number. While something
plays it should read `state: RUNNING` with a `hw_ptr` that advances between
two reads. If it is RUNNING and you still hear
nothing, the fault is at or below the codec — go back to step 2, then check
volumes.

**4. Volumes, remembering who owns which.**

    amixer -c L15 cget name='Handsfree Playback Volume'   # speakers: pyra_volumed's, from the wheel
    amixer -c L15 cget name='Headset Playback Volume'     # headphones: nobody's, 0..15

If the speakers are quiet, turn the **wheel** — writing that control by hand
is pointless, `pyra_volumed` overwrites it on the next movement. If the
headphones are quiet, that control and PulseAudio are the only two things in
play.

**5. Only then, PulseAudio's own levels.**

    pactl list sinks | grep -E 'Name:|Mute:|Volume: front'

## Consequences of the 4-channel design

These all look like faults and are not. Each has been chased at least once.

* **MATE's Sound Preferences "Hardware" tab is empty.** That tab lists
  PulseAudio *cards*, and this machine has none — `pyra.pa` uses
  `module-alsa-sink`, not `module-alsa-card`. The **Output** tab, which is the
  one that does anything, correctly lists all three sinks.
* **`pactl list short cards` returns nothing.** Same cause.
* **The sink reports `Flags: HARDWARE` but PulseAudio does software volume.**
  Verified: moving the sink volume between 100% and 50% leaves both ALSA
  volume elements untouched. Do not assume changing one changes the other.
* **Going back to `module-udev-detect` would fix the Hardware tab and the fix
  10 race at once, and is still wrong.** It cannot do the 4-channel open the
  Speakers/Headphones split depends on. That trade has been considered and
  rejected twice; see fixes 9 and 10.

## Traps that will cost you an afternoon

* **A killed `pasuspender` leaves the whole machine silent.** It suspends every
  sink and resumes them from its exit path, so `timeout -s KILL ... pasuspender
  -- prog` — or anything else that SIGKILLs it — never resumes them. The failure
  is silent and survives until something calls `pactl suspend-sink ... 0`.
  Everything started in between plays into a dead sink, which makes it an easy
  way to invalidate a whole afternoon of A/B measurements without noticing.
* **`SDL_AUDIODRIVER=alsa` does not reach the codec on this machine.** SDL
  reports initialising happily, and every playback PCM under `/proc/asound/`
  stays `closed` — SDL's default ALSA device resolves to nothing that drives
  the hardware here, and the 4-channel open the Speakers/Headphones split needs
  is not something SDL will do. "Bypass PulseAudio per-app" is therefore not
  available out of the box, and an app configured that way is silent, not fast.
  Confirm with `for s in /proc/asound/card*/pcm*p/sub0/status; do head -1 $s; done`
  before believing any measurement taken that way.
* **`hw_params` of an open stream is not the device's capability.** It reports
  the *negotiated* rate. Reading `rate: 88200` there and concluding the
  hardware does only 88200 is wrong — `--dump-hw-params` on the free device
  gives `[88200 96000]`. This mistake is already in the history of this repo.
* **`speaker-test -D hw:CARD=L15` failing is usually not a fault.**
  PulseAudio holds the device exclusively. Stop it first, or test through
  `-D pulse`.
* **The card's number is not stable across boots.** L15 was card 4 on one boot
  and card 3 on the next. Address it by name (`hw:CARD=L15`) or by udev
  attribute (`ATTRS{id}=="L15"`). Never write `hw:4`.
* **`Handsfree Playback Volume` drifting between measurements is the wheel,**
  not something clobbering your settings.
* **`alsa-restore` logging `failed to import hw:N use case configuration -2`
  is harmless.** There is no UCM profile for this card; it falls back to
  `asound.state`, which is the intended path here.
* **`alsa-state.service` is inactive on this image.** Nothing re-saves mixer
  state at shutdown. That is why one bad `asound.state` survived every boot —
  and equally why one good one sticks. If you `alsactl store` while the routes
  are off, you have just recreated fix 9's bug.

## Open, and untested

* **The High-Performance PLL mode (96000).** Would make 48 kHz content an
  exact 2:1 instead of ragged, which is a **quality** lever, not a CPU one —
  96000 is more output samples than 88200, so it would cost slightly more, and
  draw more power. Two mixer writes, fully reversible. Nobody has flipped it
  and listened.
* **`speex-fixed-1` instead of `trivial`.** Would sound considerably better
  and cost back some of the ~8-point conversion penalty. Not measured.
* **A 2-channel sink.** `CHANNELS: [1 5]` permits it and it would halve
  everything downstream of conversion, at the cost of the headphone/speaker
  split. A product decision, not a performance one.
* **What a given app actually asks for.** `pactl list sink-inputs` prints each
  live stream's sample spec. Partly answered: Ship of Harkinian asks for
  `s16le 2ch 32000Hz`, a ragged 2.75625:1 against the link. Moving it to 44100
  for an exact 2:1 was tried and **costs 23% more**, not less — see
  `improvements.md` item 10. Matching the *ratio* is a quality lever only;
  only matching the *rate* (88200) reaches the cheap path, and for this title
  that would mean synthesising 2.76x the samples in the game instead. Other
  titles are still unprofiled.

## Reference code and documents

This page describes the **direct McPDM path**, which is what the machine uses
on the stock kernel. The audio DSP (AESS) path is a separate piece of work and
lives in `progress.md` sections 22 to 34; the links below are what that work
drew on, in the order they turned out to be worth.

* **https://github.com/goldelico/omap-aess** — the one that matters. A
  complete kernel tree by the Letux maintainer with the AESS forward-ported to
  7.2, branches `letux/aess-v17`, `letux/aess-asoc-fw-v5`,
  `letux/aess-audio-test-v3` and `letux/aess-abefw-v4` merged into
  `omap-aess-7.2`. Earlier `letux/aess-v14`, `aess-v16` and
  `work-aess-module-v11` are there too.

  This tree gave up the fix for the tinny DSP output in about ten minutes
  after two days of measurement had not: the ABE back ends must set the McPDM
  downlink mask to `MCPDM_PDM_DN_MASK | MCPDM_CMD_INT`, all five downlink
  channels plus the command word, not the slot pair each back end owns. See
  `experiments/aess/0030` and `progress.md` section 32. **Check anything
  AESS-shaped against this tree before investigating it from scratch.**

* **https://github.com/goldelico/letux-rootfs** — the matching Letux
  userspace, 27 Debian source packages. Checked for AESS audio configuration
  and there is none: no `asound.state`, no PulseAudio scripts, no `aess`
  anything. Recorded so nobody looks twice.

* **https://github.com/omap-audio/abefw** — the ABE/AESS firmware *and the
  tools that generate it*, from the omap-audio project. The generator is the
  part that matters: `/lib/firmware/omap_aess-adfw.bin` is otherwise a binary
  with no source, and a firmware-side processing setting cannot be changed any
  other way. Its `peter/bnw` branch is Peter Ujfalusi's.

* **https://www.pyra-handheld.com/wiki/index.php/ABE** — the Pyra wiki's ABE
  page. Records that Ujfalusi, who maintains McPDM and twl6040, recommended
  forward-porting the 3.15 branch of `omap-audio` rather than the 3.8 one this
  driver descends from — which is what `goldelico/omap-aess` is.

* **https://github.com/TI-OpenLink/kernel-omap** — TI's OMAP4 kernel sources,
  where `sound/soc/omap/aess` originated.

* **https://www.ti.com/pdfs/wtbu/OMAP4430_4460_4470_PUBLIC_TRM_Addendum_ABE_HAL_vF.pdf**
  — the ABE/HAL TRM addendum. Source of the start order in section 4.13.2 that
  fixed the original silence, the DL2 -6 dB rule in section 3.8, and the ATC
  descriptor bitfields. Worth reading further; section 3 on the processing
  chain and gains is the useful part.

* The Pyra forum's **"Audio Driver (with bounty!)"** thread, where Ujfalusi and
  Marek Belisko discuss recompiling the AESS firmware from source.
