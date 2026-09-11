# Reproducing this exact machine

`procedure.md` gets you a booting trixie desktop. This document goes further:
it gets you the state this repository actually describes, with the patched
kernel and every helper in place, and says how to check that you got there.

Read `procedure.md` first if you have never done the card part. This is the
spine, and it points at the other documents rather than repeating them.

---

## What the end state is

| Part | What it is | Where it comes from |
| --- | --- | --- |
| Rootfs | The Pyra project's trixie image, grown onto the whole card | `procedure.md` sections 1 to 3 |
| Five fixes | Xorg, first-run wizard, nubs, GLX, USB hub | `pc/pyra-trixie-prep.sh`, applied offline |
| Kernel | `5.6.19-fix`: the stock pyradef source, a lockup detector, and the four patches | `pc/pyra-crossbuild.sh kernel-fix` |
| X display driver | **Stock**, unmodified, from the Pyra repository | nothing to build |
| Helpers | Boot selector, kernel installer, suspend test, hang trap, idle dimmer, profilers | `device/pyra-install-helpers.sh` |
| Capture settings | `kernel.sysrq = 446` and all-CPU backtraces | installed with the helpers |

**The display driver is not rebuilt and does not need to be.** This is worth
stating plainly because the repository does contain a way to build it, and
that is easy to mistake for a step. `pc/pyra-crossbuild.sh ddx` compiles
`xserver-xorg-video-armsoc-omap5` from source in a container, and it works,
but nothing here patches it and the machine runs the distribution package. The
build target exists for future work above the ioctl layer, such as
instrumenting the modeset. The fix this project made for the display driver is
a configuration change, fix 4, which disables the GLX extension and is applied
to the card by the prep script.

---

## The path

### 1. Get a working desktop

Follow `procedure.md` sections 0 to 6. At the end of it the machine boots to
MATE, the rootfs fills the card, and the five fixes are in place. Do not
continue until section 6 passes.

Optional, and much easier done now than later: `procedure.md` section 7 sets
the card up for development, with your SSH key authorised, sudo without a
password and no login prompt. Do it while the card is still in the reader.

### 2. Build the patched kernel, on the PC

    ./pc/pyra-crossbuild.sh kernel-fix

Roughly ten minutes on a modern machine, most of it the first container pull.
It cross-compiles in a throwaway Debian container, so nothing is installed on
your host beyond the image, and the Pyra is not involved. The output is
`~/git/dragonbox-pyra-build/kernel/fix-kernel.tar.gz`.

The build prints each patch as it applies it. All four must say `applied` or
`already`; a patch that will not apply stops the build rather than producing a
kernel that is missing a fix it claims to have. `building.md` has what each
patch does and why.

### 3. Copy it and the repository across, and install it

The kernel installer lives in this repository, so send both in one go:

    scp ~/git/dragonbox-pyra-build/kernel/fix-kernel.tar.gz pyra@<address>:
    rsync -a device patches pyra@<address>:dragonbox-pyra/

    ssh pyra@<address>
    sudo ./dragonbox-pyra/device/pyra-install-debug-kernel.sh fix-kernel.tar.gz

It refuses rather than guesses: a tarball that would destroy the `/lib`
symlink, too little space in `/boot`, a boot configuration it did not write.
It never touches the stock kernel, which stays installed and bootable.

Then choose it. There is no boot menu on this machine, because U-Boot here has
no display driver, so the choice is made from Linux before rebooting:

    sudo pyra-boot-kernel.sh debug --once     # one boot, then back to stock
    sudo systemctl reboot

`--once` arms a service that runs before anything else and puts the default
back, so a kernel that never reaches userspace costs one power cycle and
nothing else. Once you are satisfied, make it permanent:

    sudo pyra-boot-kernel.sh debug

### 4. Install the helpers

The repository is already on the device from step 3, so this is one command:

    cd dragonbox-pyra/device
    sudo ./pyra-install-helpers.sh

It puts the scripts on `$PATH`, installs the sysrq settings, and enables the
idle dimmer for the user who invoked it. `--dry-run` says what it would change
and `--list` says where each file goes. Run it again after a `git pull`.

### 5. Turn sleep back on

The workaround for suspend hanging was to refuse the operation outright. The
kernel fix makes that unnecessary:

    sudo systemctl unmask sleep.target suspend.target hybrid-sleep.target \
                          suspend-then-hibernate.target hibernate.target

---

## Checking you got there

Each of these covers one of the faults in the README, and each has a
specific thing to look at.

**The kernel is the patched one.**

    uname -r                                     # 5.6.19-fix
    sudo pyra-boot-kernel.sh status              # and it is what boots next

**The phantom SD hosts are gone.** This is `patches/0003`. Six hosts become
four, and all four are real controllers:

    ls /sys/class/mmc_host/                      # mmc0 to mmc3, no mmc4 or mmc5
    ps -eo stat,comm | awk '$1 ~ /^D/'           # nothing at all
    cat /sys/devices/platform/txs02612/switch    # still works: eMMC

Nothing should be in uninterruptible sleep. On the stock kernel two rescan
workers are stuck there from boot, which is what blocked suspend and what held
the load average at 2.0.

**Suspend works.**

    sudo pyra-sleep-test.sh

It arms the real-time clock so the machine wakes itself, tries suspend-to-idle
first and only then suspend to RAM, and checks afterwards that the desktop
session was thawed rather than left frozen.

**Resume is quiet.** This is `patches/0004`. Waking the machine used to storm
the PMIC's interrupt for as long as the resume took, hundreds to thousands of
log lines per wake. Count the hardware deliveries across one suspend rather
than the log lines:

    awk '/ palmas$/{print $2+$3}' /proc/interrupts

It should move by about two. Before the patch the same wake moved it by 233.
`dmesg` should hold no `Failed to read IRQ status` at all.

**The display patch cannot be checked this way.** It is a bound on two loops
that should never be reached, so a healthy machine looks identical with and
without it. What confirms it is the hang not happening, or this line appearing
instead of a hang:

    sudo dmesg | grep "rx fifo will not drain"

If the display does wedge anyway, take a backtrace *before* rebooting. The
machine stays reachable over SSH, and this is the only moment the stack can be
read. The kernel's own lockup detector will not do it for you, for reasons in
`troubleshooting.md`:

    for i in 1 2 3; do echo l | sudo tee /proc/sysrq-trigger; sleep 1; done
    sudo dmesg | tail -120

---

## How reproducible this really is

Honest limits, so that a rebuild that differs is not a mystery.

**Pinned.** The kernel and driver sources are fetched by `.dsc` file and the
`.dsc` hashes are pinned in `pc/pyra-crossbuild.sh`. `dpkg-source` verifies
the tarballs against the `.dsc` when it unpacks, so pinning the `.dsc` pins
the source. The patches are in the repository and are checked before use.

**Not pinned.** The containers are `debian:bookworm` and `debian:trixie`, which
are moving tags. A build six months from now gets whatever compiler and
toolchain those tags point at then. Bookworm is used for the kernel
deliberately, because 5.6 does not build with gcc 14 and bookworm's gcc 12 is
what upstream used, but the exact point release is not fixed. Pin the digest
if you need a byte-identical rebuild.

**Also not pinned.** The rootfs image is whatever is at the Pyra project's
download URL, and the packages installed on first boot come from that
project's apt repository. Neither is under this repository's control.

**Not captured at all.** The eMMC bookworm install, which is left untouched as
a recovery path, and anything you install into the desktop afterwards.
