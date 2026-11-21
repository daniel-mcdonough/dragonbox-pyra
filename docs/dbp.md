# DBP packages: installing forum apps on the trixie card

> **Type: instructions.** Steps to follow, with the reference behind them.

Tested 2026-11-21 on the r5 release image, kernel `5.6.19-m4-kbdled`, with
GBA.emu 1.5.46.02 (`GBAemu`), the most-downloaded package in the DBP
repository (1532 downloads that day). It installs and runs: the package
registers, gets a menu entry, mounts, and opens its 1280x720 window. Before it
starts, a dialog says three dependencies are missing. They aren't (see below).
Press **Launch**.

A DBP is a squashfs image with a zip of metadata appended. `dbpd` (package
`dbp` 0.6.12.2, already on the image) loop-mounts the image read-only and lays
a writable directory over it with an AuFS union. Nothing is unpacked and
nothing goes through apt. Most forum releases ship this way.

## Install one

Put the `.dbp` in `dragonbox/packages/` at the root of any mounted filesystem.
That can be a second SD card, or the system card itself:

    sudo mkdir -p /dragonbox/packages
    sudo chown -R "$USER": /dragonbox
    cp GBAemu-1.5.46.02.dbp /dragonbox/packages/
    dbp-cmd register /dragonbox/packages/GBAemu-1.5.46.02.dbp
    dbp-cmd list

`dbpd` reads `dragonbox/packages/` on each filesystem when it starts and when
something new is mounted. It doesn't watch the directory, so a file copied onto
a filesystem that's already mounted needs `dbp-cmd register` (above), a reboot,
or `sudo systemctl restart dbpd`. Measured 2026-11-21: after the copy alone,
`dbp-cmd list` was empty; after `register` it listed the package.

Registering exports two things: a menu entry,
`/usr/share/applications/__dbp__<id>_default.desktop`, and a launcher,
`/usr/local/games/<Exec>`. GBA.emu appears under Games.

**`dragonbox/` must be writable by you.** On launch, `dbp-run` creates
`dragonbox/appdata/<id>/` as the user who launched it. That directory is the
writable branch of the union: saves, configs and anything else the program
writes go there. If `dbp-run` can't create it, the mount fails with:

    Error: Unable to set up AuFS union. This is likely a bug. This may temporarily be worked around by rebooting.

and `dmesg` shows `aufs opt_add:...: lookup failed .../dragonbox/appdata/<id> (-2)`.
Rebooting doesn't help. Fix the ownership (the `chown` above). Reproduced
2026-11-21 by calling `dbp-cmd mount` directly, which skips that step.

To undo an install:

    dbp-cmd unregister /dragonbox/packages/GBAemu-1.5.46.02.dbp
    rm /dragonbox/packages/GBAemu-1.5.46.02.dbp
    rm -r /dragonbox/appdata/GBAemu      # the program's saves and settings

## The "missing dependencies" dialog

GBA.emu declares
`Dependency[deb]=libbluetooth3;libvorbis0a;libvorbisfile3;libsndfile1;libvorbisidec1;libpng16-16;libglib2.0-0;`.
On trixie, `dbp-run` reports:

    System packages: libvorbisidec1, libpng16-16, libglib2.0-0

None of these is really missing:

- `libpng16-16` and `libglib2.0-0` are installed as `libpng16-16t64` and
  `libglib2.0-0t64` (see the t64 note below). dbp compares the names
  literally against `/var/lib/dpkg/status` and ignores `Provides:`, so any
  package Debian renamed reads as missing.
- `libvorbisidec1` isn't in trixie. The binary doesn't link it anyway.

The dialog's **Install** button only says automatic installation isn't
supported. **Launch** carries on. On any DBP built for buster or bullseye,
expect this dialog. What decides whether the program runs is whether its
libraries resolve, and the dialog doesn't check that.

## Check a DBP's libraries before running it

