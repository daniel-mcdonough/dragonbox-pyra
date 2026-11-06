#!/bin/sh
# Read core and battery temp and pick approperiate cpu freq and charging rates

interval=20
core="core_thermal"
battery="bq27421-0"

maxFreq=1900
maxCharge=3000000

setMaxFreq()
{
        if [ "$1" -lt "$maxFreq" ]
        then
                current_maxFreq=$1
        fi
}

setMaxCharge()
{
        if [ "$1" -lt "$maxCharge" ]
        then
                current_maxCharge=$1
        fi
}

doThermal()
{

	current_maxFreq=${maxFreq}
	current_maxCharge=${maxCharge}

        core_temp=$(cat "${core_dev}")
        battery_temp=$(cat "${battery_dev}")
        
	#Check Core, from hottest to coldest
	if [ ${core_temp} -gt 99000 ]
	then
       		setMaxFreq 250
	elif [ ${core_temp} -gt 97000 ]
	then
        	setMaxFreq 500
	elif [ ${core_temp} -gt 95000 ]
	then
        	setMaxFreq 750
	elif [ ${core_temp} -gt 93000 ]
	then
        	setMaxFreq 1000
	elif [ ${core_temp} -gt 91000 ]
	then
                setMaxFreq 1250
        elif [ ${core_temp} -gt 90000 ]
        then
		setMaxFreq 1500
        elif [ ${core_temp} -gt 89000 ]
        then
		setMaxFreq 1700
        elif [ ${core_temp} -gt 88000 ]
        then
        	setMaxFreq 1900
	fi

	#Check Battery, from hottest to coldest
	if [ ${battery_temp} -gt 50000 ]
	then
        	setMaxFreq 250
        	setMaxCharge 1600000
	elif [ ${battery_temp} -gt 55000 ]
	then
        	setMaxFreq 500
        	setMaxCharge 1600000
	elif [ ${battery_temp} -gt 53000 ]
	then
        	setMaxFreq 750
        	setMaxCharge 1600000
	elif [ ${battery_temp} -gt 51000 ]
	then
        	setMaxFreq 1000
        	setMaxCharge 1600000
	elif [ ${battery_temp} -gt 50000 ]
	then
        	setMaxFreq 1250
        	setMaxCharge 1700000
	elif [ ${battery_temp} -gt 49000 ]
	then
		setMaxFreq 1500
        	setMaxCharge 1800000
	elif [ ${battery_temp} -gt 48000 ]
	then
        	setMaxCharge 2000000
	fi

        if [ "$daemon" -eq 0 ]
        then
                echo ${core}:${core_temp} ${battery}:${battery_temp}
                echo MaxFreq: ${current_maxFreq} MaxCharge: ${current_maxCharge}
        fi

       	cpufreq-set -u ${current_maxFreq}MHz
       	echo ${current_maxCharge} > /dev/usb_max_current
       	
}

if [ "$1" = "daemon" ]
then
	daemon=1
	shift
else
	daemon=0
fi

for i in /sys/class/thermal/thermal_zone*
do
    name=$(cat ${i}/type)
    if [ "${name}" = "${core}" ]
    then
        core_dev="${i}/temp"
    fi
    
    if [ "${name}" = "${battery}" ]
    then
        battery_dev="${i}/temp"
    fi    
done

if [ -z "${core_dev}" ]
then
        echo could not find ${core}
        exit 1
fi

if [ -z "${battery_dev}" ]
then
        echo could not find ${battery}
        exit 1
fi

#echo $core_dev
#echo $battery_dev

if [ "$daemon" -eq 1 ]
then
	while true
	do
		doThermal
		sleep ${interval}
	done
else
	doThermal
fi

