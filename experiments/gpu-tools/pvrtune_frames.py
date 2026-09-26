#!/usr/bin/env python3
"""Per-frame GPU time from a PVRTune timing export.

    PVRTuneDeveloperGUI cap.pvrtune --export-csv-timing=cap-timing.csv
    ./pvrtune_frames.py cap-timing.csv [from_s to_s]

Pairs ta_start/ta_end and 3d_start/3d_end, clusters 3D kicks separated by
less than 1 ms into one render, and labels a render "scene" when more than two
TA kicks precede it (SoH's 640x360 game framebuffer) and "present" otherwise
(the 1280x720 pass that draws that framebuffer to the window).
"""
import csv, statistics as st, sys

path = sys.argv[1]
ev = [(int(r[0]), r[1]) for r in list(csv.reader(open(path)))[1:]]
t0 = ev[0][0]
lo = t0 + float(sys.argv[2]) * 1e6 if len(sys.argv) > 2 else t0
hi = t0 + float(sys.argv[3]) * 1e6 if len(sys.argv) > 3 else ev[-1][0]

spans = {'ta': [], '3d': []}
open_ = {}
for t, e in ev:
    k, s = e.split('_')
    if s == 'start':
        open_[k] = t
    elif k in open_:
        spans[k].append((open_.pop(k), t))
d3 = [s for s in spans['3d'] if lo <= s[0] < hi]
ta = [s for s in spans['ta'] if lo <= s[0] < hi]

clusters, cur = [], [d3[0]]
for s in d3[1:]:
    if s[0] - cur[-1][1] > 1000:
        clusters.append(cur)
        cur = [s]
    else:
        cur.append(s)
clusters.append(cur)

prev_end, kinds = 0, {'scene': [], 'present': []}
for c in clusters:
    nta = sum(1 for a in ta if prev_end <= a[0] < c[0][0])
    busy = sum(b - a for a, b in c)
    kinds['scene' if nta > 2 else 'present'].append((busy, c[-1][1] - c[0][0], len(c), nta))
    prev_end = c[-1][1]

dur = (hi - lo) / 1e6
for name, L in kinds.items():
    if not L:
        continue
    print(f"{name:8s} {len(L)/dur:5.1f}/s  3D busy mean {st.mean(x[0] for x in L):5.0f} us"
          f"  median {st.median(x[0] for x in L):5.0f}  p95 {sorted(x[0] for x in L)[int(len(L)*.95)]:5.0f}"
          f"  kicks {st.mean(x[2] for x in L):.1f}  TA kicks before {st.mean(x[3] for x in L):.1f}")

iv = sorted(ta + d3)
union, (cs, ce) = 0, iv[0]
for a, b in iv[1:]:
    if a > ce:
        union += ce - cs
        cs, ce = a, b
    else:
        ce = max(ce, b)
union += ce - cs
print(f"{dur:.0f} s: 3D busy {sum(b-a for a,b in d3)/dur/1e4:.1f}%  TA busy {sum(b-a for a,b in ta)/dur/1e4:.1f}%"
      f"  GPU busy (TA or 3D) {union/dur/1e4:.1f}%")
