# Audio on the Pyra: the chain, the limits, and how to diagnose silence

Updated 2026-09-24 on the running unit, kernel `5.6.19-m4`, Debian 13
(trixie); the speakers, the ports and the OPP section on 2026-10-20 on
`5.6.19-m4-kbdled`. The direct-link sections were verified 2026-09-20 on
`5.6.19-freq`.

This is the map. The repair instructions for the faults that make the machine
silent are fix 9 and fix 10 in `fixes.md`; the performance survey and its
numbers are item 10 in `improvements.md`; the history of the audio DSP work is in
the development log (sections 22 to 34) and `experiments/aess/`; how that work
compares with letux 7.3, and how to move to it, is `aess-letux-7.3.md`. This document is what
you want open when someone says "there is no sound" and you do not yet know
which of those you are looking at — or when you are about to write something
that touches audio and need to know what the hardware will and will not do.

## Two paths, chosen by the kernel

There are two ways audio reaches the codec, and **which one you have depends on
the kernel you booted**, not on anything in userspace:

| kernel | path | PulseAudio script | healthy sinks |
| --- | --- | --- | --- |
| `5.6.19-m4`, `-m4-kbdled` | audio DSP (AESS), `hw:L15,5` | `/etc/pulse/pyra-aess.pa` | `aess`, ports `pyra-speaker` and `pyra-headphones` |
| `5.6.19-fix`, `-freq`, `-pyradef` | direct McPDM link, `hw:L15,0` | `/etc/pulse/pyra.pa` | `alsa_output.hw_CARD_L15_DEV_0`, `speakers`, `headphones` |

Only `-m4` carries the AESS patches. Tell which one is running with:

    grep -q 'MultiMedia1 LP' /proc/asound/pcm && echo AESS || echo direct

**The PulseAudio script must match the kernel, and nothing makes it.**
`/etc/pulse/daemon.conf.d/zz-pyra-aess.conf` selects the AESS script
unconditionally. Boot a direct-link kernel with it installed and `hw:L15,5`
does not exist; delete it and boot `-m4` and device 0 is a front end that does
not serve audio. Either mismatch gives the same symptom — a single `auto_null`
sink, the desktop's "dummy output" — and the journal line that tells them
apart is under *Diagnosing silence* below. On the running unit the boot menu
still offers all four kernels, so three of its entries are silent. This is the
first thing to settle before handing the image to anyone else.

## The AESS path

    app -> PulseAudio -> aess sink -> MultiMedia1 LP -> DSP mixers -> McPDM -> TWL6040 -> amp
                         48000 Hz     hw:L15,5         DL1 headset             routing
                         S16_LE 2ch                    DL2 handsfree           enums

The OMAP5's audio DSP takes what applications actually produce — 48000 Hz,
`S16_LE`, stereo — and does the widening and the rate conversion to the codec's
PDM link in hardware. That is the whole reason for it: the same 48 kHz file
costs **1.1% of a core** in `aplay` against 14.4% on the direct link, and
PulseAudio drops from 12% to 4% (development log §25, §26).

**PulseAudio** is pointed at `pyra-aess.pa` by `zz-pyra-aess.conf`, which is
read after the packaged `pyra.conf` so its assignments win; the packaged
`pyra.pa` is left untouched and reverting is one file deletion. The repository
copies are in `device/pulse/`. Since 2026-10-20 the script loads
`module-alsa-card` with a profile set of our own, on `hw:L15,5`, stereo,
`tsched=0`, `mmap=no`, 4 x 2048-frame fragments. That gives the desktop a
card and the `aess` sink two ports. It needs three files besides the script,
none of them packaged, all installed by hand:

| repository | device |
| --- | --- |
| `device/pulse/alsa-mixer/profile-sets/pyra-aess.conf` | `/etc/pulse/pyra-alsa-mixer/profile-sets/pyra-aess.conf` |
| `device/pulse/alsa-mixer/paths/pyra-speaker.conf` | `/usr/share/pulseaudio/alsa-mixer/paths/pyra-speaker.conf` |
| `device/pulse/alsa-mixer/paths/pyra-headphones.conf` | `/usr/share/pulseaudio/alsa-mixer/paths/pyra-headphones.conf` |

The paths have to be in `/usr/share`: PulseAudio 17 reads a profile set's
paths from there only, ignores `paths_dir=`, and probes a missing path as an
empty one, so the sink comes up with no ports and no error. Without the profile
set the `load-module` line fails and the session gets `auto_null`; the bare
`module-alsa-sink` line it replaced is still in the script, commented out,
and needs none of these files.

