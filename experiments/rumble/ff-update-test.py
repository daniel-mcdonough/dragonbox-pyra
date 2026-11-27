#!/usr/bin/env python3
# Play one FF_RUMBLE effect on the pyraInput Gamepad and change its strength
# twice while it plays, by uploading it again under the same id (what SDL does
# for every SDL_GameControllerRumble call on a running effect). With
# trace-vibra.sh around it, the regmap trace shows whether the TWL6040's
# VIBCTLR (0x1a) stays on across the updates. Needs read/write on the event
# node (root, or the input group).
#
# Usage: ff-update-test.py [--play-again] [STRONG...]
#   default strengths 0x4000 0xffff 0x2000; --play-again writes a play event
#   after each update, as SDL's LINUX_JoystickRumble does.
import fcntl, glob, os, struct, sys, time

EVIOCSFF = 0x402c4580           # _IOW('E', 0x80, struct ff_effect), 44 bytes on armhf
EVIOCRMFF = 0x40044581
EV_FF, FF_RUMBLE = 0x15, 0x50


def gamepad():
    for d in sorted(glob.glob('/sys/class/input/event*')):
        with open(d + '/device/name') as f:
            if f.read().strip() == 'pyraInput Gamepad':
                return '/dev/input/' + os.path.basename(d)
    sys.exit('no pyraInput Gamepad')


def upload(fd, eid, strong, length_ms=10000):
    # type, id, direction, trigger.button, trigger.interval, replay.length,
    # replay.delay, (pad), rumble.strong, rumble.weak, (rest of the union)
    buf = bytearray(struct.pack('<HhHHHHH2xHH', FF_RUMBLE, eid, 0, 0, 0,
                                length_ms, 0, strong, 0).ljust(44, b'\0'))
    fcntl.ioctl(fd, EVIOCSFF, buf)
    return struct.unpack_from('<h', buf, 2)[0]


def mark(msg):
    print(f'{time.clock_gettime(time.CLOCK_MONOTONIC):.6f} {msg}', flush=True)


args = sys.argv[1:]
play_again = '--play-again' in args
strengths = [int(s, 0) for s in args if s != '--play-again'] or [0x4000, 0xffff, 0x2000]
fd = os.open(gamepad(), os.O_RDWR)
eid = upload(fd, -1, strengths[0])
mark(f'uploaded id {eid} strong {strengths[0]:#06x}')
os.write(fd, struct.pack('<IIHHi', 0, 0, EV_FF, eid, 1))
mark('play')
for s in strengths[1:]:
    time.sleep(1.0)
    got = upload(fd, eid, s)
    mark(f'updated id {got} strong {s:#06x}')
    if play_again:
        os.write(fd, struct.pack('<IIHHi', 0, 0, EV_FF, got, 1))
        mark('play')
time.sleep(1.0)
os.write(fd, struct.pack('<IIHHi', 0, 0, EV_FF, eid, 0))
mark('stop')
fcntl.ioctl(fd, EVIOCRMFF, eid)
mark('erased')
