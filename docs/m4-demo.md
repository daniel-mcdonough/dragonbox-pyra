# Running the Pyra's two Cortex-M4s yourself

> **Type: instructions.** Steps to follow.

The OMAP5432 in the Pyra has two Cortex-M4 cores, called the IPU, that nothing
on the stock system ever starts. This demo starts them under Linux
`remoteproc`, shows both of them running code, measures their clock speed, and
leaves the machine the way it was.

It is a demonstration that the cores work, not an application. Nothing here
makes games or the desktop faster, and `docs/m4-ipu.md` explains why the M4s
are unlikely ever to. What it does show is the whole path working on Pyra
hardware: device tree, IOMMU, carveout memory, firmware loading and both cores
coming out of reset.

Everything it needs is in this repository: the kernel patches
(`experiments/m4-ipu/`), the firmware source (`experiments/m4-ipu/firmware/`)
and the device scripts (`device/pyra-m4-*.sh`).

**Status.** First booted on a V5.3 unit on 2026-09-20 (`docs/m4-ipu.md`).
**Run end to end on that unit on 2026-10-18**, on both kernels that carry the
M4 work: the shipped `5.6.19-m4-kbdled` and the M4-only `5.6.19-m4demo`. On
each, `pyra-m4-demo.sh` gave 13 ok, 0 failed, with **both cores measured at
212.8 to 212.9 MHz**. On `5.6.19-m4demo`, `pyra-m4-check.sh` also gave 13 ok
and `pyra-m4-run.sh` 11 ok, both with 0 failed. The logs are in
`experiments/m4-ipu/results/`. **One unit so far.** Results from another unit
are the most useful thing you can add (see "If you post results").

---

## What you will see

`sudo ./pyra-m4-demo.sh` goes through four steps. From the 2026-10-18 run,
trimmed:

    | pyra-m4-hello: running on the OMAP5432 IPU (2 x Cortex-M4)
    | core0: state=alive beats=0000000001
    | core1: state=alive beats=0000000001
    | core0 clock-src=systick dwt-ctrl=0x4f000000 dwt-fault=0 systick=0x00000005
    | core1 clock-src=systick dwt-ctrl=0x4f000000 dwt-fault=0 systick=0x00000005

    == live, 15s ==
           t   core0-beats        MHz   core1-beats        MHz
          1s    0000000001      213.8    0000000001      214.2
          2s    0000000002      213.1    0000000002      212.5
          ...
         15s    0000000011      212.6    0000000011      211.9

      ok    core0: 212.8 MHz, core clock, from SysTick (15 one-second samples, median 213.0)
      ok    core1: 212.8 MHz, core clock, from SysTick (15 one-second samples, median 212.5)
      ok    a fresh count: .bss was zeroed by the loader and an M4 started over
      ok    no IOMMU fault
      ok    no BUG or WARNING
    13 ok, 0 failed

The beats are slow, about one every 1.4 s, on purpose. The firmware runs
uncached straight from DDR, which is slow on this hardware (see `docs/m4-ipu.md`).

1. **Live.** For ten seconds (`--seconds N` for longer) it prints both cores'
   heartbeat counters and each core's clock speed. The speed comes from each
   M4 counting its own clock in SysTick, sampled against Linux's clock.
2. **Stop.** The IPU goes offline and its trace buffer disappears.
3. **Start again.** The counters begin again from near zero.
4. **Kernel log.** It checks for IOMMU faults, `BUG`s and `WARNING`s over the
   whole run.

Why this is evidence rather than a script printing numbers:

- **The text was written by an M4.** The buffer lives in the firmware's
  `.bss`, so it is not in the firmware file at all. The kernel's loader zeroes
  it on every start, so every byte in it came from a running core.
- **Both cores are running.** `core1`'s line is only ever written by the second
  core.
- **They keep running.** The counters advance between samples. A core that
  wrote one line and crashed would show a frozen number.
- **The clock speed is measured, not looked up.** Linux's clock tree reports a
  425.472 MHz gate clock for the IPU. The cores measure 212.8 MHz, exactly half,
  which is also TI's documented figure. The script checks that two independent
  estimates agree within 2% before it reports a number.

---

## What you need

- A **Pyra** running the **Debian 13 (trixie) card image** from
  `packages.pyra-handheld.com/images/trixie/`. Tested on a V5.3 mainboard.
  Other mainboards have not been tried.
