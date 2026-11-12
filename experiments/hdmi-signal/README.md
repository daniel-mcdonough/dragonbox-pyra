# Why an HDMI monitor shows nothing above 640x480

An HDMI monitor gets a picture from the Pyra only at the lowest modes. The question here is where the
signal fails. The answer so far: on the Pyra's side of the connector, in the TMDS signal itself. X is
ruled out, and so is every documented PLL setting: the DCO range, the fractional divider, PHY_CLKINEN and
TI's older M2 = 3 operating point. M2 = 3 may buy a little margin; it doesn't fix it. The symptoms
and the user-facing summary are in `docs/troubleshooting.md`, "An HDMI monitor shows nothing above 640x480".

## Method: modes set straight on DRM, with X stopped

Set modes with `modetest` from Debian's `libdrm-tests` (trixie `2.4.124-2`, matching the card's
`libdrm2`). The release image has no apt lists, so download the deb on a PC, check it against the
trixie `Packages` index, and copy only `usr/bin/modetest` to `/tmp` on the Pyra. Nothing gets installed.

    sudo systemctl stop lightdm                       # with HDMI unplugged, see below
    sudo /tmp/modetest -M omapdrm -c                  # HDMI-A-1 is connector 56, CRTC 57 is free
    sleep 20 | sudo /tmp/modetest -M omapdrm -s 56@57:1280x720-60
    sleep 20 | sudo /tmp/modetest -M omapdrm -s '56@57:#7'    # by index, for modes with odd rates

