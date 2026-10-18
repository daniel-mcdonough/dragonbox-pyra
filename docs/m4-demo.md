# Running the Pyra's two Cortex-M4s yourself

The OMAP5432 in the Pyra has two Cortex-M4 cores, called the IPU, that nothing
on the shipped system ever starts. This kit starts them under Linux
`remoteproc`, shows both of them running code, measures their clock speed, and
leaves the machine the way it was.

It is a demonstration that the cores work, not an application. Nothing here
makes games or the desktop faster, and `docs/m4-ipu.md` explains why the M4s
are unlikely ever to. What it does show is the whole path working on Pyra
hardware: device tree, IOMMU, carveout memory, firmware loading and both cores
coming out of reset.

**Status.** The kernel changes and the heartbeat firmware were first booted on
a V5.3 unit on 2026-09-20 (`docs/m4-ipu.md`). The `5.6.19-m4demo` kernel and
the cycle-counter firmware in this kit are newer builds of the same work, and
the output below is a sample of what the demo prints, not a recorded run.

---

## What you will see

`sudo ./pyra-m4-demo.sh` goes through four steps. The core boot lines it prints
first look like this:

    pyra-m4-hello: running on the OMAP5432 IPU (2 x Cortex-M4)
    core0: state=alive beats=0000000004
    core1: state=alive beats=0000000004
    mode: demo, DWT cycle counter per core
    core0 cpu-cycles=0001234567
    core1 cpu-cycles=0001233210

1. **Live.** For ten seconds it prints both cores' heartbeat counters and each
   core's clock speed. The speed comes from the M4's own cycle counter (DWT
   `CYCCNT`) sampled against Linux's clock.
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
  425 MHz gate clock for the IPU, while TI documents roughly half that for the
  cores. The cycle counter settles which is right on your unit.

---

## What you need

- A **Pyra** running the **Debian 13 (trixie) card image** from
  `packages.pyra-handheld.com/images/trixie/`, set up per this repository's
  `docs/procedure.md`. The kernel here is built from that image's own kernel
  source (`5.6.19-pyradef`) and installs **beside** it.
  Tested on a V5.3 mainboard. Other mainboards have not been tried.
- A **GP** (general purpose) SoC, which retail Pyras are. Check it with:

      cat /sys/bus/soc/devices/soc0/type        # must say GP

  On an HS part the firmware would have to be signed by TI and none of this
  works.
- SSH or a terminal on the Pyra, and about 60 MB free across `/boot` and `/usr` (the kernel stages at 57 MB).

---

## Before you start: what this changes and how to undo it

Read this part even if you skip everything else.

- **One new kernel, `5.6.19-m4demo`, beside the stock one.** The stock kernel,
  its modules and its boot entry are not touched. The new kernel gets the
  `l1` test slot in `/boot/extlinux/user.cfg`. **If you already have a test
  kernel in `l1`, its entry is replaced** (its files stay on disk), so save
  `user.cfg` first.
- **The Pyra has no boot menu you can see.** U-Boot has no display driver, so
  the menu exists only on the serial console. To boot a test kernel you make it
  the default, and `pyra-boot-kernel.sh debug --once` arms a service that puts
  the default back early in the following boot. A kernel that boots therefore
  gets exactly one boot.
- **If the new kernel does not boot at all**, nothing on the device can fix
  it. Put the SD card in a PC and change the `default l1` line in
  `/boot/extlinux/extlinux.conf` back to what it was (`default l0` on a
  stock image).
- **Never leave the firmware in `/lib/firmware`.** The kernel starts the M4s
  automatically whenever `omap5-ipu-fw.xem4` is there, at every boot. Both
  scripts remove it on exit, however they exit. If you ever need to stop that
  happening, add `modprobe.blacklist=omap_remoteproc` to the kernel command
  line.
- The kernel carries **only** this repository's general fixes (`patches/`) and
  the four M4 patches. It does not carry the AESS audio work or the
  frequency-table changes that this project's everyday `5.6.19-m4` kernel
  has. Your audio and CPU frequencies behave as they do on stock.

