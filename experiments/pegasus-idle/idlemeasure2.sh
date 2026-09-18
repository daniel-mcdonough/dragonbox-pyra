#!/bin/sh
# Usage: idlemeasure2.sh <label> <theme> <udev:on|off>
# Cools the machine first, so the thermal ceiling and leakage are comparable
# between conditions, then reports CPU time rather than trusting the battery
# gauge, which moves with die temperature.
label=$1; theme=$2; udev=$3
export DISPLAY=:0
cfg=$HOME/.config/pegasus-frontend/settings.txt

pkill -9 -x pegasus-fe 2>/dev/null
while pgrep -x pegasus-fe >/dev/null; do sleep 1; done

# Cool down: wait for the die to come back under 64 C, up to three minutes.
n=0
while [ $n -lt 180 ]; do
    t=$(cat /sys/class/thermal/thermal_zone0/temp)
    [ "$t" -lt 64000 ] && break
    sleep 10; n=$((n+10))
done
start_temp=$(awk "{printf \"%.1f\", \$1/1000}" /sys/class/thermal/thermal_zone0/temp)

printf "general.theme: %s\n" "$theme" > "$cfg"
if [ "$udev" = off ]; then
    nohup env SDL_JOYSTICK_DISABLE_UDEV=1 /tmp/pyra-gles /tmp/pegasus-fe >/tmp/m2-$label.log 2>&1 &
else
    nohup /tmp/pyra-gles /tmp/pegasus-fe >/tmp/m2-$label.log 2>&1 &
fi
n=0; while [ $n -lt 40 ]; do grep -q "games found" /tmp/m2-$label.log && break; sleep 1; n=$((n+1)); done
sleep 25

pid=$(pgrep -x pegasus-fe | head -1)
hz=$(getconf CLK_TCK)
for t in /proc/$pid/task/*; do echo "$(basename $t) $(awk "{print \$14+\$15}" $t/stat) $(cat $t/comm)"; done > /tmp/ta
c1=$(awk "{print \$14+\$15}" /proc/$pid/stat); t1=$(cut -d" " -f1 /proc/uptime)
i1=$(awk "/^cpu /{print \$5}" /proc/stat); a1=$(awk "/^cpu /{s=0; for(i=2;i<=8;i++) s+=\$i; print s}" /proc/stat)
sleep 40
c2=$(awk "{print \$14+\$15}" /proc/$pid/stat); t2=$(cut -d" " -f1 /proc/uptime)
i2=$(awk "/^cpu /{print \$5}" /proc/stat); a2=$(awk "/^cpu /{s=0; for(i=2;i<=8;i++) s+=\$i; print s}" /proc/stat)
for t in /proc/$pid/task/*; do echo "$(basename $t) $(awk "{print \$14+\$15}" $t/stat) $(cat $t/comm)"; done > /tmp/tb

dt=$(echo "$t1 $t2" | awk "{print \$2-\$1}")
printf "%-16s start=%sC  frontend=%s  machine=%s  end=%sC ceiling=%s\n" "$label" "$start_temp" \
  "$(echo "$c1 $c2 $t1 $t2 $hz" | awk "{printf \"%.1f%%\", (\$2-\$1)/\$5/(\$4-\$3)*100}")" \
  "$(echo "$i1 $i2 $a1 $a2" | awk "{printf \"%.1f%%\", (1-(\$2-\$1)/(\$4-\$3))*100}")" \
  "$(awk "{printf \"%.1f\", \$1/1000}" /sys/class/thermal/thermal_zone0/temp)" \
  "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"
awk -v hz="$hz" -v dt="$dt" "
    NR==FNR { a[\$1]=\$2; next }
    { d=(\$2-a[\$1])/hz/dt*100; if (d>0.4) printf \"    %-18s %5.1f%%\n\", \$3, d }
" /tmp/ta /tmp/tb
pkill -9 -x pegasus-fe 2>/dev/null