**`mmap=no` is not optional.** The ring buffer is the DSP's own memory, mapped
into the process, and it keeps only 32-bit stores; 16- and 8-bit writes vanish.
With mmap on, every stream PulseAudio resamples -- most music, and games at
32 kHz -- plays stale ring contents 128 ms or more old and crackles like a
record, while 48 kHz test tones sound perfect (development log section 35).

**48 kHz only, and 44.1 kHz is resampled in software.** The engine has one
timebase; 44.1 kHz would need the event counter and McPDM retimed together and
nothing in the driver does that, so a 44.1 kHz stream came out 8.84% fast. The
kernel no longer advertises 44100 (`experiments/aess/0029`). The sink is pinned
at 48000 and PulseAudio converts 44.1 kHz material with `speex-float-1` — not
`trivial`, which aliases audibly. Before the resampler change a 44.1 kHz song
into a 48 kHz sink measured 9% of a core; that has not been re-measured with
`speex-float-1`. Most music is 44.1 kHz, so this is the case that matters.

**Headphones versus speakers is a port, switched at the codec.** In the DSP,
DL1 feeds the headset and DL2 the handsfree amplifier, and both DSP paths stay
on. The ports switch the four codec routes instead: `pyra-speaker` sets
`Handsfree Left/Right Playback` to `HF DAC` and the headset routes `Off`;
`pyra-headphones` does the reverse. Choose one in MATE's Sound Preferences,
Output tab, *Connector*, or with `pactl set-sink-port aess pyra-headphones`.
The choice is remembered. The switching was not done with the DSP mixers
because turning those off, even briefly during a port change, can leave the
front end with no back end, and then the PCM will not open (below). There
is no automatic switching on plug-in: the jack switch is stuck (*Open*,
below). The speakers are the default.

**The speakers need the DSP at OPP100, and only kernels with
`experiments/aess/0036` keep it there.** The firmware has three task
networks, OPP25, OPP50 and OPP100. At OPP50 it runs the headset path and
**not** the handsfree one, so the headphones play and the speakers are silent.
Without 0036 the driver selects OPP100 when a stream opens and then drops to
OPP50 within a quarter of a second: every DAPM stream event recalculates the
level from widgets this tree never fills in, and gets 0. This is why the
speakers had never played through the DSP before 2026-10-20. During playback,
check

    sudo cat /sys/kernel/debug/omap-aess/opp_level           # 100 is right, 0 is the bug
    sudo ./device/pyra-aess-trace.py opp                      # MAXTASKBYTESINSLOT 0x10

**The controls.** The DSP graph has two output paths, and the playback device
opens only if **at least one of them is complete**:

| path | switches, all `on` | feeds |
| --- | --- | --- |
| DL1 | `DL1 Mixer Multimedia`, `Sidetone Mixer Playback`, `DL1 PDM Switch` | headphones |
| DL2 | `DL2 Mixer Multimedia` | speakers |

The sidetone mixer is in the DL1 path whether or not sidetone is wanted: the
graph runs `DL1 Mixer -> Sidetone Mixer -> DL1 PDM -> PDM_DL1`. So any one DL1
switch off silences the headphones and nothing else, and DL2 off silences the
speakers. Both paths broken and the device will not open: `dpcm_path_get()`
finds no back end, the kernel logs `no backend DAIs enabled for OMAP ABE Media
LP`, and PulseAudio falls back to `auto_null`. Each of those cases was tested
on 2026-09-24 by switching it off and restarting PulseAudio. Development log §25
says all three DL1 switches are needed for the device to open; that was true
only while DL2 was off.

The gains in front of both paths:

| control | value | note |
| --- | --- | --- |
| `DL1 Media Playback Volume`, `DL2 Media Playback Volume` | 120 | 0 is muted |
| `DL1 Playback Volume`, `DL2 Playback Volume` | 120,120 | 0,0 is muted. DL2 sat at 113 (-7 dB) until 2026-10-20, restored from `asound.state` every boot; nothing chose it. Fix 9's helper now asserts 120 |
 Set these with `amixer -c L15 cset name='...'`, **never `sset`**:
`sset` takes the *simple* control name, with `Switch` and `Playback Volume`
stripped, and silently does nothing when handed the full one.

