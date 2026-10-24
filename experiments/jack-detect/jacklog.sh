#!/bin/sh
# Log the TS3A227E jack state and the card's jack controls on change.
#
#   sudo ./jacklog.sh [SECONDS] > log      default 1800
#
# Reads ONLY the accessory status register (0x0b) of the chip, with
# i2ctransfer. Do not dump /sys/kernel/debug/regmap/4-003b/registers instead:
# that reads 0x01 and 0x02 too, which clear on read, and steals the driver's
# events. Needs i2c-tools and alsa-utils.
end=$(( $(date +%s) + ${1:-1800} )); last=""
while [ "$(date +%s)" -lt "$end" ]; do
	acc=$(i2ctransfer -f -y 4 w1@0x3b 0x0b r1 2>/dev/null)
	irq=$(awk '/TS3A227E/{print $2+$3}' /proc/interrupts)
	exp=$(awk '/4-0022$/{print $2+$3}' /proc/interrupts)
	line=$(grep -o 'mic-int  *|mic-int  *) in  *[a-z]*' /sys/kernel/debug/gpio | awk '{print $NF}')
	hp=$(amixer -c L15 cget iface=CARD,name="Headset Stereophone Jack" | sed -n 's/.*: values=//p')
	mic=$(amixer -c L15 cget iface=CARD,name="Headset Mic Jack" | sed -n 's/.*: values=//p')
	cur="acc=$acc ts_irq=$irq exp_irq=$exp intb=$line hp=$hp mic=$mic"
	[ "$cur" != "$last" ] && echo "$(date +%T.%N | cut -c1-12) $cur" && last=$cur
	sleep 0.2
done
