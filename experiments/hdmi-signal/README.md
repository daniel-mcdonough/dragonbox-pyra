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

    sudo python3 hdmireg.py dump                      # wp 0x58040000, pll 0x58040200, phy 0x58040300
    sudo python3 hdmireg.py f 0x58040210 3 1 4        # set bits 3..1 of a register

Addresses come from the `ti,omap5-hdmi` node's `reg` (wp, pll, phy, core at `0x58060000`). At 640x480
and 1280x720 the PLL matches `dss_pll_calc_b` exactly (sys_clkin 19.2 MHz, N=8, Fint 2.4 MHz):

| Mode | M.frac | M2 | DCO | SD | SELFREQDCO | PHY TX_CTRL / POWER_CTRL / PAD_CFG |
| --- | --- | --- | --- | --- | --- | --- |
| 640x480 | 314.6875 | 3 | 755.25 MHz | 4 | 2 (low) | `0` / `bf1bcc80` / `00107d80` |
| 1280x720 | 618.75 | 2 | 1485 MHz | 6 | 2 (low) | identical |

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

## Open

What's left is analog: the PHY's drive and LDO settings, the board's TMDS routing, or this unit's
micro-HDMI connector. DRA7 and the OMAP5 uEVM run 1080p on the same HDMI IP and driver, so a generic
driver bug is unlikely. Next: the TRM's HDMI PHY register descriptions, then try only the documented
settings. And ask whether 720p or above works on anyone's V5.x Pyra, which tells "this unit" from "every
Pyra".
