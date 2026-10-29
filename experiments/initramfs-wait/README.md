# Why root sometimes mounts a minute or two late

The findings live in `docs/troubleshooting.md`, "Root mounts a minute or two
late". This directory holds the tools used to chase them. Shape A's cause is a
5.6 kernel bug, fixed in m4-kbdled by `patches/0048` (see "The fix" below). The
workaround for the other kernels is
`device/etc/initramfs-tools/scripts/init-top/pyra-settle-nudge`.

## `pyra-settle-diag`

An initramfs-tools `init-top` hook. It runs before `init-top/udev`, starts a
background watcher and returns. If the initramfs is still running 15 s after
boot, and again at 30, 60 and 100 s, the watcher records the following in
`/run/initramfs/settle-diag.txt`:

- pending sysfs firmware fallbacks (`/sys/class/firmware`)
- the udev run directory
- every process's state, parent, wchan and command line
- the open fds of `systemd-udevd` and `udevadm`, the `fdinfo` of their epoll
  and inotify fds (which fds are watched, and which inode an inotify watch is
  on), `/proc/net/unix`, and the inode number of `/run/udev`

A second watcher writes `/run/initramfs/settle-timeline.txt`. It polls every
0.2 s and adds a line, with the uptime, each time `/run/udev/queue` appears
or goes or `udevadm settle` exits, so every boot leaves a timeline. After the
15 s snapshot, if settle is still running and the queue file is absent, the
hook creates and deletes `/run/udev/.pyra-settle-poke` once and logs it as
`poke`.

It also writes a `pyra-settle-diag` marker to the kernel log and triggers
SysRq-T, so every task's kernel stack ends up in the journal. Around the SysRq
write it turns `printk.ignore_loglevel` off and sets the console loglevel to 1,
then restores both, so the dump goes only to the ring buffer. A dump printed to
the consoles once froze a boot. It also holds `rcu_read_lock()` for as long as it
prints, which stalls the root mount's `rcu_barrier()`. `/proc/<pid>/stack`
is empty for other tasks on this SMP ARM kernel, which is why the hook uses
SysRq-T. On a normal boot the hook only writes its `armed at uptime` line.

Install (on the card, for one kernel):

    sudo install -m 755 pyra-settle-diag /etc/initramfs-tools/scripts/init-top/
    sudo update-initramfs -u -k 5.6.19-m4-kbdled

Remove it by deleting the file and running `update-initramfs` again.

## State on 2026-10-28

Installed on the trixie card for `5.6.19-m4-kbdled` only, beside the fix
`pyra-fw-nofallback`. The previous initrd is
kept beside it as `initrd.img-5.6.19-m4-kbdled.before-r16`. Dry run on the live
system: the snapshot is written as intended. Four warm reboots with the hook in
place mounted root at 7.6, 9.5, 6.5 and 6.3 s, so the slow warm-reboot shape
has not been caught yet. Left installed so that daily use catches it.

Later the same day, a warm reboot spent 16.6 s silent in the initramfs (root at
23.4 s), below the 40 s first sample, so the samples moved to 15, 30, 60 and
100 s and the card's initramfs was rebuilt with that version.

Later still: a sample caught at 15 s froze the boot for good during its
SysRq-T dump, which then went to fbcon and serial (`ignore_loglevel`). The
hook now keeps the dump off the consoles. Live, one SysRq-T write took 5.28 s
before that change and 0.03 s after it. The card's m4-kbdled initramfs was
rebuilt with it. `.before-r16` is still the fallback.

Then a full shape A was caught (root at 126.2 s): all four samples ran, the boot
finished, and the dumps were in the journal only. The samples are in
`settle-diag-2026-10-28-shapeA.txt`. udev's queue was empty throughout, and
`udevadm settle` was still waiting for udevd to answer its PING (see
`docs/troubleshooting.md`). The fd and unix-socket capture was added after that
and installed the same way.

## State on 2026-10-29

The fdinfo, timeline and poke parts were added and installed the same way.
Seven warm reboots into l5, each after 11 min or more up (the first before the
fdinfo part was installed):

- One caught at 26.6 s (`settle-diag-2026-10-29-30s.txt`, fds and epoll fdinfo
  only, before the timeline existed). `udevadm settle` had no control socket
  open, so it was past the PING. It was waiting on inotify with the queue file
  already gone.
- One at 16.7 s (`settle-diag-2026-10-29-poke.txt`, with the timeline at the
  end). The queue file was gone by 6.86 s, settle stayed, and the poke at
  15.79 s freed it by 15.84 s.