Stop X with no monitor attached. With the stock X driver, a monitor at hotplug can hang the 2D GPU, and
X then can't be killed (`docs/troubleshooting.md`, "The X server can hang in a modeset", the etnaviv
section). With X stopped, plugging in a monitor gets you the kernel console on it: at 640x480 when the
EDID read fails, at 1024x768 when it succeeds (fbcon's pick). At 1024x768 the picture drops out every few
seconds, with sideways static in between, which makes a handy live test: the console holds the mode, so
no `modetest` is needed.

The EDID read sometimes fails at plug-in (`omapdss error: HDMI I2C Master Error`), and then the connector
lists only `640x480`. Re-probe with `echo detect | sudo tee /sys/class/drm/card0-HDMI-A-1/status`.

## Result (2026-11-11, release card, `5.6.19-m4-kbdled`)

The full table is in `docs/verification-log.md`. In short: clean colour bars at 640x480 and 720x480
(252-270 Mb/s per TMDS lane). From 650 Mb/s up (1024x768), the result is black, or bars with static. At
720p and 1080p the monitor stays synced (no "no signal") but shows black. This held on two monitors and
two cable paths (a 3' cable, and an 8" cable with a 5" micro-HDMI adapter). Where the cut-off falls moves
with the cable: the 3' cable gave bars with static at 1366x768 and 1600x900, the short pair gave black.

## The registers, read live

`hdmireg.py` reads and writes the HDMI wrapper, PLL, PHY and core through `/dev/mem` with Python `mmap`.
`devmem2` on this image is broken (it prints a wrong virtual address and returns 0), but `/dev/mem`
itself works (`CONFIG_STRICT_DEVMEM` is off). Read only while a mode is held: when HDMI is off, the
registers keep whatever the last mode set left there.

    sudo python3 hdmireg.py dump                      # wp 0x58040000, pll 0x58040200, phy 0x58040300 (8 words)
    sudo python3 hdmireg.py f 0x58040210 3 1 4        # set bits 3..1 of a register

Addresses come from the `ti,omap5-hdmi` node's `reg` (wp, pll, phy, core at `0x58060000`). At 640x480
and 1280x720 the PLL matches `dss_pll_calc_b` exactly (sys_clkin 19.2 MHz, N=8, Fint 2.4 MHz):

| Mode | M.frac | M2 | DCO | SD | SELFREQDCO | PHY TX_CTRL / POWER_CTRL / PAD_CFG |
| --- | --- | --- | --- | --- | --- | --- |
| 640x480 | 314.6875 | 3 | 755.25 MHz | 4 | 2 (low) | `0` / `bf1bcc80` / `00107d80` |
| 1280x720 | 618.75 | 2 | 1485 MHz | 6 | 2 (low) | identical |

TX_CTRL reads 0 because of M2: `hdmi5.c` passes the DCO and CLKOUT (DCO/M2) to `hdmi_phy_configure`,
and when they differ the driver sets FREQOUT to 0. Each field is decoded below.

## What was ruled out, with a mode held and the monitor watched

- **A.** (720p) SELFREQDCO switched to the high range (CONFIGURATION2 `0x00602004` → `0x00602008`), PLL re-locked
  (STATUS 3). Still black. So the DCO sitting 1 % under the 1.5 GHz range switch is not the cause.
- **B.** (720p) Integer-only M (619, M.f 0, DCO 1485.6 MHz), re-locked. Still black. So fractional-N jitter is
  not the cause.
- **D.** The core switched to DVI mid-stream (`FC_INVIDCONF` `0x78` → `0x70`). The monitor lost lock
  ("no signal"), so this one says nothing. A clean DVI test needs the mode set as DVI from the start,
  which takes a kernel knob: `drm.edid_firmware` doesn't reach omapdrm on 5.6, because omapdrm reads the
  EDID through its own `read_edid` and never calls `drm_get_edid`.
- **E.** PHY_CLKINEN on after lock (CONFIGURATION2 `0x00602004` → `0x00606004`, no GO), at 1024x768.
  Drop-outs timed by eye: median 3 s, longest 17 s, against 5 s and 19 s with the bit at 0. No change.
- **F.** TI's 3.8/3.14 operating point at 1024x768: M2 = 3, DCO 1950 MHz, CLKOUT still 650 MHz
  (CFG1 `0x0006580e`, CFG3 `0x00002000`, CFG4 `0x000e0000`, CFG2 `0x00602008`, GO, locked). Median 7 s,
  and two runs of 45 s and 125 s, where 31 timed runs at the driver's point before and after never went
  past 19 s. The static looked the same and the picture still dropped out. Applied once, not repeated: a
  small gain at most.
- **G.** The core's PHY I2C master, which dw-hdmi uses on other SoCs to set a Synopsys PHY's swing and
  termination (`phyi2c.py`). Reads at slave `0x69` and `0x49` time out with neither DONE nor ERROR, and
  `PHY_CONF0` has PDZ at 0. Nothing answers there, so no analog controls are reachable that way.
- Not tried: **C**, the PHY's `POWER_CTRL[3:0]` LDO field, which the driver sets to 0xB on OMAP4 and
  leaves at reset on OMAP5 (`ldo_voltage = false`). TI's own 3.8 driver says these bits are reserved on
  OMAP5 (see "TI's vendor kernels" below), so this test is dropped.

## The PHY registers: what the documentation covers (2026-11-11)

The register descriptions for the HDMI PHY (and the HDMI core) are in neither public TRM. TI's
OMAP543x TRM (SWPU249AG, Dec 2017) has only an overview and the timing tables in section 10.4, then
moves on to RFBI. The AM572x TRM (SPRUHZ6L) covers the same HDMI IP and is cut the same way, but it
does document the HDMI DPLL (section 11.1.3.4 and Table 11-14, recommended values), HDMI_WP and the
control-module bits. Each field below is labelled with where its meaning comes from: the driver
(omapdrm `hdmi_phy.c`/`hdmi5.c` on 5.6), the AM572x TRM, or nothing.

Live dump, read-only (2026-11-11, release card, `5.6.19-m4-kbdled`, X running with `0.6+pyra2`, HDMI
at 640x480 beside the panel). The PHY decodes 5 address bits, so `phy+0x20` mirrors `phy+0x00`.

    phy 58040300: 00000000 f0000000 bf1bcc80 00107d80
    phy 58040310: 11002c00 00007800 00000000 00000800
    pll 58040200: 00000018 00000003 00000000 0002760e   (CONTROL, STATUS, GO, CONFIGURATION1)
    pll 58040210: 00602004 00001000 00000000 00000000   (CONFIGURATION2, 3, SSC1, SSC2)
    pll 58040220: 000c0000                              (CONFIGURATION4)
    wp  58040040: 000000aa                              (HDMI_WP_PWR_CTRL)
    ctrl 4a002e0c: 10000000                             (CONTROL_HDMI_TX_PHY)

| Register | Live | Field | Value | Meaning, source |
| --- | --- | --- | --- | --- |
| TX_CTRL `+0x00` | `00000000` | `[31:30]` FREQOUT | 0 | Driver: 0 when DCO ≠ CLKOUT, i.e. the PHY takes the M2 output (LFBITCLK); 1 or 2 only with M2 = 1. Rest: undocumented. |
| DIGITAL_CTRL `+0x04` | `f0000000` | `[31:28]` | `0xF` | Driver writes `0xF0000000` ("TXVALID and TMDSCLKEN"). The control-module register below names `[30]` TXVALID, `[29]` ENBYPASSCLK, `[28]` PD_PULLUPDET; that this register uses the same layout is a guess. |
| POWER_CTRL `+0x08` | `bf1bcc80` | `[3:0]` LDO | 0 | Driver: OMAP4 writes `0xB` ("max LDO voltage"), OMAP5 leaves it (`ldo_voltage = false`). `[31:4]`: undocumented, never written by the driver. |
| PAD_CFG_CTRL `+0x0C` | `00107d80` | `[30:27]` polarity | 0 | Driver: per-lane P/N swap, none (the board DT has no `lanes`, so the default order). |
| | | `[26:22]` lane order | 0 | Driver: index into its list; 0 is `0x0123`, straight through. |
| | | `[15]` RXDET force | 0 | Driver: held at 1 across LDOON to mask false hotplugs, then cleared. Bits 20, 14-10, 8, 7 set: undocumented. |
| `+0x10` | `11002c00` | all | | Undocumented, not touched by the driver. |
| `+0x14` | `00007800` | all | | Undocumented, not touched by the driver. |
| `+0x18` | `00000000` | all | | Undocumented, not touched by the driver. |
| BIST_CONTROL `+0x1C` | `00000800` | `[11]` | 1 | Driver (OMAP5+): HFBITCLK divided by 2 before LDOON. Rest undocumented. |
| PLL CONFIGURATION2 | `00602004` | `[14]` PHY_CLKINEN | **0** | AM572x Table 11-14: 1, "Enable DPLL_HDMI clock output to HDMI_PHY"; 11.1.3.4.9 says to hold it at 0 *during* locking. The driver clears it and never sets it (`pll.c` `dss_pll_write_config_type_b`). |
| | | `[13]` PLL_REFEN | 1 | AM572x: 1 recommended. Matches. |
| | | `[12]` PLL_HIGHFREQ | 0 | Driver: no divide by 2 of the reference. |
| | | `[3:1]` SELFREQDCO | 2 | Driver: 2 below `clkdco_low`, 4 above. Test A tried 4. |
| | | `[22:21]` REFSEL | 3 | Driver: SYSCLK. |
| WP_PWR_CTRL | `000000aa` | `[7:6]`/`[5:4]` PHY cmd/status | 2/2 | Driver: TXON (the AM572x lists `[7:4]` as reserved). |
| | | `[3:2]`/`[1:0]` PLL cmd/status | 2/2 | AM572x: ON_ALL, the PLL on with its DCO output going to the PHY (3 would cut that output). |
| CONTROL_HDMI_TX_PHY | `10000000` | `[28]` PD_PULLUPDET | 1 | AM572x: low-power RX detection off. Reset value; nothing writes it. |

The VDDA rail is what the uEVM uses: `vdda-supply` is ldo4 at 1.8 V (live, regulator debugfs), shared
with the DSI port. The TMDS lines pass a TPD12S015 on the way to the connector.

### Documented settings, all tried by 2026-11-11

Nothing in the public documents names a PHY drive, swing, pre-emphasis or termination field. The
candidates that come from a document or the driver, cheapest first. Items 1 and 2 were tried at 1024x768
(E and F above):

1. **PHY_CLKINEN on after lock:** CONFIGURATION2 `0x00602004` → `0x00606004`, no GO. This is the
   AM572x's recommended value, and TI's 3.14 kernel sets it after lock on OMAP5 and DRA7 (below). The
   driver from 4.4 on leaves it at 0, and DRA7 boards run 1080p on that. So the odds are low, but the
   bit is documented and costs nothing.
2. **The PLL operating point TI's 3.8 and 3.14 kernels use at 720p:** M2 = 3, DCO 2227.5 MHz, where
   5.6 uses M2 = 2, DCO 1485 MHz. The PHY clock (DCO/M2 = 742.5 MHz) stays the same. Details and
   register values are in the next section.
3. ~~Test C, POWER_CTRL `[3:0]` = `0xB`~~: dropped. TI's 3.8 driver calls these bits reserved on OMAP5.
4. Undocumented fields (`POWER_CTRL[31:4]`, PAD_CFG's other bits, `+0x10`-`+0x18`): not without the
   register descriptions. No TI kernel names or writes them (next section). They need TI's full (NDA)
   TRM, or someone who has it.

## TI's vendor kernels against 5.6 (2026-11-11)

TI wrote its own kernels with the full TRM, so they might name or set PHY fields that mainline doesn't.
They don't. No branch names a PHY register or field beyond 5.6's five registers (`TX_CTRL`,
`DIGITAL_CTRL`, `POWER_CTRL`, `PAD_CFG_CTRL`, `BIST_CONTROL`). None reads or writes `+0x10`-`+0x18`,
`POWER_CTRL[31:4]` or any drive, swing, pre-emphasis or termination field. No board DT gives the HDMI
node anything besides `vdda-supply` (omap5-uevm: ldo4, the same rail as the Pyra; dra7-evm: ldo3). What
differs is how the PLL is set up and which PHY bits the driver sets. Read from the GPL sources with
`git show BRANCH:path`. Baseline: our 5.6 omapdrm, `drivers/gpu/drm/omapdrm/dss/` (`hdmi_phy.c`,
`hdmi5.c`, `pll.c`).

**5.6 at 720p** (live values above): N = 8 (Fint 2.4 MHz), M2 = 2, DCO 1485 MHz, SELFREQDCO 2. FREQOUT
is 0 because DCO ≠ CLKOUT (`hdmi_phy.c:145`). PHY_CLKINEN is cleared before lock and never set again
(`pll.c:533`, `dss_pll_write_config_type_b`). `POWER_CTRL[3:0]` stays at reset (`hdmi_phy.c:162`).
PAD_CFG `[30:27]` and `[26:22]` come from the DT lanes, default 0 (`hdmi_phy.c:119-120`).

| Branch (commit) | Files | PHY/PLL differences from 5.6 |
| --- | --- | --- |
| `ti-linux-3.8.y` (`4f116c97e84d`, TI's OMAP5 merge) | `drivers/video/omap2/dss/`: `ti_hdmi_4xxx_ip.c` (shared by OMAP4 and OMAP5), `hdmi.c`, `ti_hdmi_5xxx_ip.[ch]`, `dss_features.c` | 1. `POWER_CTRL[3:0]`: "OMAP5 HDMI PHY has these bits reserved" (`ti_hdmi_4xxx_ip.c:363-366`). 2. PAD_CFG bit 27 (lane 0's polarity in 5.6's layout) set to 1 on every SoC (`:369`); 5.6 has 0. 3. LDOON goes in before FREQOUT and DIGITAL_CTRL are written (`:322`); 5.6 goes to LDOON after them. 4. FREQOUT compares the pixel clock in kHz with 1 500 000 (`:312`, `:344-351`), so it is 0 for every mode. 5. PLL: below a 750 MHz bit rate, M2 counts up from 3, otherwise M2 = 1 (`hdmi.c:585-614`). At 720p that gives N = 8, M2 = 3, DCO ≈ 2227.5 MHz. SELFREQDCO stays at 2 (low), because the range test looks at the bit rate, not the DCO (`hdmi.c:583`). PHY_CLKINEN is cleared before lock and never set (`ti_hdmi_4xxx_ip.c:114`). 6. The core's PHY I2C master (`HDMI_CORE_PHY_I2CM_*`, `ti_hdmi_5xxx_ip.h:190-191`) is only touched to set its interrupt masks (`ti_hdmi_5xxx_ip.c:629-630`). Nothing programs a PHY through it. `HDMI_CORE_PHY_MASK0` gets 0x00 (`:628`); 5.6 writes 0xf3 (`hdmi5_core.c:554`). Interrupt masks only. |
| `ti-linux-3.12.y` (`68f449afccf6`) | `drivers/video/omap2/dss/`: `hdmi_phy.c`, `hdmi_pll.c`, `hdmi5.c` | 1. FREQOUT from the pixel clock: < 75 MHz → 0, < 186 MHz → 1, else 2 (`hdmi_phy.c:61-75`, `:104-110`). At 720p (74.25 MHz) that's 0, as in 5.6. 2. PAD_CFG bit 27 = 1 (`hdmi_phy.c:91`). 3. PLL: M2 = 3 only up to a 65 MHz pixel clock, otherwise 1 (`hdmi_pll.c:73-76`). At 720p that's M2 = 1, DCO 742.5 MHz, below the 750 MHz minimum that 5.6 and TI's own feature table give. PHY_CLKINEN is cleared and never set (`hdmi_pll.c:124`). `POWER_CTRL[3:0]`: not written on OMAP5, as in 5.6. |
| `ti-linux-3.14.y` (`eda6e65ec037`) | `drivers/video/fbdev/omap2/dss/`: `hdmi_phy.c`, `pll.c` (shared DSI/HDMI PLL code), `hdmi5.c` | 1. FREQOUT: same rule as 3.12, with `<=` 75 MHz (`hdmi_phy.c:152-165`, fixed in `687718b3a1e8` "causes bad freqout to be used for 75MHz pixel clock, leading to sync losts"). At 720p it's 0, as in 5.6. 2. **PHY_CLKINEN set to 1 after lock** (`pll.c:438`, in `pll_set_clock_div`, which `hdmi5.c:172` calls for the HDMI PLL; cleared before lock at `:389`). 5.6's DSI path (`dss_pll_write_config_type_a`, `pll.c:496`) still does this, but its HDMI path doesn't. 3. PLL: N = 16 (Fint 1.2 MHz, `pll.c:248`). M2 = 3 when the bit rate is at or below 750 MHz, otherwise 1 (`pll.c:269-273`). SELFREQDCO is chosen from the DCO (`pll.c:381-386`). At 720p: M2 = 3, DCO 2227.5 MHz, SELFREQDCO 4, SD 9. 4. PAD_CFG bit 27 now comes from the DT lanes (`5349695dd824`, "lane config support", removed the fixed write), as in 5.6. |
| `ti-linux-4.4.y` (`66080347de72`) | `drivers/gpu/drm/omapdrm/dss/` and the omapfb copy in `drivers/video/fbdev/omap2/omapfb/dss/` | None. `hdmi_phy.c` differs only in where the feature table lives (a static pointer picked by `omapdss_get_version()`). `pll.c`, `hdmi_pll.c` and `hdmi_wp.c` have the same register writes as 5.6. |
| `ti-linux-4.19.y` (`5a23bc00e08d`) | as 4.4 | None. Same as 4.4. |
| letux-kernel `master` (`5490f08d098d`) | `drivers/gpu/drm/omapdrm/dss/` | None. `hdmi_phy.c`, `hdmi_pll.c` and `pll.c` differ from 5.6 only in the ioremap helper and a `dss_pll_calc_a` loop guard (`4119bd55e40f`, not the HDMI PLL). Goldelico's own HDMI commits fix register access from the CEC code (hdmi4 and hdmi5) and build warnings. The Pyra DT's HDMI changes all date from 2019, so they are already in 5.6. |
| ti-omap-encore-kernel (`c9e46445a41`, 2.6.35, OMAP3621) | — | None. It has no OMAP HDMI IP driver, only OMAP4 PRCM/pad defines and an external SiI9022 panel driver. |

What this means:

- At 720p, FREQOUT is 0 in every branch, so it isn't the difference.
- The LDO field is out. TI's own code says `POWER_CTRL[3:0]` is reserved on OMAP5.
- **PHY_CLKINEN** is documented twice now: AM572x Table 11-14, and TI's 3.14 driver for OMAP5/DRA7.
  TI's 4.4 and later dropped it, and DRA7 boards run 1080p on those kernels. That keeps the odds low.
- **The PLL operating point** has changed across TI's history. At 720p, 3.8 and 3.14 ran M2 = 3 with the
  DCO at 2227.5 MHz, 3.12 ran M2 = 1 with the DCO at 742.5 MHz, and 4.4 to 5.6 run M2 = 2 with the DCO at
  1485 MHz. The CLKOUT the PHY takes is 742.5 MHz in all three. 5.6's `dss_pll_calc_b` picks the
  smallest M2 that keeps the DCO above 750 MHz (`pll.c:283`). Test A moved SELFREQDCO, and B dropped the
  fraction, but no test has moved M2. The 3.12 point is under the DCO minimum and isn't worth trying. The
  3.8/3.14 point is within range. The cheap way to try it keeps 5.6's N = 8 and writes, with 720p held:
  CONFIGURATION1 `0x0004d40e` → `0x0007400e` (M 618 → 928), CONFIGURATION4 `0x000b0000` → `0x000c8000`
  (M2 3, M.f 0.125), CONFIGURATION3 SD `6` → `9` (`0x00001800` → `0x00002400`), and CONFIGURATION2
  SELFREQDCO `2` → `4` (`0x00602004` → `0x00602008`), then GO and wait for STATUS 3, the same way as test B.
  The "before" words are built from the 1280x720 row above (N 8, M 618.75, M2 2, SD 6); no raw 720p dump was kept. The
  "after" values are computed with 5.6's own SD rule (`pll.c:304`) and haven't been read back.
- PAD_CFG bit 27 = 1 (3.8/3.12) inverts one lane pair, the clock pair in the DT binding's lane order.
  640x480 works with it at 0, so the data lanes' polarity is right. A TMDS receiver should lock to either clock
  polarity, so this isn't proposed.

## Open

What's left is analog: the PHY's drive settings, the board's TMDS routing, or this unit's
micro-HDMI connector. DRA7 and the OMAP5 uEVM run 1080p on the same HDMI IP and driver, so a generic
driver bug is unlikely. Neither the public TRMs nor TI's vendor kernels describe the PHY's analog fields
(above), and the core's PHY I2C master reaches nothing (G). Every documented setting has been tried
(A, B, E, F). The next steps are:

- someone with TI's full TRM;
- asking whether 720p or above works on anyone's V5.x Pyra, which tells "this unit" from "every Pyra".
