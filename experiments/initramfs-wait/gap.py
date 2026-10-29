# Per IN_DELETE of "queue" while a settle waits: did settle look the name up
# before udevd returned from fsnotify_add_event (inside the old notify-before-
# d_delete gap), and did settle then exit (IN_IGNORED on its group) in 50 ms?
import re, sys
pat = re.compile(r'^\s*(.+?)-(\d+)\s+\[(\d+)\]\s+\S+\s+([\d.]+): (\S+): (.*)$')
ev = [(c, int(p), int(cpu), float(t), e, r) for l in open(sys.argv[1]) if (m := pat.match(l)) for c, p, cpu, t, e, r in [m.groups()]]
for sp in sorted({p for c, p, _, _, e, _ in ev if e == 'iaw'}):
    mine = [x for x in ev if x[1] == sp]
    t0, t1 = next(x[3] for x in mine if x[4] == 'iaw'), mine[-1][3]
    for i, x in enumerate(ev):
        if x[4] == 'fsn' and 'name="queue"' in x[5] and t0 <= x[3] <= t1:
            ret = next((y[3] for y in ev[i:] if y[1] == x[1] and y[4] == 'addevr'), None)
            look = next((y[3] for y in ev[i:] if y[1] == sp and y[4] == 'look' and y[3] - x[3] < 0.05), None)
            gone = any(y[4] == 'ihe' and 'mask=0x8000' in y[5] and y[1] == sp for y in ev[i:] if y[3] - x[3] < 0.05)
            ingap = look is not None and ret is not None and look < ret
            print(f"  {x[3]:.6f}: settle lookup {'IN the gap' if ingap else 'after udevd returned'}, settle {'exited' if gone else 'STAYED'}")
