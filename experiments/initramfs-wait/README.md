# Why root sometimes mounts a minute or two late

The findings live in `docs/troubleshooting.md`, "Root mounts a minute or two
late". This directory holds the tool used to chase them. The shape A
workaround it led to is `device/etc/initramfs-tools/scripts/init-top/pyra-settle-nudge`.

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
