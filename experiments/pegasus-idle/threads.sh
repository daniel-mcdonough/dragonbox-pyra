#!/bin/sh
# Per-thread CPU of the running frontend over 20 s, plus frames if timing is on.
pid=$(pgrep -x pegasus-fe | head -1)
[ -n "$pid" ] || { echo "not running"; exit 1; }
hz=$(getconf CLK_TCK)
for t in /proc/$pid/task/*; do
    echo "$(basename $t) $(awk "{print \$14+\$15}" $t/stat) $(cat $t/comm)"
done > /tmp/th1
t1=$(cut -d" " -f1 /proc/uptime)
sleep 20
t2=$(cut -d" " -f1 /proc/uptime)
for t in /proc/$pid/task/*; do
    echo "$(basename $t) $(awk "{print \$14+\$15}" $t/stat) $(cat $t/comm)"
done > /tmp/th2
awk -v hz="$hz" -v dt="$(echo "$t1 $t2" | awk "{print \$2-\$1}")" "
    NR==FNR { a[\$1]=\$2; name[\$1]=\$3; next }
    { d=(\$2-a[\$1])/hz/dt*100; if (d>0.5) printf \"  %-18s %5.1f%% of one core\n\", \$3, d }
" /tmp/th1 /tmp/th2