**Nothing but fix 9 keeps them on.** `pyra-audio-route.sh` installs a udev rule
that runs `/usr/local/sbin/pyra-audio-route-apply` after `alsa-restore`, and
since 2026-09-24 that helper sets the four switches whenever the card has them.
Since 2026-10-20 it also sets the four DSP gains to unity every time, not
only when it finds them at 0, so a leftover like DL2's 113 cannot persist. Before that they lived
only in `asound.state`, and one session that left them off broke every boot
after it — see *Traps* below.

**The codec is held open for five minutes after the last sound.**
`module-suspend-on-idle timeout=300` in `pyra-aess.pa`, rather than the default
five seconds, because the TWL6040 headset driver pops each time it powers up or
down (development log §33). The pop is the codec, identical on both paths; not
cycling it is the only cure found. The power cost of holding it open has not
been measured.

**The direct link is still on this kernel, as `hw:L15,9`, and plays 1.47x
fast.** `legacy_link=1` keeps it as a reference for debugging (development log
§34). Nothing should use it for real audio.

## The direct McPDM path

This is what the machine uses on the stock kernel and on `-fix` and `-freq`.

    app  ->  PulseAudio  ->  remap sink  ->  ALSA sink  ->  McPDM  ->  TWL6040  ->  amp
                             speakers/        4ch                      routing
                             headphones       88200 Hz                 enums

**The codec is a TWL6040**, on i2c, reached over OMAP5's McPDM link. ALSA
enumerates it as `Letux Cortex 15`, addressed by name as `hw:CARD=L15`. On
this path it is one PCM device carrying **four channels**, and the pairs are
not interchangeable:

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

### What the link will not do

From `aplay -D hw:CARD=L15,DEV=0 --dump-hw-params /dev/zero`, with the device
free (stop PulseAudio first or it will report the device busy):

    ACCESS:   MMAP_INTERLEAVED RW_INTERLEAVED
    FORMAT:   S32_LE
    CHANNELS: [1 5]
    RATE:     [88200 96000]

Three constraints follow and none of them are configurable away on this path.
They are the reason the AESS path exists:

* **There is no 44100 and no 48000.** The link is PDM, which is inherently a
  fixed high-rate interface. Every ordinary stream is resampled before it can
  be played. This is the single largest cost in audio playback on this path
  and it cannot be removed, only avoided per-app by an app that will render at
  the link rate.
* **There is no `S16_LE`.** Everything is widened to 32 bits.
* **The two rates are modes, not a range.** `PLL Selection` and `TWL6040 Power
  Mode` select Low-Power (88200) or High-Performance (96000). This machine
  ships in Low-Power.

### What playback costs on the direct link

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
audio CPU figure. This holds on either path.

**A real game, measured under load rather than at idle.** Ship of Harkinian
asks for `s16le 2ch 32000Hz` and pulse resamples it `trivial` to 88200. With
the game running and the thermal profile holding the clock at 1.0 GHz,
`pulseaudio` takes **15.3% of a core** (536 jiffies in a 35 s window). Taken
system-wide with `perf record -a`, the whole audio stack — `alsa-sink`,
`pulseaudio` and `PulseMainloop` together — is **18.4% of all busy CPU**
against the game's own 55.4%. Killing audio outright returns about 18 points
to the game, which is the ceiling on anything audio-side. This was measured
before the AESS path existed; on `-m4` the same game's 32 kHz stream is
resampled to 48 kHz by `speex-float-1` instead, and has not been re-measured.

Two further things worth knowing before anyone optimises:

* **Muting saves nothing.** The stream is still resampled and mixed; the
  multiply by zero happens at the end. `SDL_AUDIODRIVER=dummy` is what
  actually removes the cost, per app.
* **`trivial` is the cheapest resampler and also the worst.** It picks the
  nearest source sample. At an exact 2:1 ratio that is a clean zero-order
  hold; at a ragged ratio it duplicates irregularly and is audible. Under
  Low-Power/88200 that makes 44.1 kHz music clean and 48 kHz game audio
  ragged. Nobody chose this trade deliberately; it was inherited.

## The volume wheel, on both paths

**`pyra_volumed`** (from `pyra-hacks`, enabled by default) reads the encoder
wheel on `palmas-gpadc` and writes **`Handsfree Playback Volume` only**, via
`snd_mixer_selem_set_playback_volume_all` on `hw:CARD=L15`. It sets a volume
and never sets a route. The wheel therefore controls the **speakers and
nothing else** — it does not reach the headphones, which have only
PulseAudio's software volume and the `Headset Playback Volume` control. The
TWL6040 controls are the same on both kernels, so this does not change on the
AESS path.