---

## Steps

On the Pyra, in the unpacked kit:

    sha256sum -c SHA256SUMS

    # once: the one-boot revert service runs the script from here
    sudo install -m 0755 pyra-boot-kernel.sh /usr/local/sbin/

    sudo ./pyra-m4-check.sh            # read-only; safe on the stock kernel
    sudo ./pyra-install-debug-kernel.sh m4demo-kernel.tar.gz
    sudo pyra-boot-kernel.sh debug --once
    sudo pyra-boot-kernel.sh status    # "next boot: l1", "one-shot revert: enabled"
    sudo systemctl reboot

After it comes back:

    uname -r                           # 5.6.19-m4demo
    sudo ./pyra-m4-check.sh            # expect two remoteproc devices, both offline
    sudo ./pyra-m4-demo.sh | tee m4-demo.log

and, for the strict version of the test, using the plain heartbeat firmware:

    sudo ./pyra-m4-run.sh firmware/omap5-ipu-fw.xem4

The next reboot returns to the stock kernel on its own. To run the demo again
later, use `sudo pyra-boot-kernel.sh debug --once` and reboot.

**If you post results**, please include `m4-demo.log`, the output of
`cat /sys/bus/soc/devices/soc0/*` and your mainboard version. A second unit's
clock measurement is worth more than the first.

### Removing it

    sudo pyra-boot-kernel.sh stock
    sudo sed -i '/^label l1$/,/^label /{/^label l1$/d;/^label /!d}' /boot/extlinux/user.cfg
    sudo rm -rf /boot/{vmlinuz,initrd.img,System.map,config}-5.6.19-m4demo \
                /boot/dtb/linux-image-5.6.19-m4demo /usr/lib/modules/5.6.19-m4demo

---

## If something goes wrong

| what you see | what it means |
| --- | --- |
| `no ipu remoteproc device` | Not running `5.6.19-m4demo` (check `uname -r`), or `omap_remoteproc` is blacklisted. |
| `writing 'start' failed`, `-EBUSY` in dmesg | Something asked for a hardware timer the backlight owns. The kit's device tree deliberately gives the IPU none. If you edited it, see "The one Pyra-specific trap" in `docs/m4-ipu.md`. |
| `core1 never ran` / `did not advance` | Only one M4 left reset. Please post the log; this has not been seen. |
| `state=FAULT` | The firmware took a fault. Please post the log and `dmesg`. |
| `no-dwt` instead of cycle counts | Your M4s report no cycle counter. The heartbeat is still the proof they run, and the clock is simply not measured. |
| `BUG: scheduling while atomic` | The kernel is missing `0012`. This kit's kernel has it, so you are on a different one. |
| `/lib/firmware/omap5-ipu-fw.xem4 already exists` | Left behind by something else. `sudo ./pyra-m4-run.sh --stop` removes it. |

---

## Building it yourself

Everything in the kit can be rebuilt from this repository on a Linux PC with
Docker and `arm-none-eabi-gcc`:

    ./pc/pyra-crossbuild.sh kernel-m4demo        # the kernel, in a bookworm container
    make -C experiments/m4-ipu/firmware all demo # both firmwares
    ./pc/pyra-m4-demo-kit.sh                     # the kit itself

The kit's `kernel-source/` holds what the kernel binary was built from: every
patch in the order it was applied, the exact `.config`, and the upstream
source package name and checksum. `firmware-source/` is the firmware, about a
few hundred lines of C and assembly, about a kilobyte compiled, with no TI toolchain involved.

---

## What this does not do yet

The M4s run, but they cannot talk to Linux yet. There is no mailbox or rpmsg
in this firmware, so Linux can only read what the cores write. A two-way
channel, where Linux sends work and an M4 answers, is the next step, and it is
where any useful firmware would have to start. `docs/m4-ipu.md` covers the
routes from here, including TI's own IPC stack and the hardware video decoder.
