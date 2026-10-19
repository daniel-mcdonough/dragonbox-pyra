/*
 * main.c -- what the two Cortex-M4s actually do.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * The whole program is a heartbeat written into a buffer the kernel exports
 * as /sys/kernel/debug/remoteproc/remoteprocN/trace0. That is deliberately
 * the smallest thing that cannot pass by accident:
 *
 *   - m4_trace lives in .bss, so it is not in the ELF image. The loader
 *     zeroes it on every boot (rproc_elf_load_segments() memsets the
 *     memsz-filesz tail), so ANY non-zero byte in it afterwards was written
 *     by an M4 and cannot be a read-back of the file we installed.
 *
 *   - the beats counters advance. A test that only checked for text could
 *     be satisfied by a core that wrote one line and died; two samples a
 *     second apart cannot.
 *
 *   - core1's counter starts at zero and is only ever touched by the second
 *     core, so it answers "did the second M4 come out of reset too" on its
 *     own.
 *
 * The firmware touches no peripheral and no address outside its own 1 MiB
 * carveout. That keeps it inside the AMMU's reset window (see README.md)
 * and means a bug here cannot wedge the L3 interconnect -- it can only
 * scribble on memory the kernel already handed to the IPU.
 */
#include <stdint.h>

#define TRACE_LEN	4096u
#define STACK_SIZE	4096u

/*
 * .bss: zeroed by the loader, not present in the file. See above.
 * volatile because Linux reads it behind the compiler's back.
 */
volatile char m4_trace[TRACE_LEN];

/* Two stacks, one per core; start.S picks by index. Kept in one array so
 * the order is defined, which m4_fault() relies on. */
uint8_t m4_stacks[2][STACK_SIZE] __attribute__((aligned(8)));

/*
 * .data, not .bss, and explicitly so: these are part of the loaded image,
 * which makes them a known 0 at every boot rather than a zero we would be
 * trusting the loader to have written.
 */
volatile uint32_t m4_core_claim __attribute__((section(".data"))) = 0;
volatile uint32_t m4_ready __attribute__((section(".data"))) = 0;

/* "core0: state=start beats=0000000000" -- offsets derived from the text
 * itself so they cannot drift out of step with it. */
#define LINE_TEXT	"coreN: state=start beats=0000000000\n"
#define STATE_OFF	(sizeof("coreN: state=") - 1)
#define BEATS_OFF	(sizeof("coreN: state=start beats=") - 1)
#define STATE_LEN	5u	/* start / alive / FAULT, all the same width */
#define BEATS_LEN	10u

static const char banner[] =
	"pyra-m4-hello: running on the OMAP5432 IPU (2 x Cortex-M4)\n"
	"text carveout da=0x00000000 len=0x00100000\n";

#ifdef PYRA_M4_DEMO
/*
 * The demo build adds two lines per core:
 *
 *   core0 cpu-cycles=0123456789
 *   core0 clock-src=systick dwt-ctrl=0x40000000 dwt-fault=0 systick=0x00010005
 *
 * The first is a free-running count of the core's own clock, rewritten on
 * every beat. Linux samples it against its own clock and the difference is
 * the M4's actual clock rate -- which docs/m4-ipu.md could only bound from
 * above (425 MHz is the gate clock; TI's figure is about half that). The
 * second says where the count came from, and why the better source was not
 * used. The heartbeat build leaves all of this out, so the firmware that was
 * verified on hardware is unchanged.
 *
 * Two sources, in order of preference:
 *
 *   dwt      the DWT cycle counter: 32 bits, exact, needs no polling. But it
 *            is optional in ARMv7-M, and the IPU's M4s do not have one: the
 *            first run on the Pyra (2026-10-18) read DWT_CTRL = 0x4f000000,
 *            four comparators with NOCYCCNT, NOPRFCNT, NOEXTTRIG and
 *            NOTRCPKT all set. Kept, and tried first, so the firmware still
 *            says so on any unit where that is not true.
 *   systick  SysTick, in the System Control Space that every ARMv7-M core
 *            has, clocked from the core when CLKSOURCE reads back 1. It is
 *            only 24 bits -- about 40 ms at 425 MHz -- so spin_poll() polls it
 *            every iteration and accumulates the deltas into 32 bits.
 *            "sysext" means CLKSOURCE would not stick: the count is then the
 *            implementation's reference clock, not the core's, and is
 *            reported as such rather than passed off as a core clock.
 *
 * The space after coreN, not a colon, keeps find_line() and the
 * "^coreN: state=" patterns in pyra-m4-run.sh from ever matching these.
 */
