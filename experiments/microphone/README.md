# Microphone and capture (R103)

Forum users report mic noise, and one says the built-in mic records only
"rhythmic soft popping" (https://pyra-handheld.com/boards/posts/1689224/).
The docs never covered capture.

**Status, 2026-11-23, CPU board V5.3, mainboard V5.3, release card (prep
`8c3a35d`):** no capture on `5.6.19-m4-kbdled`, because the AESS uplink was
never built. Capture works on `5.6.19-pyradef`, but the built-in mic gives no
signal even with its bias on. The headset mic is untested (no 4-pole headset).
The summary and how to record are in `docs/audio.md`, "Recording: the
microphones". The run is in `docs/verification-log.md`.

## Files

| File | What it does |
| --- | --- |
| `analyse.py` | On the PC: RMS/peak per window, band shares, band levels per time range, strongest spectral lines. Recordings are copied off the card; the card has no sox. |
| `codec-state.sh` | On the Pyra, as root, stock kernel: the TWL6040 mic registers and DAPM widgets while a capture runs. |

## Method

All recordings were made with `arecord -D hw:CARD=L15,DEV=0 -f S32_LE -c 2`,
with `Analog Left Capture Route` = `Main Mic` (the built-in mic) and the
right channel on `Headset Mic` or `Sub Mic`. They were analysed on the PC with
`analyse.py`. The clips are not kept in the repo.

1. Shipped kernel: `arecord -l`, `pactl list short sources`, and an open of
   each capture device (0, 1, 2).
2. Stock kernel (one boot of `l0`, `pyra-boot-kernel.sh debug l0 --once`):
   - 50 s at +12 dB (`Capture Volume` 1), 96000: quiet room, speech at 30 cm,
     taps on the case, quiet.
   - The Pyra's speakers as the source: a 1 kHz sine at -10.5 dBFS played with
     `paplay -d speakers` (`Handsfree Playback Volume` 25), recorded with
     every capture route at +12 and +30 dB. The same tone went to `-d
     headphones` with the jack empty, to tell sound from electrical coupling.
   - The tone recorded at 96000 and at 88200, for the rate.
   - 32 s at +30 dB, 88200: quiet, loud speech and claps at 10 cm around the
     case, fingernail scratches on the case.
   - `codec-state.sh`.

## Numbers

Shipped kernel: `audio open error: Invalid argument` on devices 0, 1 and 2.
Only `aess.monitor` as a source.

Stock kernel, built-in mic (left channel):

| condition | result |
| --- | --- |
| first 100 ms of every capture | 0 dBFS peak (stream-start click) |
| quiet, +12 dB | -82 dBFS RMS; 80% of the energy above 20 kHz |
| speech at 30 cm, +12 dB | every 1 s window -80 to -82 dBFS, the same as quiet |
| quiet, +30 dB | -68 dBFS RMS; strongest lines 60/100/120/180/240 Hz at about -88 dBFS |
| loud speech and claps at 10 cm, +30 dB | band levels within 1 dB of quiet (100-300 Hz: -37.1 quiet, -36.8 speech); one transient at 10 s, peak -38 dBFS, about 40 ms |
| scratching the case, +30 dB | within 0.5 dB of quiet |
| clicks in 8 s of quiet, +30 dB | 11 windows of 5 ms above 3x the median, in five groups 0.8-2 s apart; peak/RMS 24 dB |
| speaker tone, +12 dB | fundamental -96 dBFS, 2nd harmonic -85 dBFS |
| speaker tone, +30 dB | fundamental -84 dBFS, 2nd harmonic -78 dBFS |
| tone through the headphone path, +30 dB | not present |
| tone recorded at 96000 | appears at 1088 Hz (96000/88200 x 1000) |
| tone recorded at 88200 | appears at 1000 Hz |

The right channel: `Sub Mic` stays flat (-74 dBFS RMS at +30 dB, no response
to anything). It is not in the DT routing. `Headset Mic` with the jack empty:
-93 dBFS in 200-8000 Hz while nothing plays, and about -35 dBFS at 52-57 Hz
while anything plays.

Codec state during a capture: `AMICBCTL` = `0x11` (main and headset bias
on), `MICLCTL` = `0x0d` (Main Mic selected, mic amp and ADC on), `MICRCTL` =
`0x05`, `MICGAIN` = `0x09`. DAPM: `Main Mic Bias`, `Main Handset Mic`,
`MAINMIC`, `MicAmpL`, `ADC Left`, `Headset Mic Bias`, `HSMIC`, `ADC Right` all
On. Same boot: `ts3a227e` fails its probe on stock (`Cannot request irq 197`,
the known jack-detect fault, `experiments/jack-detect/`).

## What it means, and what's left

The codec is set up correctly, and the built-in mic input sees nothing but its
own noise. An electret at that bias, with speech at 10-30 cm, would
read somewhere around -40 dBFS at +30 dB (estimate, not measured). It is 25 dB
or more short of that, so this is not a quiet mic. Either there is none on the
`MAINMIC` net, or it is not connected, or the bias doesn't reach it. That needs
the mainboard schematic (rev 5.1.3, not in this repo) and a meter on the bias
line (NEXT R104). The speaker tone at -84 dBFS needs no working mic; crosstalk
from the class-D amplifier would explain it.

AESS capture (NEXT R105) needs the uplink routers in `omap-aess-fw.c`, the
`PDM_UL1` route in the DT, and an input mapping in `pyra-aess.conf`. It is
only worth doing for the headset mic, and that is untested on stock too.
