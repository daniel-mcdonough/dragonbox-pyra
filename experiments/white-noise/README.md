# White-noise bursts from the built-in codec (R79)

Seven forum users report bursts of white noise from the speakers or the
headphone jack, never over Bluetooth or USB audio; FBNeo's "Bad Apple" was the
usual way to provoke it. EvilDragon put it down to the microphone link opening
at each playback start, and to a hardware fault, tolerance-dependent, to be
fixed in a later CPU board revision
(https://pyra-handheld.com/boards/posts/1688403/). daveshah proposed a kernel
patch to keep the uplink off (https://pyra-handheld.com/boards/posts/1689207/).

**Status: not reproduced, 2026-11-22, on CPU board V5.3 (mainboard V5.3), on
both audio paths.** Summary and the kernel side in `docs/audio.md`
"White-noise bursts"; the run itself in `docs/verification-log.md`.

## Files

| File | What it does |
| --- | --- |
| `make-tones.py` | Writes `tone.wav`, `silence.wav` and `long.wav` (48 kHz S16 stereo). Run on the PC; the card has no sox. |
| `reproduce.sh` | On the Pyra: N cycles of sink suspend, reopen, 3 s silence, a beep; then two minutes of beeps. Timestamps each step. |
| `analyse.py` | On the PC: lists broadband (3-16 kHz) events in a recording of the headphone output, and the longest. |

## Method

The Pyra's headphone output went into the PC's analog line-in, recorded with
`parecord` at 48 kHz while `reproduce.sh` ran (input at the PC's base volume,
10 %). That covers the headphone path objectively. The speakers were judged by
ear (the owner), with a burst agreed beforehand as audible hiss or static of
about 0.2 s or more that is not in the source; clicks and pops at stream
start or stop do not count.

A synthetic loop rather than FBNeo: the reports tie the burst to playback
starting, and suspending the sink closes and reopens the PCM (and with it the
McPDM link) every cycle, twenty times in two minutes.

## Result

| path, kernel | output | opens | longest broadband run | heard |
| --- | --- | --- | --- | --- |
| AESS, `5.6.19-m4-kbdled` | headphones (recorded) | 20 + 2 min | 40 ms | — |
| AESS, `5.6.19-m4-kbdled` | speakers | 10 + 2 min | — | pops between beeps; no clear hiss |
| direct, `5.6.19-pyradef` | headphones (recorded) | 20 + 2 min | 20 ms | — |
| direct, `5.6.19-pyradef` | speakers | 10 + 2 min | — | pops only, softer than on AESS |

Every 20-40 ms event is a beep edge or the thump at sink open and close. The
thumps are DC steps, not noise: all their energy is below 100 Hz, about -0.73
of full scale at open and +0.63 at close on the line-in, then the PC input's
AC coupling drains them over about 100 ms. Same size on both paths.
Hiss between beeps, 1-16 kHz: -55 dBFS on AESS, -53 dBFS on the direct link
(measured at the PC input as set, not calibrated to volts).

## Not tried

- FBNeo and "Bad Apple" itself (not packaged for the card).
- Another CPU board revision. If the fault is component tolerance, this unit
  may simply not have it.
- daveshah's patch: nothing here to verify it against.