#define CYC_TEXT	"coreN cpu-cycles=0000000000\n"
#define CYC_OFF		(sizeof("coreN cpu-cycles=") - 1)
#define SRC_TEXT	"coreN clock-src=none    dwt-ctrl=0x00000000 dwt-fault=0 systick=0x00000000\n"
#define SRC_OFF		(sizeof("coreN clock-src=") - 1)
#define SRC_LEN		7u
#define DWTC_OFF	(sizeof("coreN clock-src=none    dwt-ctrl=") - 1)
#define DWTF_OFF	(sizeof("coreN clock-src=none    dwt-ctrl=0x00000000 dwt-fault=") - 1)
#define STCSR_OFF	(sizeof("coreN clock-src=none    dwt-ctrl=0x00000000 dwt-fault=0 systick=") - 1)

/* All in the Private Peripheral Bus, which is inside the core: these never
 * go through the AMMU or the IOMMU, so they are as safe to touch as the
 * carveout is. */
#define SYST_CSR	(*(volatile uint32_t *)0xe000e010u)
#define SYST_RVR	(*(volatile uint32_t *)0xe000e014u)
#define SYST_CVR	(*(volatile uint32_t *)0xe000e018u)
#define SCB_CCR		(*(volatile uint32_t *)0xe000ed14u)
#define SCB_CFSR	(*(volatile uint32_t *)0xe000ed28u)
#define DEMCR		(*(volatile uint32_t *)0xe000edfcu)
#define DWT_CTRL	(*(volatile uint32_t *)0xe0001000u)
#define DWT_CYCCNT	(*(volatile uint32_t *)0xe0001004u)
#define DWT_LAR		(*(volatile uint32_t *)0xe0001fb0u)

#define SYST_ENABLE	(1u << 0)
#define SYST_CLKSOURCE	(1u << 2)	/* 1 = the processor clock */
#define SYST_MASK	0x00ffffffu
#define CCR_BFHFNMIGN	(1u << 8)
#define CFSR_BFSR	(0xffu << 8)
#define DEMCR_TRCENA	(1u << 24)
#define DWT_NOCYCCNT	(1u << 25)
#define DWT_CYCCNTENA	(1u << 0)

enum clk_src { CLK_NONE, CLK_DWT, CLK_SYSTICK, CLK_SYSEXT };
static const char *const clk_name[] = { "none   ", "dwt    ", "systick", "sysext " };

/*
 * Probe the DWT the architected way rather than by reading it and hoping:
 * with FAULTMASK set (priority -1) and CCR.BFHFNMIGN set, a data bus fault
 * on a load is ignored instead of taken, and recorded in BFSR. A missing DWT
 * therefore costs nothing but a fallback, instead of sending the core to
 * m4_fault() and taking the heartbeat down with it.
 *
 * Nothing is written into the DWT until the read has come back clean.
 */
static int dwt_start(uint32_t *ctrl_out, int *fault_out)
{
	uint32_t ctrl, a, b;
	int faulted;

	SCB_CFSR = CFSR_BFSR;		/* write-one-to-clear */
	SCB_CCR |= CCR_BFHFNMIGN;
	__asm__ volatile ("dsb\n\tisb\n\tcpsid f" ::: "memory");

	DEMCR |= DEMCR_TRCENA;		/* SCS: always present */
	__asm__ volatile ("dsb" ::: "memory");
	ctrl = DWT_CTRL;
	__asm__ volatile ("dsb" ::: "memory");

	__asm__ volatile ("cpsie f\n\tisb" ::: "memory");
	SCB_CCR &= ~CCR_BFHFNMIGN;
	faulted = (SCB_CFSR & CFSR_BFSR) != 0;
	SCB_CFSR = CFSR_BFSR;

	*ctrl_out = ctrl;
	*fault_out = faulted;
	if (faulted || (ctrl & DWT_NOCYCCNT))
		return 0;

	DWT_LAR = 0xc5acce55u;		/* RAZ/WI on an M4 without the lock */
	DWT_CYCCNT = 0;
	DWT_CTRL = ctrl | DWT_CYCCNTENA;

	/* Present but stuck is "absent" too. */
	a = DWT_CYCCNT;
	b = DWT_CYCCNT;
	return a != b;
}