**The packaged daemon maps the wheel wrongly, and this unit runs a
replacement.** It computes `raw * 29 / 2052`, as if the ADC reading rose
evenly with rotation. The wheel is a tapered pot: held at quarter turns it
read 16, 144, 394, 1071 and 2068. The control is already in dB, so the lower
half of the wheel covered -52 to -42 dB, all of it inaudible, and you had to
go near the top to hear anything. `device/pyra-volumed/` holds a replacement
that goes back from the reading to wheel travel through those measured points
and spreads -40 to +6 dB evenly over it, with the very bottom at -52 dB. It
reads the ADC from sysfs, so it needs no libiio. `sudo ./install.sh` builds
it into `/usr/local/bin` and points the packaged service at it with a
drop-in; `--undo` reverts. Installed 2026-10-20. Another unit's pot may read
differently; the calibration table is at the top of the source.

The control runs 0 to 29, -52 dB to +6 dB in 2 dB steps. On
2026-10-20 it sat at 1, which is -50 dB and inaudible, and after it was set
to 26 by hand `pyra_volumed` moved it to 15 without anyone touching the wheel. So when the speakers seem dead,
read this control before anything else, and turn the wheel rather than
writing it.

## Diagnosing silence, in order

Work down. Each step is cheap and rules out a whole class. First find out which
path the kernel gives you (the `grep` under *Two paths*); the step that differs
between them says so.

**0. Is something holding the sinks suspended?**

    pactl list short sinks

If the sinks read `SUSPENDED` while something is playing, nothing is broken
downstream — they have simply been left suspended. `pasuspender` does this
deliberately for the life of its child and resumes on exit, so a `pasuspender`
that was killed rather than allowed to exit leaves the machine silent
indefinitely. Any stream started afterwards plays into a dead sink and is never
heard. Resume with:

    for s in aess alsa_output.hw_CARD_L15_DEV_0 speakers headphones; do
      pactl suspend-sink "$s" 0 2>/dev/null
    done

`SUSPENDED` with **nothing** playing is normal and expected — that is
`module-suspend-on-idle` doing its job. Only suspended-while-playing is a fault.

**1. Is there a real sink, or the silent fallback?**

    pactl list short sinks

Healthy is `aess` on the AESS path, or `alsa_output.hw_CARD_L15_DEV_0`,
`speakers` and `headphones` on the direct link. A single `auto_null` means
PulseAudio failed to open the card and fell back to a dummy; the session is
silent for its whole life because PulseAudio never retries. Find out why:

    journalctl --user -u pulseaudio.service -b | grep -i "module-alsa-sink"
    sudo dmesg | grep -m1 'no backend DAIs'

* `hw:L15,5` failed **and** dmesg has `no backend DAIs enabled`: the AESS
  routes are off. Step 2.
* `hw:L15,5` failed and `/proc/asound/pcm` has no `MultiMedia1 LP`: the AESS
  PulseAudio script on a direct-link kernel. See *Two paths*.
* `hw:CARD=L15,DEV=0` failed on `-m4`: the packaged script on the AESS kernel.
  Same section.
* Device busy: **fix 10**, the lightdm greeter took the card.

`systemctl --user restart pulseaudio.service` recovers the running session once
the cause is gone.

**2. Are the routes on?**

On either path, the codec's four output routes:

    for c in 'Handsfree Left Playback' 'Handsfree Right Playback' \
             'Headset Left Playback'   'Headset Right Playback'; do
      printf '%-26s ' "$c"; amixer -c L15 cget name="$c" | sed -n 's/^[[:space:]]*: values=//p'
    done

`1` is on (`HF DAC` / `HS DAC`), `0` is `Off`. All zeros is **fix 9** — the
shipped `asound.state` has every route off.

On the AESS path, also the DSP's:

    for c in 'DL1 PDM Switch' 'Sidetone Mixer Playback' 'DL1 Mixer Multimedia' \
             'DL2 Mixer Multimedia' 'DL1 Media Playback Volume' 'DL2 Media Playback Volume'; do
      printf '%-26s ' "$c"; amixer -c L15 cget name="$c" | sed -n 's/^[[:space:]]*: values=//p'
    done

