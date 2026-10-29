# For each settle (udevadm that called inotify_add_watch), list each IN_DELETE
# of "queue" after its watch, and whether settle's group got it and settle woke.
import re, sys
pat = re.compile(r'^\s*(.+?)-(\d+)\s+\[(\d+)\]\s+\S+\s+([\d.]+): (\S+): (.*)$')
ev = [m.groups() for l in open(sys.argv[1]) if (m := pat.match(l))]
ev = [(c, int(p), cpu, float(t), e, r) for c, p, cpu, t, e, r in ev]
for sp in sorted({p for c, p, _, _, e, _ in ev if e == 'iaw'}):
    mine = [x for x in ev if x[1] == sp]
    t_watch = next(x[3] for x in mine if x[4] == 'iaw')
    t_end = mine[-1][3]
    print(f"settle {sp}: watch {t_watch:.6f}, last own event {t_end:.6f} ({t_end - t_watch:.3f} s)")
    for i, x in enumerate(ev):
        if x[4] == 'fsn' and 'name="queue"' in x[5] and t_watch <= x[3] <= t_end + 0.5:
            nxt = ev[i + 1:i + 12]
            ihe = [y for y in nxt if y[4] == 'ihe' and 'name="queue"' in y[5]]
            wake = [y for y in ev[i:i + 400] if y[4] == 'sched_wakeup' and f'pid={sp} ' in y[5] and y[3] - x[3] < 0.05]
            print(f"   {x[3]:.6f} delete queue: ihe={'yes ' + ihe[0][5].split()[0] if ihe else 'NO'} settle-woken<50ms={'yes' if wake else 'NO'}")
