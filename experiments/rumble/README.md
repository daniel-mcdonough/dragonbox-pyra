# Rumble: what the vibrator registers do while a game plays an effect

Two small tools for checking force feedback on the Pyra end to end: from an
`FF_RUMBLE` effect on `pyraInput Gamepad`, through pyrainput, to the TWL6040's
vibra registers.

- `ff-update-test.py [--play-again] [STRONG...]` plays one effect and uploads it
  again under the same id at each further strength, a second apart, the way SDL
  changes rumble strength. `--play-again` also writes a play event after each
  update, as SDL does. Needs read/write on the gamepad's event node.
- `trace-vibra.sh COMMAND...` (root) runs a command with the `regmap_reg_write`
  tracepoint on, and prints the writes to the TWL6040 (`0-004b`) registers
  0x18-0x1b: VIBCTLL, VIBDATL, VIBCTLR, VIBDATR. The timestamps use the clock
  `ff-update-test.py` prints, so the two outputs sort into one timeline:

      sudo ./trace-vibra.sh python3 ff-update-test.py | sort -n

A trace records every write, so a motor switched off for 16 ms shows up where
reading `/sys/kernel/debug/regmap/0-004b/registers` now and then would miss it.

Used for fix 29's 0004 (pyrainput updates a playing effect in place): with
0.1.19+pyra1 VIBCTLR (`reg=1a`) drops to 0 at every update; with +pyra2 it stays
1 until the stop. Results in `docs/verification-log.md`, 2026-11-26 "pyrainput
0004". The driver side (0055's codes, the motorless left channel) is in
`docs/kernel-changes.md`.

Two tracing quirks on 5.6.19: a filter term `name == "0-004b"` is accepted and
matches nothing (the script filters on `reg` and picks the device by name in
`sed`), and writing `trace_clock` empties the buffer, so the script reads the
trace before it puts the clock back.