/*
 * SysTick with no interrupt: TICKINT stays 0, because the SysTick vector in
 * start.S is fault_handler. Returns CLK_SYSTICK, CLK_SYSEXT or CLK_NONE.
 */
static enum clk_src systick_start(uint32_t *csr_out)
{
	uint32_t csr, a, b;

	SYST_CSR = 0;
	SYST_RVR = SYST_MASK;
	SYST_CVR = 0;			/* any write clears it */
	SYST_CSR = SYST_ENABLE | SYST_CLKSOURCE;
	csr = SYST_CSR;
	*csr_out = csr;

	a = SYST_CVR;
	b = SYST_CVR;
	if (!(csr & SYST_ENABLE) || a == b)
		return CLK_NONE;
	return (csr & SYST_CLKSOURCE) ? CLK_SYSTICK : CLK_SYSEXT;
}

/*
 * The 24-bit down-counter extended to 32 bits. Correct as long as it is
 * called at least once per wrap, which spin_poll() does many times over.
 */
struct systick_acc {
	uint32_t prev;
	uint32_t total;
};

static void systick_poll(struct systick_acc *s)
{
	uint32_t now = SYST_CVR;

	s->total += (s->prev - now) & SYST_MASK;
	s->prev = now;
}
#endif

static void put(volatile char **d, const char *s)
{
	while (*s)
		*(*d)++ = *s++;
}

static void put_hex32(volatile char **d, uint32_t v)
{
	static const char hex[] = "0123456789abcdef";
	int i;

	*(*d)++ = '0';
	*(*d)++ = 'x';
	for (i = 28; i >= 0; i -= 4)
		*(*d)++ = hex[(v >> i) & 0xf];
}

/* Most significant digit first, so a reader that catches a half-written
 * counter sees a plausible number rather than a reversed one. */
static void put_dec10(volatile char *p, uint32_t v)
{
	char tmp[BEATS_LEN];
	unsigned i;

	for (i = BEATS_LEN; i-- > 0; ) {
		tmp[i] = (char)('0' + (v % 10u));
		v /= 10u;
	}
	for (i = 0; i < BEATS_LEN; i++)
		p[i] = tmp[i];
}

static void put_state(volatile char *line, const char *s)
{
	unsigned i;

	for (i = 0; i < STATE_LEN; i++)
		line[STATE_OFF + i] = s[i];
}

/*
 * Find "coreN: " in the buffer. Both cores locate their own line this way
 * rather than sharing a pointer, so there is nothing to publish between
 * them beyond m4_ready.
 */
static volatile char *find_line(unsigned id)
{
	unsigned i;

	for (i = 0; i + 7 < TRACE_LEN; i++) {
		if (m4_trace[i] == 'c' && m4_trace[i + 1] == 'o' &&
		    m4_trace[i + 2] == 'r' && m4_trace[i + 3] == 'e' &&
		    m4_trace[i + 4] == (char)('0' + id) &&
		    m4_trace[i + 5] == ':')
			return &m4_trace[i];
	}
	return 0;
}

#ifdef PYRA_M4_DEMO
/* As find_line(), for a pattern whose fifth character is the N in coreN. */
static volatile char *find_tagged(unsigned id, const char *pat)
{
	unsigned i, j, n = 0;

	while (pat[n])
		n++;
	for (i = 0; i + n < TRACE_LEN; i++) {
		for (j = 0; j < n; j++) {
			char want = (j == 4) ? (char)('0' + id) : pat[j];

			if (m4_trace[i + j] != want)
				break;
		}
		if (j == n)
			return &m4_trace[i];
	}
	return 0;
}

static void put_hex32_at(volatile char *p, uint32_t v)
{
	put_hex32(&p, v);
}
#endif

static void write_template(void)
{
	volatile char *d = m4_trace;
	unsigned id;

	put(&d, banner);
	put(&d, "trace da=");
	put_hex32(&d, (uint32_t)(uintptr_t)m4_trace);
	put(&d, " len=4096\n");

	for (id = 0; id < 2; id++) {
		const char *s = LINE_TEXT;
		volatile char *line = d;

		put(&d, s);
		line[4] = (char)('0' + id);	/* the N in coreN */
	}
#ifdef PYRA_M4_DEMO
	put(&d, "mode: demo, core clock counter per core\n");
	for (id = 0; id < 2; id++) {
		volatile char *line = d;

		put(&d, CYC_TEXT);
		line[4] = (char)('0' + id);
		line = d;
		put(&d, SRC_TEXT);
		line[4] = (char)('0' + id);
	}
#endif
	*d = '\0';	/* trace0 is read with strnlen(); keep it a string */
}

