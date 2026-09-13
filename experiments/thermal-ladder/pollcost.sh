#!/bin/bash
# What does polling every 2 s instead of every 20 s actually cost?
# Measured as the daemons own CPU time plus the machines idle frequency
# residency, neither of which depends on the charger being attached.
exec > ~/probe/pollcost.log 2>&1
WIN=${WIN:-300}
STATS=/sys/devices/system/cpu/cpu0/cpufreq/stats

measure() {
    local want=$1
    sudo sed -i "s/^interval=[0-9]*/interval=$want/" /usr/share/pyra/scripts/pyra-thermal.sh
    sudo systemctl restart pyra-thermal
    sleep 30
    local pid t0 t1 j0 j1
    pid=$(systemctl show -p MainPID --value pyra-thermal)
    # utime+stime of the daemon and every child it forks, in jiffies.
    read_cpu() { awk "{print \$14+\$15+\$16+\$17}" /proc/$pid/stat 2>/dev/null || echo 0; }
    j0=$(read_cpu); cp /proc/uptime /tmp/up0
    cat $STATS/time_in_state > /tmp/tis0
    sleep $WIN
    j1=$(read_cpu)
    cat $STATS/time_in_state > /tmp/tis1
    echo "interval=$want  daemon cpu jiffies over ${WIN}s: $((j1-j0))  (=$(awk "BEGIN{printf \"%.3f\", ($j1-$j0)/100}") s, $(awk "BEGIN{printf \"%.3f\", ($j1-$j0)/100/$WIN*100}")% of one core)"
    python3 - /tmp/tis0 /tmp/tis1 <<PY
import sys
def rd(p):
    d={}
    for l in open(p):
        k,v=l.split(); d[int(k)]=int(v)
    return d
a,b=rd(sys.argv[1]),rd(sys.argv[2])
dl={k:b[k]-a.get(k,0) for k in b}
tot=sum(dl.values())
mean=sum(k*v for k,v in dl.items())/tot if tot else 0
top=100.0*dl.get(max(dl),0)/tot if tot else 0
print("    idle mean frequency %.0f kHz, %.2f%% at the top step, %d transitions-worth of samples" % (mean, top, tot))
PY
}

echo "=== 2 second poll (the fix) ==="
measure 2
echo
echo "=== 20 second poll (the vendor) ==="
measure 20
echo
echo "=== back to the fix ==="
measure 2
echo "POLLCOST DONE"
