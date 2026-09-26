#!/usr/bin/env python3
# Reads a `thermcost.sh clock` run: battery watts per ABBA arm (first 15 s of each 60 s block dropped),
# die temperature and its slope per 10-minute hold, and the game's fps per clock from the BENCH split
# lines (one per 100 ticks, ~5 s).
# usage: thermclock.py DIR   (DIR holds thermcost-clock.csv, and thermcost-run-*.log or thermcost-clock-split.log)
import csv, glob, math, os, re, sys
from collections import defaultdict

D = sys.argv[1] if len(sys.argv) > 1 else '.'
rows = list(csv.DictReader(open(os.path.join(D, 'thermcost-clock.csv'))))
phases = []                                     # [name, [rows]] in order, one entry per block
for r in rows:
    if r['online'] != '0': continue             # on the charger: not a battery reading
    try:
        w = -int(r['current_ua']) * int(r['voltage_uv']) / 1e12
    except ValueError:
        continue
    r = dict(t=int(r['t']), w=w, cpu=int(r['cpu_mc']) / 1000, gpu=int(r['gpu_mc']) / 1000,
             core=int(r['core_mc']) / 1000, batt=int(r['batt_dc']) / 10, khz=int(r['cur_khz']), ph=r['phase'])
    # A new block when the phase changes, or every 60 s inside an ABBA phase: the order puts the
    # middle arm's two blocks back to back under the same name.
    abba = re.fullmatch(r'soh\d\d-\d+', r['ph'])
    if (not phases or phases[-1][0] != r['ph'] or
            (abba and r['t'] - phases[-1][1][0]['t'] >= 60)):
        phases.append([r['ph'], []])
    phases[-1][1].append(r)

def mean(xs): return sum(xs) / len(xs) if xs else float('nan')
def sd(xs):
    m = mean(xs); return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1)) if len(xs) > 1 else float('nan')

print('== every phase ==')
print(f'{"phase":16s} {"s":>4s} {"W":>6s} {"cpu°C":>6s} {"gpu°C":>6s} {"core°C":>6s} {"batt°C":>6s} {"MHz":>9s}')
for name, rs in phases:
    k = rs[15:] if len(rs) > 30 else rs
    mhz = sorted({r['khz'] // 1000 for r in k})
    print(f'{name:16s} {len(rs):4d} {mean([r["w"] for r in k]):6.3f} {mean([r["cpu"] for r in k]):6.1f}'
          f' {mean([r["gpu"] for r in k]):6.1f} {mean([r["core"] for r in k]):6.1f} {mean([r["batt"] for r in k]):6.1f}'
          f' {",".join(map(str, mhz)):>9s}')

print('\n== ABBA watts (60 s blocks, first 15 s dropped) ==')
for prefix in ('soh30', 'soh20'):
    arms = defaultdict(list)
    for name, rs in phases:
        m = re.fullmatch(prefix + r'-(\d+)', name)
        if m and len(rs) > 40:
            arms[int(m.group(1))].append((mean([r['w'] for r in rs[15:]]), mean([r['cpu'] for r in rs[15:]])))
    if not arms: continue
    ref = max(arms)
    print(f'{prefix}: reference {ref} MHz')
    for f in sorted(arms, reverse=True):
        ws = [a for a, _ in arms[f]]
        # paired with the reference by repeat, which the ABBA order keeps adjacent
        d = [a - b for (a, _), (b, _) in zip(arms[f], arms[ref])]
        t = mean(d) / (sd(d) / math.sqrt(len(d))) if len(d) > 1 and sd(d) > 0 else float('nan')
        print(f'  {f:5d} MHz  n={len(ws)}  {mean(ws):.3f} W (sd {sd(ws):.3f})  Δ {mean(d):+.3f} W  t {t:6.1f}'
              f'  cpu {mean([c for _, c in arms[f]]):.1f} °C')

print('\n== holds (10 min): last 3 min, and the slope over the last 5 ==')
for name, rs in phases:
    if not name.startswith('hold'): continue
    last = [r for r in rs if r['t'] >= rs[-1]['t'] - 180]
    tail = [r for r in rs if r['t'] >= rs[-1]['t'] - 300]
    n = len(tail); tm = mean([r['t'] for r in tail]); cm = mean([r['cpu'] for r in tail])
    slope = sum((r['t'] - tm) * (r['cpu'] - cm) for r in tail) / sum((r['t'] - tm) ** 2 for r in tail) * 60
    print(f'{name:14s} {mean([r["w"] for r in last]):.3f} W  cpu {mean([r["cpu"] for r in last]):.1f}'
          f' gpu {mean([r["gpu"] for r in last]):.1f} core {mean([r["core"] for r in last]):.1f} °C'
          f'  cpu slope {slope:+.2f} °C/min  (start {rs[0]["cpu"]:.1f})')

print('\n== the game: BENCH split windows by clock ==')
# Either the game's own logs (on the device) or thermcost-clock-split.log (in the repo: the same
# lines, each prefixed by its run's name).
runs = defaultdict(list)
for f in sorted(glob.glob(os.path.join(D, 'thermcost-run-*.log'))):
    runs[os.path.basename(f)[len('thermcost-run-'):-4]] = list(open(f, errors='replace'))
if not runs and os.path.exists(os.path.join(D, 'thermcost-clock-split.log')):
    for line in open(os.path.join(D, 'thermcost-clock-split.log'), errors='replace'):
        name, _, rest = line.partition(' ')
        runs[name].append(rest)
for f, lines in runs.items():
    by = defaultdict(list)
    for line in lines:
        m = re.search(r'Benchmark split ticks=\d+ .*', line)
        if not m: continue
        k = dict(re.findall(r'(\w+)=([^\s]+)', m.group(0)))
        pf = re.search(r'render_cpu_ms med=[\d.]+ mean=[\d.]+ p95=([\d.]+) per_frame=([\d.]+)', m.group(0))
        # the 20 fps run starts at 30 until its segment applies the CVar: keep each run's own rate
        if ('fps20' in f) != (k['frames_per_tick'] == '1.00'): continue
        by[k['cpu_mhz']].append((float(k['fps']), float(pf.group(2)), float(pf.group(1))))
    target = 20 if 'fps20' in f else 30
    print(f'{f} (target {target} fps; the first window of a run is the load)')
    for mhz, v in by.items():
        fps = [a for a, _, _ in v]
        print(f'  {mhz:>10s}  windows {len(v):4d}  fps mean {mean(fps):5.2f} min {min(fps):5.2f}'
              f'  frames lost {100 * (1 - mean(fps) / target):4.1f}%'
              f'  windows under {0.983 * target:.1f}: {sum(1 for x in fps if x < 0.983 * target):3d}'
              f'  render CPU/frame {mean([b for _, b, _ in v]):5.1f} ms  p95 render/tick {mean([c for _, _, c in v]):5.1f} ms')
