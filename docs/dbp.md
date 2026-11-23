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
    dbp-cmd list

On a second SD card, format it ext4 or f2fs, **never exFAT** (see "exFAT
crashes the kernel" below). A new ext4 or f2fs filesystem's root belongs to
root, so make the folder with `sudo` and hand it to yourself, the same way.
The card mounts under `/media/$USER/<label>`:

    M=/media/$USER/<label>
    sudo mkdir -p $M/dragonbox/packages
    sudo chown -R "$USER": $M/dragonbox
    cp GBAemu-1.5.46.02.dbp $M/dragonbox/packages/

then take the card out and put it back (or `sudo systemctl restart dbpd`),
for the reason in the next paragraph. Tested 2026-11-23 with GBA.emu on a
119 GB card, ext4, in the right slot: it registered when the card was
mounted, ran, and kept its writable files in the card's
`dragonbox/appdata/GBAemu/`. Unmounting the card unregistered it and removed
its menu entry and launcher. Don't put a card written from the trixie image
in the second slot as package storage: see troubleshooting.md, "Two cards
from the image in the Pyra: the wrong root".

`dbpd` registers a package as soon as its copy finishes, and unregisters it
when the file is deleted. It does this with an inotify watch on each
`dragonbox/packages/` folder. The watch is set only when the filesystem is
mounted or `dbpd` starts. **If the folder didn't exist then, nothing watches it**
until the next mount, reboot or `sudo systemctl restart dbpd`. Until then,
register by hand with `dbp-cmd register /path/to/file.dbp`. Measured
2026-11-21: a folder created after `dbpd` started got no watch; after a
restart, a copy registered within 3 s and a removal unregistered it. The log line
`An error occured while registering a package none` during a copy is harmless:
the file is seen before the copy finishes, then registered when it does.

Double-clicking a `.dbp` in the file manager opens it with `dbp-run-path`,
which registers and runs it in one step (MIME handler set; not tried).
Running `./file.dbp` in a shell doesn't work: the binfmt entry the package
ships isn't registered on the card.

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
- `libvorbisidec1` is in trixie (1.2.1+git20180316-8+b1) but not installed.
  The binary doesn't link it, so it isn't needed.

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

## A DBP that needs GLX

Fix 4 turns GLX off, so a DBP that runs desktop GL without the `gl4es` wrapper
doesn't start at all (on bookworm it ran slowly). Start its launcher as
`gl4es /usr/local/games/<Exec>`: `dbp-run` passes the environment on (checked
2026-11-21 with Ice Field Frenzy). [gl4es.md](gl4es.md), "Programs that need
GLX", has the messages and the one game that needed more.

## When a program is killed or crashes

- **The mount can be left behind.** `dbp-run` unmounts when the program exits
  normally. If `dbp-run` itself is killed, the union and the image stay mounted
  (seen 2026-11-21 after a `timeout`). Check with `findmnt -t aufs,squashfs`.
  Remove them with
  `sudo umount /mnt/dbp/union/<id> /mnt/dbp/images/<id>`. The two empty
  mount points stay, and if the `.dbp` was deleted meanwhile, so does its loop
  device (`sudo losetup -l` shows it `(deleted)`; `sudo losetup -d` frees it).
- **Input can stay remapped.** Many launchers (GBA.emu's included) remap
  input for the game and undo it on exit, so a crash leaves the game's
  mapping. Recovery: [troubleshooting.md](troubleshooting.md), "Nubs, d-pad or game buttons dead
  after a game or DBP crashed".

## exFAT crashes the kernel

Don't keep DBPs on an exFAT card. The 5.6 kernel has only the old staging
exFAT driver (`CONFIG_STAGING_EXFAT_FS=m`). The card mounts, and copying a
`.dbp` onto it works (checksum intact) and registers it. Launching it hits a
kernel BUG. Reproduced 2026-11-23 with GBA.emu on `5.6.19-m4-kbdled`, mounted
the way udisks mounts exFAT (`uid=1000,gid=1000`):

    kernel BUG at fs/buffer.c:3082!
    PC is at submit_bh_wbc+0x194/0x1b8
     ... exfat_write_begin [exfat] ... do_xino_fwrite [aufs] ... aufs_fill_super [aufs]

AuFS keeps an index file (`xino`) on its writable branch, here
`dragonbox/appdata/<id>` on the exFAT card. Its first write goes through the
staging driver's `exfat_write_begin`, which trips the BUG. The oops kills a
`dbpd` thread in the middle of the mount. The window never opens, `dbp-run`
waits forever, and `dbp-cmd` stops answering. Later, `sync` segfaulted with
a second oops (in `rwsem_down_read_slowpath`) on the half-built AuFS mount.
This matches what forum users reported on bookworm (AuFS segfaults, hangs
from exFAT cards). Recovery: troubleshooting.md, "A DBP launched from an
exFAT card: kernel BUG, then nothing answers". Reformat the card ext4 or
f2fs.

## The DBP Installer

`dbpInstaller_sebt3` 1.2.1 (from the DBP repository; MD5
`0177ded6197a2f9df0f4e3d1a76bcb80`, as the repository lists it) works on
trixie once `python3-apt` is installed. Tested 2026-11-23 with python3-apt
3.0.0 installed by hand (`sudo apt install python3-apt`). It bundles a
Python 3.7 copy of the `apt` module, whose compiled `apt_pkg` can't load on
trixie's Python 3.13, so it uses the system's `apt_pkg`. Without
`python3-apt`, it stops with `ModuleNotFoundError: No module named
'apt_pkg'` (seen on bookworm).

Its window lists the repository's packages and their details. It downloads
into `dragonbox/packages/` on the card you choose, checks the MD5, and
leaves registering to `dbpd`. From a terminal:

    dbp-run --chdir dbpInstaller_sebt3 dbpInstaller.sh cards
    dbp-run --chdir dbpInstaller_sebt3 dbpInstaller.sh -d RootFs install icefieldfrenzy.farox

**Its "RootFs" choice downloads to `~/dragonbox/packages`, and `dbpd` never
looks there.** `dbpd` searches `dragonbox/packages` at the root of each
mounted filesystem, and your home folder isn't one. The download completes
and nothing registers, even after a `dbpd` restart (tested 2026-11-23). Two
ways round it: choose a second card (anything mounted under `/media`), or
point `~/dragonbox` at the system card's folder once:

    sudo mkdir -p /dragonbox/packages
    sudo chown -R "$USER": /dragonbox
    rmdir ~/dragonbox/packages ~/dragonbox 2>/dev/null
    ln -s /dragonbox ~/dragonbox

With that link, an Installer download registered within 4 s.

Before downloading, the Installer checks the package's
`Dependency[deb]=` list against apt. It installs any that are missing with
`pkexec apt-get -y install`, which goes through polkit (not run here). Old names that
trixie renamed (`libasound2`, `libglib2.0-0`, `libpng16-16`) are only
reported as "not found" and skipped. For GBA.emu it would install
`libvorbisidec1`, which is harmless but not needed.

## Not tested on this card

- **The Installer's apt step and its DownLoad button.** Only the
  command-line download was run (2026-11-23). What the Installer would
  install was read from its own dependency check, not by letting it run
  `pkexec apt-get`.
- **A DBP from an f2fs second card.** ext4 was tried; f2fs is the system
  card's own filesystem and should behave the same.
