#!/usr/bin/env python3
# Summarise a gpuoff.sh run.
#   analyse.py gpuoff.csv gpuoff.log [cutoff_s]
# Blocks come from the phase log, not from the CSV, so back-to-back blocks of the same
# state stay separate. Each switch between on and off is also measured as a step: the mean
# of the 45 s before it against the 45 s after it, skipping 15 s after the switch because
# the gauge averages over its own window. Steps cancel the slow drift that the battery
# voltage and the cooling die put on block means. cutoff_s drops everything after that
# many seconds from the first block (for example once the screen has blanked).
import csv, sys, statistics as st

rows = list(csv.DictReader(open(sys.argv[1])))
log = [l.split() for l in open(sys.argv[2]) if len(l.split()) == 2]
cut = float(sys.argv[3]) if len(sys.argv) > 3 else None
marks = [(int(t), p) for t, p in log]
t_first = next(t for t, p in marks if p.startswith("gpu-"))
if cut is not None:
    marks = [(t, p) for t, p in marks if t - t_first < cut] + [(t_first + int(cut), "cut")]
W = lambda r: -int(r["current_ua"]) * int(r["voltage_uv"]) / 1e12   # current_now < 0 discharging
def span(a, b): return [r for r in rows if a <= int(r["t"]) < b]

print("block    start   n  power W   sd    gpu C  pd_off%  clk_active%")
blocks = []
for (t, p), (t2, _) in zip(marks, marks[1:]):
    if not p.startswith("gpu-"): continue
    rs = span(t + 15, t2)
    if len(rs) < 10: continue
    w = [W(r) for r in rs]
    blocks.append((p, st.mean(w)))
    print(f"{p:8} {t - t_first:5d} {len(rs):3} {st.mean(w):7.3f} {st.stdev(w):6.3f} "
          f"{st.mean(int(r['gpu_mc']) for r in rs)/1000:6.1f} "
          f"{100*st.mean(float(r['pwrst_off_frac']) for r in rs):7.0f} "
          f"{100*st.mean(float(r['clkact_frac']) for r in rs):9.0f}"
          + ("  ON USB POWER" if any(r["online"] == "1" for r in rs) else ""))

print("\nswitch       at    before   after   on-off W   gpu C on-off")
steps = []
for (t0, p0), (t, p) in zip(marks, marks[1:]):
    if not (p0.startswith("gpu-") and p.startswith("gpu-") and p0 != p): continue
    end = next((u for u, _ in marks if u > t), t + 90)
    a, b = span(max(t0, t - 45), t), span(t + 15, min(end, t + 60))
    if len(a) < 10 or len(b) < 10: continue
    wa, wb = st.mean(map(W, a)), st.mean(map(W, b))
    ga, gb = (st.mean(int(r["gpu_mc"]) for r in x) / 1000 for x in (a, b))
    d = wa - wb if p0 == "gpu-on" else wb - wa
    g = ga - gb if p0 == "gpu-on" else gb - ga
    steps.append(d)
    print(f"{p0[4:]:>3} -> {p[4:]:<3} {t - t_first:5d}  {wa:7.3f} {wb:7.3f}   {d:+.3f}     {g:+.1f}")
if steps:
    print(f"\nGPU held ON costs {st.mean(steps):.3f} W at desktop idle "
          f"(mean of {len(steps)} switches, range {min(steps):.3f}-{max(steps):.3f})")
