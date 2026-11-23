#!/usr/bin/env python3
# Writes the three test files reproduce.sh plays: a 0.5 s 440 Hz beep at
# -20 dBFS and 1 s of silence, 3 s of silence, and twenty 4 s beeps at -26 dBFS
# with 2 s gaps. 48 kHz stereo S16, 5 ms fades so the files add no clicks.
import math, struct, wave

def write(name, segs, rate=48000):
    f = wave.open(name, 'wb'); f.setnchannels(2); f.setsampwidth(2); f.setframerate(rate)
    buf = bytearray()
    for freq, dur, db in segs:
        a = 32767 * 10 ** (db / 20); n = int(rate * dur)
        for i in range(n):
            g = min(1, i / 240, (n - i) / 240)
            v = int(a * g * math.sin(2 * math.pi * freq * i / rate)) if freq else 0
            buf += struct.pack('<hh', v, v)
    f.writeframes(bytes(buf)); f.close()

write('tone.wav', [(440, 0.5, -20), (0, 1.0, 0)])
write('silence.wav', [(0, 3.0, 0)])
write('long.wav', [(440, 4, -26), (0, 2, 0)] * 20)
