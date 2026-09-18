#!/bin/sh
# Control: a static Qt Quick scene with no Pegasus around it.
export DISPLAY=:0
cat > /tmp/static.qml <<QML
import QtQuick 2.15
import QtQuick.Window 2.15
Window {
    visible: true; visibility: Window.FullScreen; color: "#101014"
    Text {
        anchors.centerIn: parent
        color: "#d0d0d8"; font.pixelSize: 24
        text: "static scene, nothing animating"
    }
}
QML
pkill -f "qt5/bin/qmlscene" 2>/dev/null
nohup /tmp/pyra-gles /usr/lib/arm-linux-gnueabihf/qt5/bin/qmlscene /tmp/static.qml >/tmp/qmlidle.log 2>&1 &
sleep 20
pid=$(pgrep -f "qt5/bin/qmlscene" | head -1)
hz=$(getconf CLK_TCK)
c1=$(awk "{print \$14+\$15}" "/proc/$pid/stat"); t1=$(cut -d" " -f1 /proc/uptime)
i1=$(awk "/^cpu /{print \$5}" /proc/stat); a1=$(awk "/^cpu /{s=0; for(i=2;i<=8;i++) s+=\$i; print s}" /proc/stat)
sum=0; cnt=0; n=0
while [ $n -lt 30 ]; do sum=$((sum + $(cat /sys/class/power_supply/bq27421-0/current_now))); cnt=$((cnt+1)); sleep 3; n=$((n+3)); done
c2=$(awk "{print \$14+\$15}" "/proc/$pid/stat"); t2=$(cut -d" " -f1 /proc/uptime)
i2=$(awk "/^cpu /{print \$5}" /proc/stat); a2=$(awk "/^cpu /{s=0; for(i=2;i<=8;i++) s+=\$i; print s}" /proc/stat)
printf "qmlscene   frontend=%-7s machine=%-7s draw=%4s mA  die=%s C\n" \
  "$(echo "$c1 $c2 $t1 $t2 $hz" | awk "{printf \"%.1f%%\", (\$2-\$1)/\$5/(\$4-\$3)*100}")" \
  "$(echo "$i1 $i2 $a1 $a2" | awk "{printf \"%.1f%%\", (1-(\$2-\$1)/(\$4-\$3))*100}")" \
  "$(echo "$sum $cnt" | awk "{printf \"%.0f\", -\$1/\$2/1000}")" \
  "$(awk "{printf \"%.1f\", \$1/1000}" /sys/class/thermal/thermal_zone0/temp)"
pkill -f "qt5/bin/qmlscene"
