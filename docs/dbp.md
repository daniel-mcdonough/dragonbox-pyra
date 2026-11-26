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

A repository app page like `https://pyra-handheld.com/repo/apps/161` is HTML, not the package — fetching that
URL gets back a web page, not a `.dbp` (check with `file` before trusting a download). The actual file is at
`https://pyra-handheld.com/repo/packages/<name>/download`, a link the page carries in an embedded JSON blob
rather than a plain `<a href>`. Tested 2026-11-24 with `dbpInstaller_sebt3`: the `/download` URL matched the
repository's listed MD5.

Put the `.dbp` in `dragonbox/packages/` at the root of any mounted filesystem.
That can be a second SD card, or the system card itself:

    sudo mkdir -p /dragonbox/packages
    sudo chown -R "$USER": /dragonbox
    cp GBAemu-1.5.46.02.dbp /dragonbox/packages/
    dbp-cmd list

On a second SD card, format it ext4 or f2fs, **never exFAT** (see "exFAT
crashes the kernel" below). If the card ever held the trixie image, give it a
new partition table first, not just a new filesystem. The old table's disk
id can make the Pyra mount this card as `/` (troubleshooting.md, "Two cards
from the image in the Pyra"). A new ext4 or f2fs filesystem's root belongs to
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

**The appdata directory name is the `.desktop`'s `Appdata=` key, not the
package id**, and they aren't always the same string. Calling `dbp-cmd mount`
directly (skipping `dbp-run`'s own directory creation, as above) needs
`mkdir -p dragonbox/appdata/<Appdata>` — using `<id>` instead gives the same
`lookup failed .../dragonbox/appdata/<Appdata> (-2)` even though a same-named
`dragonbox/appdata/<id>/` already exists. Seen 2026-11-25 with
`casio_sw-10_m-ht` (`Id=casio_sw-10_m-ht`, `Appdata=casio_sw-10`).

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
    ad=$(unzip -p /dragonbox/packages/GBAemu-1.5.46.02.dbp meta/default.desktop | sed -n 's/^Appdata=//p' | tail -1)
    mkdir -p "/dragonbox/appdata/${ad:-$id}"   # what dbp-run would do
    tok=$(dbp-cmd mount $id)
    ls /mnt/dbp/union/$id/
    ldd /mnt/dbp/union/$id/gbaemu | grep 'not found'
    dbp-cmd umount $tok

For GBA.emu nothing was `not found` (2026-11-21). `libEGL` and `libGLESv2`
resolve to the SGX driver in `/opt/omap5-sgx-ddk-um-linux/lib`.

The appdata folder must carry the package's `Appdata=` name, which can differ
from its id: Fiat Homo is `fiathomo_farox` with `Appdata=fiathomo`. Without
that folder, `dbp-cmd mount` fails with `Error: Unable to set up AuFS union`
and the kernel log has `aufs opt_add: lookup failed /dragonbox/appdata/fiathomo
(-2)`. The message suggests a reboot, but the folder is what's missing.
`dbp-run` makes it itself. The snippet above reads the name from the
package. `unzip` can't read the metadata of every package: on ft2-clone 2.26
it reported a zip with extra bytes and printed nothing, so check that `ad` came
out non-empty.

A library the launcher bundles shows as `not found` here, because `ldd`
doesn't get the launcher's `LD_LIBRARY_PATH`. Read the launcher script before
treating it as missing. Farox's demos ship their own `libfmod.so.10`/`.so.13`
next to the binary and set `LD_LIBRARY_PATH=./`.

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
  doesn't prove every DBP will. ptitSeb's P* emulators fail this way: given
  `libfuse2t64` for `libfuse2`, their FUSE file reads come back corrupt
  (see "ptitSeb's P* emulators" below).
- **New soname** (from the image's package lists: `libtinyxml2-6a` →
  `libtinyxml2-11`, `libglew2.1` → `libglew2.2`, `libunistring2` →
  `libunistring5`, Boost 1.62/1.67 → 1.83, `libbullet` → `libbullet3.24t64`,
  `libflac12` → `libflac14`): `ldd` says `not found` and the program doesn't
  start. `libcrypto1.1` is gone (trixie has only OpenSSL 3). ScummVM-Pyra
  2026.4.0 hits this one directly: its dependency dialog claims `libflac12`
  missing (true this time, not a t64 rename) and the binary dies at the
  dynamic linker before any window opens (`verification-log.md`, R113); the
  DBP bundles no libraries of its own to fall back on. Streets of Rage Remake
  5.1 (bennugd, 2021) hits the OpenSSL one with no dialog at all: its only
  declared dependency is installed, but all 52 of its binaries link
  `libcrypto.so.1.1` (`verification-log.md`, R115). A clean dialog is no more
  proof than a noisy one; run `ldd`.

A missing soname needs a DBP rebuilt against trixie, or a DBP that bundles its
libraries in its own `lib/`. `/etc/dbp/run_script` puts `$DBP_IMAGE_DIR/lib` on
`LD_LIBRARY_PATH`. Copying a buster `.so` into the system, or symlinking
`libGLEW.so.2.2` to `.so.2.1` (a workaround from the forum on bookworm), mixes
32-bit and 64-bit `time_t` callers, and the result fails silently. A buster
library kept in the package's own folder, used only by the old binary and
needing nothing but libc, keeps the old binary's ABI. Buster's `libfuse.so.2`
worked that way for the P* emulators, where trixie's `libfuse2t64` didn't. The
package image is read-only, but if the launcher puts `<union>/lib` on
`LD_LIBRARY_PATH`, the user can add a library to
`dragonbox/appdata/<id>/lib/` (see "Making them start" under the P* emulators).

## A DBP that needs GLX

Fix 4 turns GLX off, so a DBP that runs desktop GL without the `gl4es` wrapper
doesn't start at all (on bookworm it ran slowly). Start its launcher as
`gl4es /usr/local/games/<Exec>`: `dbp-run` passes the environment on (checked
2026-11-21 with Ice Field Frenzy). [gl4es.md](gl4es.md), "Programs that need
GLX", has the messages and the one game that needed more.

A DBP that bundles gl4es's `libGL.so.1` in its own `lib/` doesn't need the
wrapper. Heart of the Alien Redux 1.2.4.4 does this: its SDL2 window rendered
on the SGX through the bundled gl4es, `libEGL` and `libGLESv2`, with GLX off
(2026-11-26, `/proc/<pid>/maps`; `verification-log.md`, R119).

## DBPs that need your own game data

Many engine ports ship without the game: Heart of the Alien Redux wants the
Sega CD ISO, Streets of Rage Remake its `SorR.dat`. The data goes in the
package's appdata folder, `dragonbox/appdata/<Appdata>/` (the `.desktop`'s
`Appdata=` key, see above), which is the program's working directory when it
runs. Without the data, these get as far as loading it and stop, so only the
start-up can be checked. For Heart of the Alien that means libraries, SDL
video and audio init and the mixer opening, then
`panic: can't read GAME2.BIN file` (R119).

## SDL 1.2 games: which SDL, fullscreen, and the D-pad

An SDL 1.2 DBP gets one of two libraries. The card has ouzle's
`libsdl1.2pyra` as the system `libSDL-1.2.so.0`. Some packages bundle
sdl12-compat (SDL 1.2 on top of SDL2) and put it first on
`LD_LIBRARY_PATH`. `/proc/<pid>/maps` says which one a running game took.
Tested 2026-11-26 on kernel r4 (`verification-log.md`, R121):

| DBP (repo version) | SDL 1.2 it loads | Fullscreen window | Picture |
|---|---|---|---|
| OpenTyrian 1.0 (`OpenTyrian_C4ALL`) | its bundled sdl12-compat 1.2.61, under `gl4es`, drawn on the SGX | 1280x720+0+0 | 640x400 stretched to 1152x720, aspect kept, 64 px black bars left and right |
| Hostile Takeover 1.6.0.03 (`ptitSeb_ht`) | `libsdl1.2pyra` (declares it) | 1280x720+0+0 | native 1280x720, 1:1 |

Both start and run. What differs is scaling. `libsdl1.2pyra` puts a small
mode in the middle of the screen unscaled: OpenTyrian forced onto it showed
its 640x400 picture at 320,160 with a black border. sdl12-compat scales it up.
Hostile Takeover asks for the full 1280x720, so nothing needs scaling, and it
segfaults on sdl12-compat (both 1.2.61 and Debian's 1.2.68) at its first draw.
Keep it on `libsdl1.2pyra`.

**OpenTyrian starts windowed.** Its default is a 640x400 window. Turn on
fullscreen in its own menu (OpenTyrian → Toggle Fullscreen), or put
`{"video": {"fullscreen": true, "scaler": "Scale2x"}}` in
`~/.opentyrian/opentyrian.conf`. It keeps its settings there, in your home
folder, not in the package's appdata.

**The D-pad sends every press twice to a game that reads both the keyboard
and the joystick.** The input daemon reports a D-pad press on `pyraInput
keyboard` (an arrow key) and on `pyraInput Gamepad` (the hat) at once. In
OpenTyrian's menus, one press moved the highlight two items when started
without its launcher. That is OpenTyrian's own code: it turns the joystick
hat into key presses on top of the real key. Its launcher prevents it by
running `sudo pyrainputctl disable gamepad` before the game and `enable`
after (one press, one step, checked). Start it from the menu or
`/usr/local/games/opentyrian`, not by running `ot` directly. While it runs,
nothing arrives on the gamepad device. Hostile Takeover opens no joystick,
so each press arrives once with the gamepad left on. If OpenTyrian crashes,
the gamepad stays off: see "Input can stay remapped" below.

## Sound-heavy DBPs: Fasttracker 2 clone and Farox's demos

On bookworm the forum warned that these could crash the audio into loud noise
(https://pyra-handheld.com/boards/posts/1704299/,
https://pyra-handheld.com/boards/posts/1715481/). On the trixie card with
kernel r4 all four start and play clean through the speakers. The owner
listened at a low wheel setting through five runs of roughly two minutes each
(estimated from the session's timestamps) and heard no burst (2026-11-26;
`verification-log.md`, R122). Headphones were not tried.

| DBP (repo version) | GL path | Window and picture | Sound (PulseAudio stream) |
|---|---|---|---|
| ft2-clone 2.26 (`ft2-clone`, jedi23 2026) | GLES2 straight on the SGX: SDL2 over EGL, with its own `libpvrDRI3WSEGL.so`; no gl4es | 632x400 window by default; fullscreen 1280x720, picture stretched to fill the screen | `ft2-clone`, s16le 2ch 48 kHz; clean playing a module |
| Fiat Homo 1.0.0.2 (`fiathomo_farox`) | `gl4es` → SGX, SDL 1.2 (`libsdl1.2pyra`), bundled `libfmod.so.13` | fills the screen, no title bar (see below) | `FMOD Audio`, s16le 2ch 48 kHz; clean |
| Ante Dominum 1.0.0.2 (`antedominum_farox`) | as Fiat Homo, bundled `libfmod.so.10` | fills the screen | `FMOD Audio`, s16le 2ch 48 kHz; clean |
| Fit for Autopsy 1.0.0.2 (`autopsy_farox`) | `gl4es` → SGX, SDL 1.2 (`libsdl1.2pyra`), no fmod | menu: 300x480 decorated window; Boy: 4:3 picture, black bars left and right; Division by Zero fills the screen | each demo opens its own stream: Boy s16le 2ch 44.1 kHz, Division by Zero s16le mono 44.1 kHz; clean. The menu has none |

Fiat Homo and Ante Dominum are the two intros of the forum thread "Some Scene
Intro/demo by Traction". Of Fit for Autopsy's ten demos, only Boy and Division
by Zero were run.

**ft2-clone needs a restart to go fullscreen.** Alt+Enter, its documented
toggle, does nothing in this build. Tick Config → Miscellaneous → Fullscreen,
and it answers "This setting is not applied until you close and reopen the
program". It saves this in `~/.config/FT2 clone/FT2.CFG`, not in appdata. The
next start opens fullscreen. The picture then fills all of 1280x720 although
"Stretched" is off, so the pixels are not square (x 2.03, y 1.8). Windowed,
"Auto fit" stays at 1x: 2x would be 1264x800, taller than the screen. A module
given on the command line is loaded at start
(`/usr/local/games/run-ft2.sh song.xm`); Right Ctrl plays it. It used 46 % of
a core playing, with its default 8-point sinc interpolation (`top`, one
sample).

**The demos' X window and their picture disagree.** X reports Fiat Homo,
Ante Dominum and Fit for Autopsy's demos as a decorated 1280x720 window at
1,36 under a marco title bar, which would push the bottom 36 rows off the
screen. On the display the picture covers the whole screen with no title bar
(the owner looked; `xwd -root` agrees). Why was not looked into. The Autopsy
menu, a smaller window, is drawn exactly inside its client area.

**Quitting.** Escape quits ft2-clone (after a yes/no box), Fiat Homo, Ante
Dominum, and each Autopsy demo back to the menu. The Autopsy menu itself
ignores Escape. It was ended with SIGTERM here, which left its union mounted
(see the next section).

## ptitSeb's P* emulators: PSNes, PNes, PGen, PFBneo

**They don't start on trixie as shipped, but two buster libraries in each one's appdata folder fix that**
(below, "Making them start"). The repository's current builds are all build 03, 6.06.0.03 (ptitSeb,
2023-09-04): PSNes `repo/apps/199`, PNes `apps/198`, PGen `apps/197`, PFBneo `apps/195`. Each binary links two
libraries trixie doesn't give it, and the dynamic linker stops before any window opens:

    bin/psnes: error while loading shared libraries: libfuse.so.2: cannot open shared object file: No such file or directory

| Library the binary needs | On trixie | Effect |
|---|---|---|
| `libtinyxml2.so.6` (buster's `libtinyxml2-6a`) | gone: trixie has `libtinyxml2.so.11` (`libtinyxml2-11`, not installed) | new soname, `not found` |
| `libfuse.so.2` (`libfuse2`) | `libfuse2t64`, same soname, not installed | `not found`; installing it doesn't help (below) |
| `libGLEW.so.2.1`, `libcrypto.so.1.1` | gone (trixie has GLEW 2.2, OpenSSL 3) | bundled in the DBP's `lib/`, resolve |
| `libSDL2-2.0.so.0`, `libcurl.so.4`, `libminizip.so.1`, `libGL.so.1` | installed | resolve (`libGL` is gl4es's: the launcher runs `gl4es`) |

Build 03's "repacked for better compatibility" is the bundled `lib/` with GLEW 2.1 and OpenSSL 1.1, the two
libraries bookworm broke. It doesn't bundle tinyxml2 or fuse. The dependency dialog lists `libtinyxml2-6a,
libminizip1, libfuse2, libcurl4`. Two of those are t64 renames that are installed (`libminizip1t64`,
`libcurl4t64`). The other two really are missing.

**With the two libraries supplied, all four start to their menu.** This was a probe that changed nothing on the
system or in the packages. Buster's `libtinyxml2.so.6` (7.0.0) and `libfuse.so.2` (2.9.9) went in a scratch
folder, passed through `LD_LIBRARY_PATH` to `dbp-run`. Each emulator then opened a 1280x720+0+0 window
(`_NET_WM_STATE_FULLSCREEN`, no title bar) showing its game list. Rendering is SDL2's desktop GL through gl4es 1.1.7 on the SGX
(`GL renderer : GL4ES wrapper`; `/proc/<pid>/maps` has gl4es `libGL.so.1`, the SGX `libEGL`/`libGLESv2` and
`libpvrDRI3WSEGL.so`). That is the OpenGL 1.x backend ptitSeb built, so there are no shader filters
(https://pyra-handheld.com/boards/posts/1710015/). Idle in the menu each used about 18 % of a core (`top`, one sample) and
opened no audio stream. No ROM was loaded, so game speed and sound were not tested. Tested 2026-11-26
(`verification-log.md`, R123).

**Why `libfuse2t64` is not enough.** Each emulator mounts its own skin and data files with FUSE at
`/tmp/c2d_romfs` (`POSIXRomFs`). The binaries were built with a 32-bit `time_t`, and `libfuse2t64` uses a 64-bit one,
so the `struct stat` passed between them doesn't match. With trixie's `libfuse2t64` in the scratch folder in place of buster's, PSNes
opened its window. Every skin image read from the romfs failed (`stbi_load failed ... unknown image type`), the
screen stayed blank white and black, the main thread spun at 91 % of a core, and SIGTERM didn't stop it (SIGKILL
did). This is the silent t64 failure described above, seen for real. A working fix must carry buster's
`libfuse.so.2`, which matches the binary's ABI and needs only libc. Symlinking a newer tinyxml2 to `.so.6`, the
forum's bookworm workaround, was not tried.

**Menu keys** (`config.cfg`, as sent with `xsend`): arrows move, End is A (run), Return opens the per-ROM menu
(the forum's "BACK is Enter"), Escape opens Main Options. **QUIT → GO** is the last entry of Main Options (Up
from its top wraps to it), and End selects it. Up in the game list wraps to the last game, not to QUIT. Quitting this way unmounted the union and the romfs. ROMs go in
`dragonbox/appdata/<id>/roms/`, made on the first run along with `config.cfg`.

**A stale romfs after a crash clears itself.** After SIGKILL, `dbp-run` unmounted the union, but
`/tmp/c2d_romfs` stayed as a dead FUSE mount ("Transport endpoint is not connected"). The next P* emulator
started cleared it and mounted its own (PGen, checked). By hand: `fusermount -u /tmp/c2d_romfs`.

### Making them start

Each launcher (`psnes.sh`, `pnes.sh`, ...) puts `<union>/lib` first on `LD_LIBRARY_PATH`. The union is the
read-only image with `dragonbox/appdata/<id>/` as its writable branch. A file in `dragonbox/appdata/<id>/lib/`
therefore shows up in `<union>/lib` next to the image's own GLEW and OpenSSL, and only that emulator loads it.
`/etc/dbp/run_script`'s own `LD_LIBRARY_PATH` entry is the image's `lib/`, not the union's, so a package whose
launcher doesn't add `<union>/lib` itself won't see such files. None of the four sets `Appdata=`, so the folder is
the id: `psnes`, `pnes`, `pgen`, `pfbneo`.

`device/pyra-ptitseb-libs.sh` does all of this. Run it as the desktop user, not root, once the `.dbp` files are in
`dragonbox/packages/` and registered. It downloads the two debs from archive.debian.org and checks their
SHA-256s. Then it takes `libtinyxml2.so.6.2.0` and `libfuse.so.2.9.9` out, checks those too, and copies them into each
registered emulator's `appdata/<id>/lib/` under their sonames. `--check` shows what each one has, `--debs DIR` uses
debs you already fetched, and `--undo` removes the files again. By hand, for one emulator:

    cd /tmp
    wget https://archive.debian.org/debian/pool/main/t/tinyxml2/libtinyxml2-6a_7.0.0+dfsg-1_armhf.deb
    wget https://archive.debian.org/debian/pool/main/f/fuse/libfuse2_2.9.9-1+deb10u1_armhf.deb
    sha256sum lib*.deb
    #   e6e812f6d5d8ada7c73534c805b357f73e6aa009099c14ea654cea32bc106e8e  libtinyxml2-6a_7.0.0+dfsg-1_armhf.deb
    #   c0a8c4ab83d337bca5738da2a7df264962f4269778b93a2814923a4a3ebb303d  libfuse2_2.9.9-1+deb10u1_armhf.deb
    dpkg-deb -x libtinyxml2-6a_7.0.0+dfsg-1_armhf.deb x
    dpkg-deb -x libfuse2_2.9.9-1+deb10u1_armhf.deb x
    mkdir -p /dragonbox/appdata/psnes/lib
    cp x/usr/lib/arm-linux-gnueabihf/libtinyxml2.so.6.2.0 /dragonbox/appdata/psnes/lib/libtinyxml2.so.6
    cp x/lib/arm-linux-gnueabihf/libfuse.so.2.9.9 /dragonbox/appdata/psnes/lib/libfuse.so.2

For a package on a second card, the folder is `dragonbox/appdata/<id>/` on that card (`dbp-cmd getmount <id>` prints
its mount point). Nothing goes into `/usr/lib` and no package is installed. The libraries need only libc and
libstdc++.

**Where the two checksums come from.** They are the `SHA256:` lines of the two packages in buster's
`main/binary-armhf/Packages`, which buster's signed `InRelease` vouches for. Trixie still carries buster's release
key in `debian-archive-removed-keys.gpg`, so the whole chain can be checked on the Pyra:

    B=https://archive.debian.org/debian/dists/buster
    wget -q $B/InRelease $B/main/binary-armhf/Packages.xz
    gpgv --keyring /usr/share/keyrings/debian-archive-removed-keys.gpg InRelease
    #   Good signature from "Debian Stable Release Key (10/buster) <debian-release@lists.debian.org>"
    grep 'main/binary-armhf/Packages.xz$' InRelease | tail -1; sha256sum Packages.xz
    #   both b6dd3b4e38ad90b4d30330b27892761100d1c64439a4e3f7a384d3ec35cc110c
    xz -dc Packages.xz | grep -A20 -E '^Package: (libtinyxml2-6a|libfuse2)$' | grep -E '^(Package|Version|SHA256):'

The `grep ... | tail -1` takes the SHA256 section of `InRelease`, which is listed after the MD5 one. The extracted
libraries' SHA-256s, which the script also checks: `libtinyxml2.so.6.2.0`
`8c41daedc60746b9859b99fc214f2ac830de261bc61666bb5c07ea402498bd69`, `libfuse.so.2.9.9`
`eb638c364f53d0ee9e36e3290a6c4b4b5a0120dd1c8c3b613cd14edb3f8a08d3`.

**Starting them.** Applications → Emulators lists all four. `dbp-run` still shows its "One or more dependencies ...
missing" dialog each time, because it checks the declared deb names (`libtinyxml2-6a`, `libfuse2`, and the t64
renames `libminizip1`, `libcurl4`), not the libraries. Press **Launch anyway**. "Install missing dependencies" can't
help: `libtinyxml2-6a` isn't in trixie, and `libfuse2t64` is the library that breaks them. `dbp` has no setting to
skip the dialog. Tested 2026-11-26 on `5.6.19-m4-kbdled`: all four started from the menu to their game list with
buster's two libraries mapped from `<union>/lib` (`verification-log.md`, R124).

## DevilutionX (Diablo)

**It works on trixie as shipped.** The repository's current build is DevilutionX 1.5.2 (jedi23, 2024-02-08,
`repo/apps/250`, file `devilx.dbp`). Its binary links only SDL2, SDL2_image, libsodium23, zlib and bzip2, and trixie
has all of them, so `ldd` finds nothing missing. The launcher is one line, `gl4es ./devilutionx`: SDL2 desktop GL
through gl4es on the SGX. The `.desktop` has no `Appdata=` key, so the appdata folder is `dragonbox/appdata/DevilutionX/`.
Its `Dependency[deb]` line is commented out, so `dbp-run` shows no dependency dialog either.

**The game data** goes in that appdata folder: `DIABDAT.MPQ` from the original game, and for Hellfire also
`hellfire.mpq`, `hfmonk.mpq`, `hfmusic.mpq` and `hfvoice.mpq`. The shareware `spawn.mpq` (25 448 219 bytes, from
the DevilutionX project's `devilutionx-assets` release) works too, and lets you check a card without the game.
With no data, the game opens fullscreen and shows "Data File Error: Unable to open main data archive (diabdat.mpq or
spawn.mpq)". Press OK and it exits. **Saves and `diablo.ini` aren't kept in appdata.** They go to
`~/.local/share/diasurgical/devilution/` on the system card, so removing the package leaves them behind.

Tested 2026-11-26 on `5.6.19-m4-kbdled` (`verification-log.md`, R126). From Applications → Games → Adventure and RPG,
it opened a 1280x720+0+0 window (`_NET_WM_STATE_FULLSCREEN`) with gl4es `libGL.so.1`, the SGX `libGLESv2` and
`libpvrDRI3WSEGL.so` mapped. The intro played with a 22 050 Hz PulseAudio stream open. The shareware game reached
Tristram, where a click walked the hero, and Quit Game exited cleanly and unmounted the union. In town it used about
65 % of one core (`top`).

**The forum's black screen at start didn't show up** in seven starts with the pyrainput mouse on, which is the default.
The poster got past it with an external mouse and a restart, and suggested the launcher should run
`sudo pyrainputctl disable mouse` before the game and `enable mouse` after, so the nubs act only as analog sticks.
The 1.5.2 launcher does neither. Not tested: the nubs (how fast the right nub moves the cursor, and the
deadzone), and the gamepad, because nobody was at the device.

## When a program is killed or crashes

- **The mount can be left behind.** `dbp-run` unmounts when the program exits
  normally. If `dbp-run` itself is killed, the union and the image stay mounted
  (seen 2026-11-21 after a `timeout`). Killing only the program can do it too:
  after SIGTERM to Fit for Autopsy's menu, `dbp-run` exited and left the union
  and its image mounted, the image twice (2026-11-26; one of the two may come
  from hand mounts earlier in that session). Check with `findmnt -t aufs,squashfs`.
  Remove them with
  `sudo umount /mnt/dbp/union/<id> /mnt/dbp/images/<id>`, repeating the image
  path until `findmnt` no longer lists it. The two empty
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
trixie once `python3-apt` is installed. Prep installs it (fix 32); on a card
prepared before that, `sudo apt install python3-apt`. Tested 2026-11-23 with
python3-apt 3.0.0 installed by hand. It bundles a
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
and nothing registers, even after a `dbpd` restart (tested 2026-11-23). Prep
(fix 32) points `~/dragonbox` at `/dragonbox`, the system card's folder, which
it makes and gives to the user, so on a prepared card RootFs works. It leaves
a `~/dragonbox` that already holds files alone, and only the user it sets up
gets the link. Otherwise, choose a second card (anything mounted under
`/media`), or make the link once:

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
