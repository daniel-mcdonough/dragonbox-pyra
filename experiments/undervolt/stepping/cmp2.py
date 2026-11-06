#!/usr/bin/env python3
# cmp2.py <dir>: in-process check. Every segment's frames against segment 0's two frames (either phase);
# the frozen Market draws the same frame every segment, so any difference is an error.
import sys, glob, re, numpy as np
from PIL import Image
d = sys.argv[1]
im = {p.split('/')[-1][:-4]: np.asarray(Image.open(p).convert('RGB')).astype(int) for p in glob.glob(d+'/*.ppm')}
segs = sorted({int(re.match(r'seg(\d+)', k).group(1)) for k in im})
ref = [v for k, v in im.items() if k.startswith('seg0-')]
bad = 0
print(f"segments {len(segs)} frames {len(im)}")
if len(im) != 12: print('FAIL frame count'); sys.exit(1)
for k in sorted(im):
    best = min(int(np.abs(im[k] - r).any(axis=2).sum()) for r in ref)
    if best: print(f"{k}: {best} pixels"); bad += 1
print('FAIL' if bad else 'OK'); sys.exit(1 if bad else 0)
