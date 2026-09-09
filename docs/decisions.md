# Decisions and rejected alternatives

## Where this deviates from the forum post

The original writeup works, but a few steps are fragile enough to be worth
replacing:

- **User creation.** The post appends raw lines to `/etc/passwd`, `/etc/group`
  and `/etc/shadow` and has you hand-edit group membership. That is how you end
  up with `gshadow` disagreeing with `group` and `useradd` refusing to run
  later. The script uses `useradd --root` / `usermod --root`, which write all
  four files consistently and honour the image's own `login.defs`.
- **Password handling.** `openssl passwd -6 'yourpassword'` puts the password
  in shell history and in `ps` output. The script prompts with `read -rs` and
  pipes to `chpasswd -e -R`, so it never reaches the process table.
- **The DRI symlink target.** The post hardcodes `kms_swrast_dri.so`. If mesa
  25.x has dropped that name, a blind `ln -s` creates a dangling symlink and you
  get the same segfault with a more confusing log. The script probes for
  `kms_swrast_dri.so`, then `swrast_dri.so`, then any `*_dri.so`, and hard-fails
  rather than leaving a broken link.
- **The first-run marker.** `/var/lib/pyra/first-run.done` is asserted, not
  verified. The script greps the actual `pyra-first-run.sh` for the path it
  really checks, and warns if it has to fall back to the documented default.
- **Enabling pyrainput.** The post has you run `systemctl enable --now
  pyrainput` after boot. The script symlinks it into `multi-user.target.wants`
  offline, so the nubs work on the very first boot.

---

## Rejected alternatives (for when you're tempted)

**Installing trixie to the eMMC instead of a card.** Technically possible, and
it sidesteps the long-press quirk since the eMMC's older U-Boot has no PMIC
check. But it overwrites bookworm-7 — your only known-good system and your only
recovery path. This image is deliberately a live SD image that leaves the eMMC
alone. Don't burn the fallback to test a build that needed four fixes to reach
a desktop.

**The microSD slot under the battery.** Not the documented boot path, and not
confirmed to be on a boot-capable controller.

**USB boot.** OMAP5 peripheral boot exists, but it is an SPL-over-USB recovery
mechanism, not a way to run a rootfs.

---