#ifndef PYRA_M4_DEMO
static void spin(void)
{
	/* volatile so this survives -Os. Meant as a few ms; measured on
	 * 2026-10-18 at about 0.6 s, because with the unicache off every
	 * fetch and every access to i goes to DDR (docs/m4-ipu.md). Still
	 * one beat a second or so, which is all the test needs. */
	volatile uint32_t i;

	for (i = 0; i < 300000u; i++)
		;
}
#else
/*
 * spin(), polling SysTick on every iteration when that is the clock, and
 * republishing the count every PUBLISH_EVERY iterations -- a few ms here.
 *
 * Not only on each beat, which is what the first version did. A beat takes
 * over a second on this hardware (the loop runs uncached from DDR), so Linux
 * sampling once a second saw the count jump by one beat's worth of cycles or
 * not at all, and divided that by one second -- which printed 293 MHz and
 * meant nothing. Publishing much faster than Linux samples is what makes
 * count/time a clock rate.
 */
#define PUBLISH_EVERY	1024u

static void spin_poll(enum clk_src clk, struct systick_acc *s,
		      volatile char *cyc)
{
	volatile uint32_t i;

	for (i = 0; i < 300000u; i++) {
		if (clk == CLK_SYSTICK || clk == CLK_SYSEXT)
			systick_poll(s);
		if (cyc && (i % PUBLISH_EVERY) == 0) {
			if (clk == CLK_DWT)
				put_dec10(cyc + CYC_OFF, DWT_CYCCNT);
			else if (clk != CLK_NONE)
				put_dec10(cyc + CYC_OFF, s->total);
		}
	}
}
#endif

void m4_main(unsigned id)
{
	volatile char *line;
	uint32_t beats = 0;

	if (id == 0) {
		write_template();
		m4_ready = 1;		/* release core 1 */
	} else {
		while (m4_ready == 0)
			;
	}

	line = find_line(id);
	if (!line)
		for (;;)		/* cannot report anything; just stop */
			;

	put_state(line, "alive");

#ifdef PYRA_M4_DEMO
	{
		volatile char *cyc = find_tagged(id, "coreN cpu-cycles=");
		volatile char *src = find_tagged(id, "coreN clock-src=");
		struct systick_acc st = { 0, 0 };
		uint32_t dwt_ctrl = 0, st_csr = 0;
		int dwt_fault = 0;
		enum clk_src clk = CLK_NONE;
		unsigned i;

		if (dwt_start(&dwt_ctrl, &dwt_fault))
			clk = CLK_DWT;
		else
			clk = systick_start(&st_csr);
		if (clk == CLK_SYSTICK || clk == CLK_SYSEXT)
			st.prev = SYST_CVR;

		if (src) {
			for (i = 0; i < SRC_LEN; i++)
				src[SRC_OFF + i] = clk_name[clk][i];
			put_hex32_at(src + DWTC_OFF, dwt_ctrl);
			src[DWTF_OFF] = dwt_fault ? '1' : '0';
			put_hex32_at(src + STCSR_OFF, st_csr);
		}
		if (cyc && clk == CLK_NONE)
			for (i = 0; i < BEATS_LEN; i++)
				cyc[CYC_OFF + i] = "none      "[i];

		for (;;) {
			put_dec10(line + BEATS_OFF, ++beats);
			spin_poll(clk, &st, cyc);
		}
	}
#else
	for (;;) {
		put_dec10(line + BEATS_OFF, ++beats);
		spin();
	}
#endif
}

/*
 * Any fault lands here. The faulting core works out which one it is from
 * its own stack pointer -- the exception entry pushed onto the stack
 * start.S gave it, and the two stacks are adjacent in a known order.
 */
void m4_fault(void)
{
	uint32_t sp;
	unsigned id;
	volatile char *line;

	__asm__ volatile ("mov %0, sp" : "=r" (sp));
	id = (sp > (uint32_t)(uintptr_t)&m4_stacks[1][0]) ? 1u : 0u;

	if (m4_ready) {
		line = find_line(id);
		if (line)
			put_state(line, "FAULT");
	}
	for (;;)
		;
}