The tables under *The AESS path* say what each needs to be.
`device/pyra-audio-route.sh --check` prints both sets, from a checkout. For either, `sudo /usr/local/sbin/pyra-audio-route-apply` sets
them; if that file does not exist fix 9 is not installed. Then restart
PulseAudio, because a sink that failed to load at login does not come back by
itself.

**3. Is the PCM actually moving?**

    cat /proc/asound/L15/pcm5p/sub0/status     # AESS
    cat /proc/asound/L15/pcm0p/sub0/status     # direct link

`/proc/asound/L15` is a symlink to whichever `cardN` the codec landed on this
boot, which is the reason to use it rather than a number. While something
plays it should read `state: RUNNING` with a `hw_ptr` that advances between
two reads. If it is RUNNING and you still hear nothing, the fault is at or
below the codec — go back to step 2, then check volumes.

**4. Volumes, remembering who owns which.**

    amixer -c L15 cget name='Handsfree Playback Volume'   # speakers: pyra_volumed's, from the wheel
    amixer -c L15 cget name='Headset Playback Volume'     # headphones: nobody's, 0..15

If the speakers are quiet, turn the **wheel**. Writing that control by hand
does no good, because `pyra_volumed` overwrites it. To test at a fixed level,
`sudo systemctl stop pyra_volumed` first and start it again afterwards. If
the speakers are silent on the AESS path and the headphones are not, check
the OPP (*The AESS path*) before anything else. If the
headphones are quiet, that control and PulseAudio are the only two things in
play. On the AESS path the DSP gains in the table above sit in front of both.

**5. Only then, PulseAudio's own levels.**

    pactl list sinks | grep -E 'Name:|Mute:|Volume: front'

## Consequences of the PulseAudio design

These all look like faults and are not. Each has been chased at least once.

* **MATE's Sound Preferences "Hardware" tab is empty on the direct link.**
  That tab lists PulseAudio *cards*. The packaged `pyra.pa` uses a bare
  `module-alsa-sink`, which makes no card, so `pactl list short cards` is
  empty too. On the AESS path, since 2026-10-20, it lists the card
  `alsa_card.L15` with one profile, and the Output tab has the
  Speakers/Headphones connector. A MATE window that was open while
  PulseAudio restarted shows stale devices; close it and open it again.
* **The sink reports `Flags: HARDWARE` but PulseAudio does software volume.**
  Verified on the direct link: moving the sink volume between 100% and 50%
  leaves both ALSA volume elements untouched. Do not assume changing one
  changes the other.
* **Going back to `module-udev-detect` would fix the Hardware tab and the fix
  10 race at once, and is still wrong for the direct link.** It cannot do the
  4-channel open the Speakers/Headphones split depends on. That trade has been
  considered and rejected twice; see fixes 9 and 10. On the AESS path that
  argument does not apply, and `pyra-aess.pa` loads `module-alsa-card` itself,
  still without `module-udev-detect`.
* **Why a profile set and not UCM.** A UCM profile for this card was written
  and loaded first. PulseAudio 17 turns UCM devices that share a PCM into one
  *profile* each, so Speakers and Headphones became two profiles in the
  Hardware tab, and the Output tab had nothing to choose. This happens with or
  without `ConflictingDevice`. A profile set with two paths on one mapping
  gives one sink with two ports. Do not reinstall a UCM file for `L15`
  alongside it; `alsactl` would start using it too.

## Traps that will cost you an afternoon

* **Mixer state is re-saved at every shutdown.** `alsa-state.service` is
  inactive on this image, but `alsa-restore.service` has
  `ExecStop=alsactl store`, so whatever the routes are when the machine goes
  down is what the next boot restores. One session that left the AESS routes
  off broke every boot after it: PulseAudio failed to open `hw:L15,5`, fell
  back to `auto_null`, and the kernel logged `no backend DAIs enabled for OMAP
  ABE Media LP`. That happened on 2026-09-21 and went unnoticed for four boots.
  Fix 9's helper now asserts those routes after `alsa-restore`, so a bad saved
  state no longer survives a reboot — but it still survives until the reboot.
  If you `alsactl store` while the routes are off, you save the bad state.
* **Crackle on music but clean test tones, on the AESS path, means something
  is writing the DSP's memory through a mapping.** The kernel stops that from
  patch 0032 on, and `mmap=no` in `pyra-aess.pa` stops PulseAudio doing it on
  a kernel without 0032. Check both before anything else. On such a kernel,
  recording `aess.monitor` also crashes PulseAudio with SIGBUS.
