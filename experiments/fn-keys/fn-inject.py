#!/usr/bin/env python3
# Send kernel keycodes through a throwaway uinput keyboard, the same path
# pyrainput's Fn layer uses. Usage: fn-inject.py [-s] CODE... (-s: hold Shift
# for all; a CODE written sNN holds Shift for that one only; dNN/uNN press/release only)
import fcntl, os, struct, sys, time

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_SYN, EV_KEY = 0, 1
KEY_LEFTSHIFT = 42

args = sys.argv[1:]
shift = args and args[0] == '-s'
codes = [a for a in args if a != '-s']

fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
for c in range(1, 256):
    fcntl.ioctl(fd, UI_SET_KEYBIT, c)
# legacy uinput_user_dev: name[80], id (4 x u16), ff_effects_max, abs arrays
dev = struct.pack('80sHHHHi', b'fn-inject', 3, 1, 1, 1, 0) + b'\0' * (4 * 64 * 4)
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(float(os.environ.get('FN_WAIT', '1.5')))  # let X and the console pick the device up

def ev(t, c, v):
    sec = time.time()
    os.write(fd, struct.pack('llHHi', int(sec), int((sec % 1) * 1e6), t, c, v))

def key(c, v):
    ev(EV_KEY, c, v)
    ev(EV_SYN, 0, 0)
    time.sleep(0.05)

for a in codes:
    if a[0] in 'du':
        key(int(a[1:]), 1 if a[0] == 'd' else 0)
        continue
    s = shift or a.startswith('s')
    c = int(a.lstrip('s'))
    if s:
        key(KEY_LEFTSHIFT, 1)
    key(c, 1)
    key(c, 0)
    if s:
        key(KEY_LEFTSHIFT, 0)
time.sleep(0.5)
fcntl.ioctl(fd, UI_DEV_DESTROY)