Mount it by hand, run `ldd` on the binary, and unmount:

    id=GBAemu
    mkdir -p /dragonbox/appdata/$id       # what dbp-run would do
    tok=$(dbp-cmd mount $id)
    ls /mnt/dbp/union/$id/
    ldd /mnt/dbp/union/$id/gbaemu | grep 'not found'
    dbp-cmd umount $tok

For GBA.emu nothing was `not found` (2026-11-21). `libEGL` and `libGLESv2`
resolve to the SGX driver in `/opt/omap5-sgx-ddk-um-linux/lib`.

`dbp-run --log-output --chdir <id> <executable>` runs a package from a
terminal. Its output goes to `/tmp/dbpout/dbprun-<id>-stdout.log` and
`-stderr.log`.

## Library names, and the t64 change

armhf trixie went through Debian's 64-bit `time_t` transition ("t64"). Every
library whose ABI passes a `time_t` was rebuilt with a 64-bit one, and its
**package** was renamed with a `t64` suffix. The **soname** (`libglib-2.0.so.0`,
`libpng16.so.16`) stayed the same. So:

- **Renamed package, same soname** (`libglib2.0-0` → `libglib2.0-0t64`,
  `libfuse2` → `libfuse2t64`, `libminizip1` → `libminizip1t64`): an old binary
  still loads. It shows up only in the dependency dialog. Any call that
  passes a `time_t` or a struct holding one now disagrees in size between the
  old binary and the library. The fault is silent and depends on whether the
  program makes such calls. GBA.emu ran without visible fault, but that
  doesn't prove every DBP will.
- **New soname** (from the image's package lists: `libtinyxml2-6a` →
  `libtinyxml2-11`, `libglew2.1` → `libglew2.2`, `libunistring2` →
  `libunistring5`, Boost 1.62/1.67 → 1.83, `libbullet` → `libbullet3.24t64`):
  `ldd` says `not found` and the program doesn't start. `libcrypto1.1` is gone
  (trixie has only OpenSSL 3).

A missing soname needs a DBP rebuilt against trixie, or a DBP that bundles its
libraries in its own `lib/`. `/etc/dbp/run_script` puts `$DBP_IMAGE_DIR/lib` on
`LD_LIBRARY_PATH`. Copying a buster `.so` into the system, or symlinking
`libGLEW.so.2.2` to `.so.2.1` (a workaround from the forum on bookworm), mixes
32-bit and 64-bit `time_t` callers, and the result fails silently.

## When a program is killed or crashes

- **The mount can be left behind.** `dbp-run` unmounts when the program exits
  normally. If `dbp-run` itself is killed, the union and the image stay mounted
  (seen 2026-11-21 after a `timeout`). Check with `findmnt -t aufs,squashfs`.
  Remove them with
  `sudo umount /mnt/dbp/union/<id> /mnt/dbp/images/<id>`.
- **Input can stay remapped.** Many launchers (GBA.emu's included) run
  `sudo pyrainputctl overload <file>` before the program and `no-overload`
  after it. If the program dies in between, the nubs and buttons keep the
  game's mapping. Run `sudo pyrainputctl no-overload` to get them back.

## Not tested on this card

- **exFAT for the package card.** The 5.6 kernel has only the old staging exFAT
  driver (`CONFIG_STAGING_EXFAT_FS=m`). On bookworm, forum users saw an AuFS
  mount with an exFAT branch segfault, and DBPs hang the machine from exFAT
  cards. Reformatting to ext4 or f2fs cured both. Use ext4 or f2fs.
- **The DBP Installer package** (`dbpInstaller_sebt3`). It needs
  `python3-apt`, which the image doesn't have (trixie's archive has 3.0.0,
  checked 2026-11-21). On bookworm it fails with
  `ModuleNotFoundError: No module named 'apt_pkg'` until that package is
  installed.
- **Programs that need mesa's software GLX.** Fix 4 turns GLX off, so a DBP
  that runs desktop GL without the `gl4es` wrapper doesn't start at all (on
  bookworm it ran slowly). [gl4es.md](gl4es.md) has the details.
- **A package on a second SD card.** `dbpd` searches every mounted filesystem,
  so it should work the same way, but only the system card's root was tried.
