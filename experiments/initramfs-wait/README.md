# Why root sometimes mounts a minute or two late

The findings live in `docs/troubleshooting.md`, "Root mounts a minute or two
late". This directory holds the tool used to chase the part that is still open.

## `pyra-settle-diag`

An initramfs-tools `init-top` hook. It runs before `init-top/udev`, starts a
background watcher and returns. If the initramfs is still running 15 s after
boot, and again at 30, 60 and 100 s, the watcher records the following in
`/run/initramfs/settle-diag.txt`:

- pending sysfs firmware fallbacks (`/sys/class/firmware`)
- the udev run directory
- every process's state, parent, wchan and command line

It also writes a `pyra-settle-diag` marker to the kernel log and triggers
SysRq-T, so every task's kernel stack ends up in the journal. `/proc/<pid>/stack`
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
