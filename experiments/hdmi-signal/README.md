# Why an HDMI monitor shows nothing above 640x480

An HDMI monitor gets a picture from the Pyra only at the lowest modes. The question here is where the
signal fails. The answer so far: on the Pyra's side of the connector, in the TMDS signal itself, and
neither in X nor in the PLL setup. The symptoms and the user-facing summary are in `docs/troubleshooting.md`,
"An HDMI monitor shows nothing above 640x480".

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
section). With X stopped, plugging in a monitor gets you the kernel console on it at 640x480.

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

## What was ruled out, with 720p held and the monitor watched

- **A.** SELFREQDCO switched to the high range (CONFIGURATION2 `0x00602004` → `0x00602008`), PLL re-locked
  (STATUS 3). Still black. So the DCO sitting 1 % under the 1.5 GHz range switch is not the cause.
- **B.** Integer-only M (619, M.f 0, DCO 1485.6 MHz), re-locked. Still black. So fractional-N jitter is
  not the cause.
- **D.** The core switched to DVI mid-stream (`FC_INVIDCONF` `0x78` → `0x70`). The monitor lost lock
  ("no signal"), so this one says nothing. A clean DVI test needs the mode set as DVI from the start,
  which takes a kernel knob: `drm.edid_firmware` doesn't reach omapdrm on 5.6, because omapdrm reads the
  EDID through its own `read_edid` and never calls `drm_get_edid`.
- Not tried: **C**, the PHY's `POWER_CTRL[3:0]` LDO field, which the driver sets to 0xB on OMAP4 and
  leaves at reset on OMAP5 (`ldo_voltage = false`). Its meaning on OMAP5 isn't confirmed. Find it in the
  OMAP543x TRM before writing it.

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

### Documented settings worth trying at 720p

Nothing in the public documents names a PHY drive, swing, pre-emphasis or termination field. The
candidates that come from a document or the driver, cheapest first. Each is one write with 720p held
and the owner watching (rule 5); none has been tried:

1. **PHY_CLKINEN on after lock:** CONFIGURATION2 `0x00602004` → `0x00606004`, no GO. This is the
   AM572x's recommended value; the driver leaves it at 0, as DRA7 does, and DRA7 boards run 1080p. So
   the odds are low, but the bit is documented and costs nothing.
2. **Test C, POWER_CTRL `[3:0]` = `0xB`:** the OMAP4 driver's "max LDO voltage". Its meaning on OMAP5
   is still undocumented (TI's own driver drops it for OMAP5), which is why the owner held it back.
3. Undocumented fields (`POWER_CTRL[31:4]`, PAD_CFG's other bits, `+0x10`-`+0x18`): not without the
   register descriptions. They need TI's full (NDA) TRM, or someone who has it.

## Open

What's left is analog: the PHY's drive and LDO settings, the board's TMDS routing, or this unit's
micro-HDMI connector. DRA7 and the OMAP5 uEVM run 1080p on the same HDMI IP and driver, so a generic
driver bug is unlikely. The public TRMs don't describe the PHY's analog fields (above), so the next steps
are the two documented writes in the list above, someone with TI's full TRM, and asking whether 720p or above
works on anyone's V5.x Pyra, which tells "this unit" from "every Pyra".