- Five fast ones: root at 9.3, 10.9, 9.6, 9.7 and 9.4 s (journal monotonic
  column, which runs slightly later than the kernel's own stamp).

So the PING conclusion of 2026-10-28 was wrong, and
`docs/troubleshooting.md` shape A says what replaced it. After this,
`pyra-settle-nudge` was installed beside the diagnostic. Both are in the card's
m4-kbdled initrd. The diagnostic's poke only fires if settle is still running
at 15 s, which the nudge should now prevent.

## `pyra-settle-trace` (R21, 2026-10-29)

An `init-top` hook that puts kprobes and two scheduler tracepoints on the
path from udevd's `unlink` of `/run/udev/queue` to settle's check of it:
`do_unlinkat`, `fsnotify` (IN_DELETE only), `inotify_handle_event`,
`fsnotify_add_event` (entry and return), `ep_poll_callback`, and for
`udevadm` only `sys_inotify_add_watch`, `do_epoll_wait`, `inotify_read`,
`filename_lookup`/`do_filp_open` of `/run/udev*`, `sched_wakeup` and
`sched_switch`. Kprobes don't stop the task the way strace's ptrace does.
The kernel's ring buffer outlives switch_root, and a watcher stops tracing 3 s
after settle exits. Read it after boot with
`sudo cat /sys/kernel/tracing/trace`. `chain.py` pulls settle's events out of
it, and `stall.py` lists each queue deletion during settle's wait, whether
settle's inotify group got it, and whether settle woke. `gap.py` says whether
settle's lookup fell in the old notify-before-`d_delete()` window and whether
settle then exited (see "The fix" below). The header of the hook
lists what each probe shows.

Probe notes for this ARM kernel: arguments 5 and up are `$stack0` onwards.
Probes that read user strings (`do_faccessat`, `vfs_statx`,
`strncpy_from_user` with `:ustring`) mostly print `(fault)`, so the path
probes sit on `filename_lookup` and `do_filp_open`, which get the kernel's
copy. `getname_flags` never fires, because callers use its
`getname_flags.part.0` clone. Unfiltered, `udevadm trigger`'s 90000 sysfs
lookups cost about 2 s of boot time, so the path probes filter on
`/run/udev*`.

Test runs had `pyra-settle-nudge` moved out of the m4-kbdled initrd. Two
traced warm reboots on l5, after 42 and 11 min up:

- Fast (`settle-trace-2026-10-29-fast.txt`): one queue deletion during
  settle's wait, on CPU 1. settle was woken on CPU 0, looked up the queue
  file 0.1 ms later and exited.
- Stuck (`settle-trace-2026-10-29-stuck.txt`, root at 17.8 s): queue
  deletions at 7.379 and 10.333 s were delivered and read, and settle looked
  the file up each time and slept on. In both, settle was woken on udevd's CPU
  and ran before udevd got back from `fsnotify_add_event`, so before
  `d_delete()`. The deletion at 13.565 s woke it on the other CPU, and it
  exited.

`inotify-delete-race.c` is the same race outside boot. Build it on the
Pyra with `gcc -O2`, then run `./inotify-delete-race DIR 2000 0 0` with DIR
a fresh directory on tmpfs. The result is in `docs/troubleshooting.md` shape A
and `docs/verification-log.md`.

After the runs the trace hook was removed and the nudge put back. The
initrd's file list matched `initrd.img-5.6.19-m4-kbdled.before-r21`, kept
beside it. One boot after that: nudge log `settle exited`, no kprobes left.

## The fix (R22, 2026-10-29)

`patches/0048` and `0049` backport the mainline fix (`docs/kernel-changes.md`).
Tested on m4-kbdled with them, against the unpatched `5.6.19-m4` (l4) booted the
same morning.

`inotify-delete-race.c` changed first. Its deleter used to re-create the file
2 ms after each unlink, so a waiter on the other CPU that ran late found the
next cycle's file. That counted as stale, and the merged events made the "seen"
count fall short. That is where the earlier cross-CPU counts came from, or some of
them. The deleter now waits for the waiter's check (up to 100 ms) before
re-creating the file. Measured, 2000 deletions per case:

| Kernel | 0/0 | 1/1 | 0/1 | 1/0 | unpinned |
| --- | --- | --- | --- | --- | --- |
| `5.6.19-m4`, unpatched | 1956 | 1986 | 3 | 12 | 1137 |
| `5.6.19-m4-kbdled` + 0048-0049 | 0 | 0 | 0 | 0 | 0 |

Five traced warm reboots with the nudge moved out and `pyra-settle-trace` in.
Each boot had one queue deletion while settle waited, and settle exited within
2 ms of it every time. `gap.py` scores each deletion by whether settle's lookup
ran before udevd got back from `fsnotify_add_event` (where the old kernel had not
yet run `d_delete()`), and whether settle then exited. Results:

- R21's unpatched stuck boot: 2 lookups in that window, settle stayed both times.
- This set: 1 lookup in that window (boot 3), and settle exited.

Settle's wake target CPU is not enough to classify a boot. On boot 5 the wakeup
targeted udevd's CPU, but settle ran on the other one after udevd had
returned. Extract and per-boot scores: `settle-trace-2026-10-29-fixed.txt`.

Afterwards the trace hook was removed and the nudge put back. Unpatched kernels
(l2, l3, l4) still need it, and on m4-kbdled it never fires. The initrd's file
list matched the one saved before the test. One boot after that: settle exited
at 6.03 s, no nudge, no kprobes left. `/boot` (238 MB) was too full for the
kernel install, so the `.before-r16` and `.before-r21` initrds were moved off it,
with `.before-r22`, to `/var/backups/pyra-boot/` on the root filesystem.

The Pyra's serial console (its micro-USB FTDI port, 1500000 baud) was logged on
the PC for these boots. The cmdline already sends the console there, cable or
not, so logging it doesn't change the timing. If a traced boot ever hangs
outright, SysRq-z over serial (a BREAK, then `z`) dumps the ftrace buffer to
the console.