* **A killed `pasuspender` leaves the whole machine silent.** It suspends every
  sink and resumes them from its exit path, so `timeout -s KILL ... pasuspender
  -- prog` — or anything else that SIGKILLs it — never resumes them. The failure
  is silent and survives until something calls `pactl suspend-sink ... 0`.
  Everything started in between plays into a dead sink, which makes it an easy
  way to invalidate a whole afternoon of A/B measurements without noticing.
* **A/B comparisons against `hw:L15,9` are against a link that plays 1.47x
  fast.** Every comparison in development log §26 to §31 used it. See §34.
* **`SDL_AUDIODRIVER=alsa` does not reach the codec on the direct link.** SDL
  reports initialising happily, and every playback PCM under `/proc/asound/`
  stays `closed` — SDL's default ALSA device resolves to nothing that drives
  the hardware here, and the 4-channel open the Speakers/Headphones split needs
  is not something SDL will do. An app configured that way is silent, not fast.
  On the AESS path the device offers read/write access only (patch 0032), so
  anything opening `hw:L15,5` directly must write 48 kHz; `plughw:L15,5` with
  a 44.1 kHz file fails to open. The `default` ALSA device is PulseAudio,
  which resamples, and is what SDL's ALSA driver uses unless told otherwise. Confirm with
  `for s in /proc/asound/card*/pcm*p/sub0/status; do head -1 $s; done`
  before believing any measurement taken that way.
* **`module-alsa-sink` "initialization failed" is not always its arguments.**
  Twice during the AESS work it was something else: an earlier load already
  holding the device, then nested quotes in `sink_properties` mangled by the ssh
  command line. Test module arguments from a file and check what reached the
  daemon before blaming a parameter.
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
  `asound.state`, and fix 9's udev rule runs after it.

## Open, and untested

* **Selecting the PulseAudio script from the kernel.** See *Two paths*. A boot
  step that checks for `MultiMedia1 LP` and picks the script would remove the
  mismatch; nothing does it yet.
* **What `speex-float-1` costs for 44.1 kHz music on the AESS path.** The 9%
  figure predates it.
* **Automatic headphone/speaker switching on the AESS path.** The ports exist
  and switch by hand. Switching on plug-in needs the jack switch, and it is
  stuck: `Headset Stereophone Jack` and `Headset Mic Jack` both read `on`,
  and the input device reports `SW_HEADPHONE_INSERT 1`, with the jack empty
  and with headphones in. Not traced. The plug interrupt `twl6040_irq_plug`
  had counted 44598 after two hours of uptime, so it is firing, or
  bouncing. Once the switch works, add a `[Jack Headset Stereophone]`
  section to `pyra-headphones.conf`.
* **The power cost of the five-minute idle timeout.** One word to revert.
* **The High-Performance PLL mode (96000), direct link.** Would make 48 kHz
  content an exact 2:1 instead of ragged, which is a **quality** lever, not a
  CPU one — 96000 is more output samples than 88200, so it would cost slightly
  more, and draw more power. Two mixer writes, fully reversible. Nobody has
  flipped it and listened.
* **`speex-fixed-1` instead of `trivial`, direct link.** Would sound
  considerably better and cost back some of the ~8-point conversion penalty.
  Not measured.
* **A 2-channel sink, direct link.** `CHANNELS: [1 5]` permits it and it would
  halve everything downstream of conversion, at the cost of the
  headphone/speaker split. A product decision, not a performance one.
* **What a given app actually asks for.** `pactl list sink-inputs` prints each
  live stream's sample spec. Partly answered: Ship of Harkinian asks for
  `s16le 2ch 32000Hz`, a ragged 2.75625:1 against the direct link. Moving it
  to 44100 for an exact 2:1 was tried and **costs 23% more**, not less — see
  `improvements.md` item 10. Matching the *ratio* is a quality lever only;
  only matching the *rate* (88200) reaches the cheap path, and for this title
  that would mean synthesising 2.76x the samples in the game instead. On the
  AESS path the cheap rate is 48000 instead. Other titles are still
  unprofiled.

## Reference code and documents

The AESS path's history is in the development log (sections 22 to 34) and the patches
and tools under `experiments/aess/`; the links below are what that work drew
on, in the order they turned out to be worth.

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
  `experiments/aess/0030` and development log section 32. **Check anything
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