- A **GP** (general purpose) SoC, which retail Pyras are. Check it with:

      cat /sys/bus/soc/devices/soc0/type        # must say GP

  On an HS part the firmware would have to be signed by TI and none of this
  works.
- A kernel with the M4 work in it. Which route you take depends on what the
  card runs now:

      uname -r

  | `uname -r` says | route |
  | --- | --- |
  | `5.6.19-m4-kbdled` | **A.** The shipped kernel already has it. Nothing to install. |
  | `5.6.19-pyradef` (stock) | **B.** Build `5.6.19-m4demo` and boot it once. |

- On the PC: this repository and `arm-none-eabi-gcc` (Debian/Ubuntu:
  `gcc-arm-none-eabi`; Arch: `arm-none-eabi-gcc`).
  Route B also needs Docker for the kernel build.

---

## Before you start: what this changes and how to undo it

Read this part even if you skip everything else.

- **Never leave the firmware in `/lib/firmware`.** Once `omap_remoteproc` is
  loaded, the kernel starts the M4s by itself whenever `omap5-ipu-fw.xem4` is
  there, at every boot. Both scripts remove it on exit, however they exit.
  Every install path in this repository (`pyra-trixie-prep.sh`,
  `pyra-install-debug-kernel.sh`) also writes
  `/etc/modprobe.d/pyra-m4-noautoboot.conf`, which stops `omap_remoteproc`
  loading at boot. The scripts load it themselves when you run them, and it
  stays loaded until the next boot.
- **Route A changes nothing else.** It runs on the kernel you already boot.
- **Route B adds one kernel, `5.6.19-m4demo`, beside the stock one.** The stock
  kernel, its modules and its boot entry are not touched. The new kernel gets
  the `l1` test slot in `/boot/extlinux/user.cfg`. **If you already have a
  test kernel in `l1`, its entry is replaced** (its files stay on disk), so
  save `user.cfg` first. The installer needs about **47 MB free in `/boot`**
  and 41 MB in `/usr`, checks both, and stops before changing anything if
  either is short. Kernels that no boot entry points at still keep their files
  in `/boot`.
- **The Pyra has no boot menu you can see.** U-Boot has no display driver, so
  the menu exists only on the serial console. To boot a test kernel you make it
  the default, and `pyra-boot-kernel.sh debug --once` arms a service that puts
  the default back early in the following boot. A test kernel that boots
  therefore gets exactly one boot.
- **If the new kernel does not boot at all**, nothing on the device can fix
  it. Put the SD card in a PC and change the `default l1` line in
  `/boot/extlinux/extlinux.conf` back to what it was (`default l0` on a
  stock image).
- `5.6.19-m4demo` carries **only** the general fixes in `patches/` and the four
  M4 patches. It does not carry the AESS audio work, the GPU idle-power fix or
  the extra frequency steps that the shipped `5.6.19-m4-kbdled` has. While
  it runs, audio and CPU frequencies behave as they do on stock.

---

## Steps

### On the PC: build the firmware and copy it over

From the top of this repository:

    make -C experiments/m4-ipu/firmware all demo
    ./pc/pyra-m4-verify.sh --patches        # optional: the patch set and firmware still say what docs/m4-ipu.md claims

    ssh pyra@<address> mkdir -p pyra-m4
    scp device/pyra-m4-check.sh device/pyra-m4-demo.sh device/pyra-m4-run.sh \
        experiments/m4-ipu/firmware/pyra-m4-demo.xem4 \
        experiments/m4-ipu/firmware/omap5-ipu-fw.xem4 \
        pyra@<address>:pyra-m4/

`pyra-m4-demo.xem4` is the one with the clock measurement. `omap5-ipu-fw.xem4`
is the plain heartbeat, for the strict test. Each is about a kilobyte, built
from a few hundred lines of C and assembly with no TI toolchain.

### Route B only: boot the M4 kernel once

Skip this on `5.6.19-m4-kbdled`. On the PC (about ten minutes):

    ./pc/pyra-crossbuild.sh kernel-m4demo
    ./pc/pyra-push-kernel.sh --install \
        --tarball ../dragonbox-pyra-build/kernel/m4demo-kernel.tar.gz pyra@<address>

