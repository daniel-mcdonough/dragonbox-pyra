#!/bin/bash
#
# pyra-hwreport.sh — collect everything about this machine that an optimisation
# decision depends on, into one file.
#
#   ./pyra-hwreport.sh                  # print to stdout
#   ./pyra-hwreport.sh -o report.txt    # write to a file
#   ./pyra-hwreport.sh -s cpu,gpu       # only some sections
#   ./pyra-hwreport.sh -l               # list the sections
#
# Sections: cpu gpu mem display audio thermal kernel gl storage load
#
# Reads only. Changes nothing, needs no root, and touches nothing that can
# wedge the display — in particular it never toggles DPMS and never runs
# x11perf, both of which are documented in docs/troubleshooting.md as ways to
# hang this machine.
#
# WHY THIS EXISTS RATHER THAN A SET OF SMALLER SCRIPTS
#
# The repository already has measurement tools: pyra-cpu-attribution.sh for
# where the CPU goes, pyra-x-load-profile.sh for the X server's share,
# pyra-freq-profile.sh and pyra-thermal-probe.sh for frequency and heat. Those
# each run a workload and measure it. This one runs nothing — it is the
# static picture you attach to a bug report or hand to somebody starting a
# port, so that they do not have to ask what the machine is.
#
# Anything here that would take more than a moment, or that needs a load to
# mean anything, is deliberately left to those other scripts and named in the
# footer instead.
#
# See docs/hardware-overview.md for what the numbers mean.

set -u

OUT=
SECTIONS="cpu gpu mem display audio thermal kernel gl storage load"
ALL="$SECTIONS"

usage() { sed -n '2,/^$/s/^# \?//p' "$0"; exit "${1:-0}"; }

while getopts "o:s:lh" o; do
	case "$o" in
	o) OUT=$OPTARG ;;
	s) SECTIONS=$(echo "$OPTARG" | tr ',' ' ') ;;
	l) echo "$ALL" | tr ' ' '\n'; exit 0 ;;
	h) usage 0 ;;
	*) usage 1 ;;
	esac
done

