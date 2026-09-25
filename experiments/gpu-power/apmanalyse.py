#!/usr/bin/env python3
# Summarise an apmcompare.sh run.
#   apmanalyse.py <dir with apmcompare.csv, apmcompare.log, apmcompare-soh-*.log>
# Power per block, dropping the first 15 s (idle) or 45 s (game: load, settle, warm GPU),
# and the last 8 s (game blocks: everything after 147 s): the script swaps modules before it writes the next phase, so the
# swap itself (about 6 s) is logged under the block it ends.
# ABBA pairs give fixed - stock. The game's own split lines give fps and frame times.
import csv, glob, os, re, sys, statistics as st

d = sys.argv[1] if len(sys.argv) > 1 else "."
rows = list(csv.DictReader(open(os.path.join(d, "apmcompare.csv"))))
marks = [l.split() for l in open(os.path.join(d, "apmcompare.log"))]
events = [m for m in marks if len(m) != 2]
marks = [(int(t), p) for t, p in (m for m in marks if len(m) == 2)]
W = lambda r: -int(r["current_ua"]) * int(r["voltage_uv"]) / 1e12

print("block         n  power W    sd   gpu C  pd_off%  rpm_susp%  clk_act%")
blocks = []
for (t, p), (t2, _) in zip(marks, marks[1:]):
    if not (p.startswith("idle-") or p.startswith("soh-")): continue
    skip = 45 if p.startswith("soh-") else 15
    # The game runs exactly 150 s from its phase mark; after that the next swap waits for
    # it to exit, which is idle time that must not count as game.
    end = min(t2 - 8, t + 147) if p.startswith("soh-") else t2 - 8
    rs = [r for r in rows if t + skip <= int(r["t"]) < end]
    if len(rs) < 10: continue
    w = [W(r) for r in rs]
    f = lambda k: 100 * st.mean(float(r[k]) for r in rs)
    blocks.append((p, st.mean(w)))
    print(f"{p:12} {len(rs):3} {st.mean(w):7.3f} {st.stdev(w):6.3f} "
          f"{st.mean(int(r['gpu_mc']) for r in rs)/1000:6.1f} {f('pwrst_off_frac'):7.0f} "
          f"{f('rpm_suspended_frac'):9.0f} {f('clkact_frac'):8.0f}"
          + ("  ON USB POWER" if any(r["online"] == "1" for r in rs) else ""))

for kind in ("idle", "soh"):
    bs = [(p.split("-")[1], w) for p, w in blocks if p.startswith(kind + "-")]
    pairs = []
    for i in range(0, len(bs) - 1, 2):
        (a, wa), (b, wb) = bs[i], bs[i + 1]
        if a != b: pairs.append((wa - wb) if a == "fixed" else (wb - wa))
    if pairs:
        print(f"\n{kind}: fixed - stock = {st.mean(pairs):+.3f} W "
              f"(pairs {' '.join(f'{x:+.3f}' for x in pairs)})")

print("\ngame            splits   fps    render_wall_ms  tick_wall_ms")
for f in sorted(glob.glob(os.path.join(d, "apmcompare-soh-*.log"))):
    sp = [l for l in open(f, errors="replace") if "Benchmark split ticks=" in l][5:]
    if not sp:
        print(f"{os.path.basename(f):28} no split lines"); continue
    g = lambda pat: st.mean(float(re.search(pat, l).group(1)) for l in sp)
    print(f"{os.path.basename(f)[15:-4]:14} {len(sp):6} {g(r' fps=([0-9.]+)'):6.2f} "
          f"{g(r'render_wall_ms med=([0-9.]+)'):12.2f} {g(r'tick_wall_ms mean=([0-9.]+)'):12.2f}")
for e in events:
    print("event:", " ".join(e))