`pyra-push-kernel.sh` copies `device/` to `~/dragonbox-pyra/` on the Pyra and
installs the kernel into `l1`. It does not make it the default. On the Pyra:

    sudo install -m 0755 ~/dragonbox-pyra/device/pyra-boot-kernel.sh /usr/local/sbin/   # once; the revert service runs it from there
    sudo pyra-boot-kernel.sh debug --once
    sudo pyra-boot-kernel.sh status    # "next boot: l1", "one-shot revert: enabled"
    sudo systemctl reboot

After it comes back, `uname -r` should say `5.6.19-m4demo`. The reboot after
that returns to the stock kernel on its own.

### On the Pyra: run it

    cd ~/pyra-m4
    ./pyra-m4-check.sh --modprobe      # read-only; expect two remoteproc devices, both offline
    sudo ./pyra-m4-demo.sh | tee m4-demo.log

and, for the strict version of the test, using the plain heartbeat firmware:

    sudo ./pyra-m4-run.sh omap5-ipu-fw.xem4

`pyra-m4-check.sh --modprobe` is safe because the firmware is not in
`/lib/firmware`: loading the module with no firmware starts nothing.

**If you post results**, please include `m4-demo.log`, the output of
`cat /sys/bus/soc/devices/soc0/*` and your mainboard version. A second unit's
clock measurement is worth more than the first.

### Removing it

Route A leaves nothing behind but `~/pyra-m4`. For route B, also:

    sudo pyra-boot-kernel.sh stock
    sudo sed -i '/^label l1$/,/^label /{/^label l1$/d;/^label /!d}' /boot/extlinux/user.cfg
    sudo rm -rf /boot/{vmlinuz,initrd.img,System.map,config}-5.6.19-m4demo \
                /boot/dtb/linux-image-5.6.19-m4demo /usr/lib/modules/5.6.19-m4demo

---

## If something goes wrong

| what you see | what it means |
| --- | --- |
| `no ipu remoteproc device` | Not running a kernel with the M4 work (check `uname -r` against the table above), or the `modprobe omap_remoteproc` the script runs failed (its error is printed above). The blacklist does not cause this: it stops only the load at boot. |
| `writing 'start' failed`, `-EBUSY` in dmesg | Something asked for a hardware timer the backlight owns. This repository's device tree deliberately gives the IPU none. If you edited it, see "The one Pyra-specific trap" in `docs/m4-ipu.md`. |
| `core1 never ran` / `did not advance` | Only one M4 left reset. Please post the log; this has not been seen. |
| `state=FAULT` | The firmware took a fault. Please post the log and `dmesg`. |
| `clock-src=none` | Neither the DWT cycle counter nor SysTick worked on your M4s. The heartbeat is still the proof they run, and the clock is simply not measured. Please post the `clock-src` line. |
| `clock-src=dwt` | Your M4s have a DWT cycle counter, unlike the unit this was developed on. Please post it. |
| `the count stood still` or `disagree by more than 2%` | The clock reading was not trustworthy, so no figure is reported. Run again with `--seconds 30`. If it persists, post the log. |
| `BUG: scheduling while atomic` | The kernel is missing `0012`. Both kernels built here have it, so you are on a different one. |
| `/lib/firmware/omap5-ipu-fw.xem4 already exists` | Left behind by something else. `sudo ./pyra-m4-run.sh --stop` removes it. |

---

## A standalone kit, for someone without the repository

`pc/pyra-m4-demo-kit.sh` packs route B into one tarball: the `5.6.19-m4demo`
kernel, both firmwares, the device scripts and this file as its README. Because
it ships a kernel binary, it also ships what that binary was built from: every
patch in the order applied, the exact `.config`, and the upstream source
package name and checksum. It refuses to finish if anything in it names the
person who built it.

    ./pc/pyra-crossbuild.sh kernel-m4demo
    ./pc/pyra-m4-demo-kit.sh             # ../dragonbox-pyra-build/m4-demo-kit/pyra-m4-demo-<date>.tar.gz

Rebuild the kit after any change to the scripts or this file. A kit only
carries the versions it was built from.

---

## What this does not do yet

The M4s run, but they cannot talk to Linux yet. There is no mailbox or rpmsg
in this firmware, so Linux can only read what the cores write. A two-way
channel, where Linux sends work and an M4 answers, is the next step, and it is
where any useful firmware would have to start. `docs/m4-ipu.md` covers the
routes from here, including TI's own IPC stack and the hardware video decoder.