want() { case " $SECTIONS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

hdr() { printf '\n=== %s %s\n' "$1" "$(printf '%.0s=' $(seq 1 $((66 - ${#1}))))"; }
kv()  { printf '  %-32s %s\n' "$1" "$2"; }

# print a file's contents, or a placeholder. Never fails the script.
cat_or() { [ -r "$1" ] && cat "$1" 2>/dev/null || echo "$2"; }

# first line of a file, trimmed
first() { [ -r "$1" ] && head -1 "$1" 2>/dev/null | tr -d '\n' || printf '%s' "n/a"; }

report() {

printf 'Pyra hardware report\n'
printf 'generated  %s\n' "$(date -Is)"
printf 'host       %s\n' "$(hostname 2>/dev/null || echo '?')"

# ---------------------------------------------------------------- cpu
if want cpu; then
	hdr "CPU"
	kv "model"        "$(awk -F: '/^model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')"
	kv "implementer"  "$(awk -F: '/^CPU implementer/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')"
	kv "part"         "$(awk -F: '/^CPU part/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')"
	kv "revision"     "$(awk -F: '/^CPU revision/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')"
	kv "cores online" "$(nproc)"
	kv "features"     "$(awk -F: '/^Features/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')"
	kv "hardware"     "$(awk -F: '/^Hardware/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')"

	echo
	kv "governor"     "$(first /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
	kv "cur / min / max MHz" \
	   "$(( $(first /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0) / 1000 )) / \
$(( $(first /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null || echo 0) / 1000 )) / \
$(( $(first /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo 0) / 1000 ))"
	kv "available steps kHz" "$(first /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies)"

	# The governor knobs that matter. sampling_down_factor is the one worth
	# 23% of burst latency; see docs/kernel-notes.md section 2.1.
	G=/sys/devices/system/cpu/cpufreq/ondemand
	if [ -d "$G" ]; then
		echo
		for k in up_threshold sampling_rate sampling_down_factor io_is_busy powersave_bias; do
			[ -r "$G/$k" ] && kv "ondemand.$k" "$(first "$G/$k")"
		done
		if [ "$(first "$G/sampling_down_factor")" = "1" ]; then
			echo "  NOTE: sampling_down_factor is 1. Setting it to 10 is worth ~23%"
			echo "        of burst latency — see device/pyra-governor-tune.sh"
		fi
	fi

	echo
	kv "cpuidle driver" "$(first /sys/devices/system/cpu/cpuidle/current_driver)"
	for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
		[ -d "$s" ] || continue
		kv "  $(basename "$s") $(first "$s/name")" "$(first "$s/desc")"
	done
fi

# ---------------------------------------------------------------- gpu
if want gpu; then
	hdr "GPU"
	for c in /sys/class/drm/card*; do
		[ -e "$c/device/uevent" ] || continue
		kv "$(basename "$c")" "$(awk -F= '/DRIVER=/{print $2}' "$c/device/uevent" 2>/dev/null | head -1)"
	done
	kv "DDK package" "$(dpkg-query -W -f='${Version}' omap5-sgx-ddk-um-linux 2>/dev/null || echo 'not installed')"
	kv "DDK path"    "$([ -d /opt/omap5-sgx-ddk-um-linux/lib ] && echo /opt/omap5-sgx-ddk-um-linux/lib || echo 'absent')"
	kv "pvr module"  "$(lsmod 2>/dev/null | awk '/pvrsrvkm/{print $1; exit}' || echo 'n/a')"
	kv "powervr.ini" "$(awk -F= '/WindowSystem/{print $2}' /etc/powervr.ini 2>/dev/null | tr -d ' \r' || echo 'n/a')"

	echo "  NOTE: the GPU rail sits at NOM (425 MHz), not its top operating point."
	echo "        See docs/known-limitations.md section 2.5 before touching it."
fi

# ---------------------------------------------------------------- mem
if want mem; then
	hdr "Memory"
	awk '/^(MemTotal|MemFree|MemAvailable|Cached|SwapTotal|AnonHugePages|Dirty)/ \
	     {printf "  %-32s %s %s\n", $1, $2, $3}' /proc/meminfo
	echo
	kv "swap devices" "$(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | tr '\n' ' ' || echo none)"
	kv "THP"          "$(first /sys/kernel/mm/transparent_hugepage/enabled)"
	echo
	echo "  Reference numbers (measured, docs/memory-optimization.md):"
	echo "    theoretical peak    ~8.5 GB/s      single-core memcpy   2130 MB/s"
	echo "    GC320 blit          1750 MB/s      GPU readback         62 MB/s"
	echo "    display scanout     221 MB/s continuous, unavoidable"
fi

# ---------------------------------------------------------------- display
if want display; then
	hdr "Display"
	for con in /sys/class/drm/card*-*/; do
		[ -r "$con/status" ] || continue
		ST=$(first "$con/status")
		[ "$ST" = "connected" ] || continue
		kv "$(basename "$con")" "$ST"
		[ -r "$con/modes" ] && kv "  modes" "$(head -3 "$con/modes" | tr '\n' ' ')"
	done
	if command -v xrandr >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
		echo
		xrandr 2>/dev/null | sed -n '1,6p' | sed 's/^/  /'
	fi
	for b in /sys/class/backlight/*/; do
		[ -r "$b/brightness" ] || continue
		kv "backlight $(basename "$b")" "$(first "$b/brightness") / $(first "$b/max_brightness")"
	done
	echo
	echo "  Panel is 720x1280 driven in DSI VIDEO mode — continuous scanout, no"
	echo "  partial update. Rotation to 1280x720 is done by the TILER, free."
fi

# ---------------------------------------------------------------- audio
if want audio; then
	hdr "Audio"
	kv "cards" "$(awk -F: '/\[/{print $2}' /proc/asound/cards 2>/dev/null | tr -d ' ' | tr '\n' ' ')"
	if command -v aplay >/dev/null 2>&1; then
		echo "  codec hw params (what the hardware will actually accept):"
		timeout 5 aplay --dump-hw-params -d 0 /dev/zero 2>&1 \
		  | awk '/^(FORMAT|CHANNELS|RATE|PERIOD_SIZE):/{print "    " $0}' \
		  || echo "    (could not query; device busy)"
	fi
	if command -v pactl >/dev/null 2>&1 && [ -n "${DISPLAY:-}${PULSE_SERVER:-}" ]; then
		echo "  live streams and the rate each asks for:"
		pactl list sink-inputs 2>/dev/null \
		  | awk '/Sample Specification|application.name/{print "    " $0}' | head -20
	fi
	echo
	echo "  The codec accepts ONLY S32_LE at 88200 or 96000 Hz. Anything else is"
	echo "  resampled: 10% of a core vs 2% for a matching rate. See docs/audio.md."
fi

# ---------------------------------------------------------------- thermal
if want thermal; then
	hdr "Thermal"
	ls /sys/class/thermal/thermal_zone*/temp >/dev/null 2>&1 \
	  || echo "  no readable thermal zones"
	for z in /sys/class/thermal/thermal_zone*; do
		[ -r "$z/temp" ] || continue
		T=$(first "$z/temp")
		printf '  %-14s %-16s %6.1f C\n' "$(basename "$z")" "$(first "$z/type")" \
		       "$(awk -v t="$T" 'BEGIN{print t/1000}')"
		for tp in "$z"/trip_point_*_temp; do
			[ -r "$tp" ] || continue
			TY=${tp%_temp}_type
			printf '      trip %-10s %6.1f C\n' "$(first "$TY")" \
			       "$(awk -v t="$(first "$tp")" 'BEGIN{print t/1000}')"
		done
	done
	echo
	echo "  Passive trip is 100 C on cpu_thermal. Two cores flat out with nothing"
	echo "  capping reached 107 C in under two minutes. Check the daemon is"
	echo "  actually capping:  sudo pyra-thermal-fix.sh --check"
fi

# ---------------------------------------------------------------- kernel
if want kernel; then
	hdr "Kernel and OS"
	kv "kernel"   "$(uname -r)"
	kv "arch"     "$(uname -m)"
	kv "cmdline"  "$(cat_or /proc/cmdline '')"
	kv "distro"   "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
	kv "gcc"      "$(gcc -dumpversion 2>/dev/null || echo 'not installed')"
	kv "uptime"   "$(awk '{printf "%.1f h", $1/3600}' /proc/uptime)"
	echo
	kv "spectre v2" "$(dmesg 2>/dev/null | grep -i -m1 'spectre' || echo '(dmesg not readable)')"
fi

# ---------------------------------------------------------------- gl
if want gl; then
	hdr "GL / GLES"
	DDK=/opt/omap5-sgx-ddk-um-linux/lib/libGLESv2.so.1
	if [ -n "${DISPLAY:-}" ] && command -v glxinfo >/dev/null 2>&1; then
		echo "  desktop GL through gl4es:"
		gl4es glxinfo -B 2>/dev/null \
		  | awk '/vendor string|renderer string|version string|direct rendering/{print "    " $0}' \
		  || echo "    (gl4es not available)"
	fi
	echo
	kv "DDK libGLESv2" "$([ -e "$DDK" ] && echo present || echo ABSENT)"
	kv "glvnd libGLESv2.so.2" \
	   "$([ -e /usr/lib/arm-linux-gnueabihf/libGLESv2.so.2 ] && echo present || echo absent)"
	echo
	echo "  To reach the hardware from SDL2, exactly two variables are needed:"
	echo "    SDL_VIDEO_X11_FORCE_EGL=1"
	echo "    SDL_VIDEO_GL_DRIVER=$DDK"
	echo "  Without them you get either a loud GLX failure or — worse — a context"
	echo "  whose every entry point is NULL. Always check GL_RENDERER at startup."
	echo
	echo "  Key limits (measured): MAX_VARYING_VECTORS=8, MAX_VERTEX_ATTRIBS=16,"
	echo "  MAX_TEXTURE_SIZE=4096, no GLES3, no GL_EXT_frag_depth, no blitFramebuffer."
fi

# ---------------------------------------------------------------- storage
if want storage; then
	hdr "Storage"
	df -h -x tmpfs -x devtmpfs 2>/dev/null | sed 's/^/  /' | head -10
	echo
	awk '$3 ~ /^(ext4|f2fs|btrfs|vfat)$/ {printf "  %-14s %-6s %s\n", $1, $3, $4}' /proc/mounts
fi

# ---------------------------------------------------------------- load
if want load; then
	hdr "Current load"
	kv "loadavg" "$(cut -d' ' -f1-3 /proc/loadavg)"
	echo "  top consumers right now:"
	ps -eo pcpu,comm --sort=-pcpu 2>/dev/null | head -8 | sed 's/^/    /'
	echo
	echo "  NOTE: a percentage read here depends on the clock the governor happens"
	echo "  to be at — identical work reads 26% at 625 MHz and 11% at 1500 MHz."
	echo "  Use pyra-cpu-attribution.sh and compare ratios, not absolutes."
fi

hdr "Where to go next"
cat <<'FOOTER'
  This report is static. For anything that needs a running workload:

    pyra-cpu-attribution.sh    where all the busy CPU goes, by process
    pyra-x-load-profile.sh     the X server's share, and whether the 2D engine moved
    pyra-freq-profile.sh       frequency behaviour under a single-core load
    pyra-thermal-probe.sh      temperatures through a load, with an abort at the trip
    pyra-ceiling-cost.sh       what each frequency rung costs in latency and watts

  Read docs/hardware-overview.md first, then docs/profiling-guide.md before
  measuring anything — four documented traps on this machine produce confident,
  reproducible, wrong numbers.

  Do NOT run x11perf. It toggles DPMS around every test and that can wedge the
  display driver hard enough to need a reboot.
FOOTER

}

if [ -n "$OUT" ]; then
	report > "$OUT" 2>&1
	echo "written to $OUT"
else
	report
fi
