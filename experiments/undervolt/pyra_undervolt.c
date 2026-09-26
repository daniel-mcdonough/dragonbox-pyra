// SPDX-License-Identifier: GPL-2.0
/*
 * pyra_undervolt: lower the voltage of one CPU operating point at runtime.
 *
 * The OMAP5's CPU table (cpu0 operating-points, driving smps123) gives each
 * frequency a fixed voltage from the device tree, not one calibrated for this
 * chip.  This module rewrites the voltage of an existing point in the live OPP
 * table with dev_pm_opp_adjust_voltage(), so a candidate can be tried without
 * a new dtb and a reboot.  Unloading the module, or rebooting, puts every
 * point back.
 *
 * 5.6 has dev_pm_opp_adjust_voltage() but does not export it, and removing and
 * re-adding a point that came from the device tree unbalances the OPP table's
 * reference count on this kernel (dev_pm_opp_remove() drops a table reference
 * only dev_pm_opp_add() takes).  kallsyms_lookup_name() is still exported in
 * 5.6, so the function is found by name.
 *
 * Interface (root):
 *   cat  /sys/module/pyra_undervolt/parameters/table
 *   echo "625000 880000" > /sys/module/pyra_undervolt/parameters/set    (kHz uV)
 *   echo "625000 0"      > /sys/module/pyra_undervolt/parameters/set    (restore)
 *
 * The OPP core applies a point's voltage only on a transition to it, so a
 * change is refused while the CPU runs at that frequency: move the pin away,
 * change the point, move the pin back.  undervolt.sh does that.
 *
 * Limits, enforced here and not configurable: points at or below MAX_KHZ only;
 * never above the device tree's voltage; at most MAX_DROP_UV below it; on the
 * Palmas SMPS's 10 mV grid (510 mV + n x 10 mV), which the OPP core would
 * otherwise not check for an adjusted point.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kallsyms.h>
#include <linux/cpu.h>
#include <linux/cpufreq.h>
#include <linux/pm_opp.h>
#include <linux/mutex.h>

#define MAX_KHZ		1000000UL
#define MAX_DROP_UV	100000UL
#define GRID_BASE_UV	510000UL
#define GRID_STEP_UV	10000UL
#define MAX_POINTS	32

typedef int (*adjust_fn_t)(struct device *dev, unsigned long freq,
			   unsigned long u_volt, unsigned long u_volt_min,
			   unsigned long u_volt_max);

struct point {
	unsigned long hz;
	unsigned long orig_uv;
	bool changed;
};

static adjust_fn_t adjust_voltage;
static struct device *cpu_dev;
static struct point points[MAX_POINTS];
static int npoints;
static DEFINE_MUTEX(lock);

static unsigned long live_uv(unsigned long hz)
{
	struct dev_pm_opp *opp;
	unsigned long uv;

	opp = dev_pm_opp_find_freq_exact(cpu_dev, hz, true);
	if (IS_ERR(opp))
		return 0;
	uv = dev_pm_opp_get_voltage(opp);
	dev_pm_opp_put(opp);
	return uv;
}

static struct point *find_point(unsigned long hz)
{
	int i;

	for (i = 0; i < npoints; i++)
		if (points[i].hz == hz)
			return &points[i];
	return NULL;
}

static int set_point(struct point *p, unsigned long uv)
{
	int ret;

	ret = adjust_voltage(cpu_dev, p->hz, uv, uv, uv);
	if (ret)
		return ret;
	p->changed = uv != p->orig_uv;
	pr_info("pyra_undervolt: %lu kHz -> %lu uV (device tree %lu uV)\n",
		p->hz / 1000, uv, p->orig_uv);
	return 0;
}

static int param_set_point(const char *val, const struct kernel_param *kp)
{
	unsigned long khz, uv;
	struct point *p;
	int ret;

	if (sscanf(val, "%lu %lu", &khz, &uv) != 2)
		return -EINVAL;

	p = find_point(khz * 1000);
	if (!p) {
		pr_err("pyra_undervolt: no operating point at %lu kHz\n", khz);
		return -ENOENT;
	}
	if (uv == 0)
		uv = p->orig_uv;

	if (khz > MAX_KHZ) {
		pr_err("pyra_undervolt: %lu kHz is above the %lu kHz limit\n",
		       khz, MAX_KHZ);
		return -EPERM;
	}
	if (uv > p->orig_uv) {
		pr_err("pyra_undervolt: %lu uV is above the device tree's %lu uV\n",
		       uv, p->orig_uv);
		return -EPERM;
	}
	if (p->orig_uv - uv > MAX_DROP_UV) {
		pr_err("pyra_undervolt: %lu uV is more than %lu uV below %lu uV\n",
		       uv, MAX_DROP_UV, p->orig_uv);
		return -EPERM;
	}
	if (uv < GRID_BASE_UV || (uv - GRID_BASE_UV) % GRID_STEP_UV) {
		pr_err("pyra_undervolt: %lu uV is not on the SMPS's 10 mV grid\n",
		       uv);
		return -EINVAL;
	}

	mutex_lock(&lock);
	if (cpufreq_quick_get(0) == khz) {
		pr_err("pyra_undervolt: the CPU is running at %lu kHz; move off it first\n",
		       khz);
		ret = -EBUSY;
	} else {
		ret = set_point(p, uv);
	}
	mutex_unlock(&lock);
	return ret;
}

static const struct kernel_param_ops set_ops = {
	.set = param_set_point,
};
module_param_cb(set, &set_ops, NULL, 0200);
MODULE_PARM_DESC(set, "\"<kHz> <uV>\": set one point's voltage; uV 0 restores it");

static int param_get_table(char *buf, const struct kernel_param *kp)
{
	unsigned int cur = cpufreq_quick_get(0);
	int i, n = 0;

	mutex_lock(&lock);
	for (i = 0; i < npoints; i++) {
		struct point *p = &points[i];

		n += scnprintf(buf + n, PAGE_SIZE - n, "%8lu %7lu %7lu%s%s\n",
			       p->hz / 1000, p->orig_uv, live_uv(p->hz),
			       p->changed ? " changed" : "",
			       p->hz / 1000 == cur ? " running" : "");
	}
	mutex_unlock(&lock);
	return n;
}

static const struct kernel_param_ops table_ops = {
	.get = param_get_table,
};
module_param_cb(table, &table_ops, NULL, 0444);
MODULE_PARM_DESC(table, "kHz, device-tree uV, live uV per operating point");

static int __init pyra_undervolt_init(void)
{
	unsigned long hz = 0;
	struct dev_pm_opp *opp;

	adjust_voltage = (adjust_fn_t)kallsyms_lookup_name("dev_pm_opp_adjust_voltage");
	if (!adjust_voltage) {
		pr_err("pyra_undervolt: dev_pm_opp_adjust_voltage not found\n");
		return -ENOENT;
	}

	cpu_dev = get_cpu_device(0);
	if (!cpu_dev)
		return -ENODEV;

	while (npoints < MAX_POINTS) {
		opp = dev_pm_opp_find_freq_ceil(cpu_dev, &hz);
		if (IS_ERR(opp))
			break;
		points[npoints].hz = hz;
		points[npoints].orig_uv = dev_pm_opp_get_voltage(opp);
		dev_pm_opp_put(opp);
		npoints++;
		hz++;
	}
	if (!npoints) {
		pr_err("pyra_undervolt: cpu0 has no operating points\n");
		return -ENODEV;
	}

	pr_info("pyra_undervolt: %d operating points on cpu0\n", npoints);
	return 0;
}

static void __exit pyra_undervolt_exit(void)
{
	unsigned int cur = cpufreq_quick_get(0);
	int i;

	mutex_lock(&lock);
	for (i = 0; i < npoints; i++) {
		struct point *p = &points[i];

		if (!p->changed)
			continue;
		if (set_point(p, p->orig_uv))
			pr_err("pyra_undervolt: could not restore %lu kHz\n",
			       p->hz / 1000);
		else if (p->hz / 1000 == cur)
			pr_warn("pyra_undervolt: %lu kHz is running; its lowered voltage stays until the next frequency change\n",
				p->hz / 1000);
	}
	mutex_unlock(&lock);
}

module_init(pyra_undervolt_init);
module_exit(pyra_undervolt_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Lower one CPU operating point's voltage at runtime, for undervolt testing");
