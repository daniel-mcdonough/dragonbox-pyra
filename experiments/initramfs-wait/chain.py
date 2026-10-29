import re, sys
lines = open(sys.argv[1]).read().splitlines()
pat = re.compile(r'^\s*(.+?)-(\d+)\s+\[(\d+)\]\s+\S+\s+([\d.]+): (\S+): (.*)$')
ev = []
for l in lines:
    m = pat.match(l)
    if m: ev.append((m.group(1), int(m.group(2)), m.group(3), float(m.group(4)), m.group(5), m.group(6)))
# settle pid = udevadm that called inotify_add_watch
spids = {p for c,p,_,_,e,_ in ev if e == 'iaw' and c == 'udevadm'}
print("settle pids:", spids)
for c,p,cpu,t,e,rest in ev:
    keep = False
    if e == 'tracing_mark_write': keep = True
    elif p in spids and e in ('iaw','iawr','epw','epwr','ird','irdr'): keep = True
    elif p in spids and e in ('look','open') and ('udev' in rest): keep = True
    elif e in ('unlink','fsn') and 'queue"' in rest: keep = True
    elif e in ('ihe','addev','addevr'): keep = True
    elif e == 'sched_wakeup' and any(f'pid={sp} ' in rest for sp in spids): keep = True
    elif e == 'sched_switch' and any(f'prev_pid={sp} ' in rest and 'prev_state=S' in rest for sp in spids): keep = True
    if keep:
        rest = re.sub(r'\((\w+)\+0x0/0x\w+\) ', '', rest)
        rest = re.sub(r'\(ret_fast_syscall\S+ <- (\w+)\) ', r'<-\1 ', rest)
        print(f"{t:10.6f} [{cpu}] {c}-{p} {e} {rest}")
