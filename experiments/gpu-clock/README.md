# What clock is the GPU actually on?

`clk_summary` says 33.77 MHz. The fill probe says something far faster. This
settles it on 2026-09-25, on `5.6.19-m4`.

`CM_DIV_H14_DPLL_CORE` (0x4A004144) reads divider field 63. TRM Table 3-880:
63 is a special encoding, ÷2.5 then ÷2, so ÷5 overall. 2127.36 / 5 = **425.47 MHz**.
The kernel's divider clock reads 63 literally, which is where 33.77 MHz comes from.

`gpuclk-test.sh` runs the `~/pyra-probe/fill` probe (blended, textured quads the
tile renderer cannot reject) on the GPU's normal source. It then flips both
selects in `CM_GPU_GPU_CLKCTRL` (bits 24/25) to `DPLL_PER` H14 at 384 MHz, while
the module reports idle, runs the probe again, and flips back. A watchdog
restores the core source after 150 s whatever happens.

| source | 1280×720 od 8 | 640×360 od 8 | 1280×720 od 2 |
| --- | --- | --- | --- |
| DPLL_CORE H14 (normal) | 860.2 Mpix/s | 660.7 | 537.6 |
| DPLL_PER H14, 384 MHz | 781.3 (0.908×) | 599.0 (0.906×) | 511.0 (0.95×) |
| back to DPLL_CORE H14 | 861.5 | 657.2 | 544.8 |

384 / 425.47 = 0.903. The fill-bound rows scale with the clock ratio, and the
overdraw-2 row is partly swap-bound, so it moves less. Nothing hung, and
switching the mux at idle is clean both ways.

Side facts found on the way (details in `docs/improvements.md` item 5):
`/dev/mem` through Python's `mmap` reads live CM registers on this kernel,
where `devmem2` returned zeros. The AVS eFuses put this chip's VDD_MM at
1027 mV for OPP_NOM and 1031 mV for OPP_OD, and `smps45` runs at 1.030 V.
