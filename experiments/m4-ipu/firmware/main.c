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
 * The demo build adds one line per core:
 *
 *   core0 cpu-cycles=0123456789
 *
 * the core's own DWT cycle counter, rewritten on every beat. Linux samples
 * it against its own clock and the difference is the M4's actual clock rate
 * -- which docs/m4-ipu.md could only bound from above (425 MHz is the gate
 * clock; TI's figure is about half that). The heartbeat build leaves this
 * out entirely, so the firmware that was verified on hardware is unchanged.
 *
 * The space after coreN, not a colon, keeps find_line() and the
 * "^coreN: state=" patterns in pyra-m4-run.sh from ever matching this line.
 */
#define CYC_TEXT	"coreN cpu-cycles=0000000000\n"
#define CYC_OFF		(sizeof("coreN cpu-cycles=") - 1)

/* All in the Private Peripheral Bus, which is inside the core: these never
 * go through the AMMU or the IOMMU, so they are as safe to touch as the
 * carveout is. */
#define SCB_CCR		(*(volatile uint32_t *)0xe000ed14u)
#define SCB_CFSR	(*(volatile uint32_t *)0xe000ed28u)
#define DEMCR		(*(volatile uint32_t *)0xe000edfcu)
#define DWT_CTRL	(*(volatile uint32_t *)0xe0001000u)
#define DWT_CYCCNT	(*(volatile uint32_t *)0xe0001004u)
#define DWT_LAR		(*(volatile uint32_t *)0xe0001fb0u)

#define CCR_BFHFNMIGN	(1u << 8)
#define CFSR_BFSR	(0xffu << 8)
#define DEMCR_TRCENA	(1u << 24)
#define DWT_NOCYCCNT	(1u << 25)
#define DWT_CYCCNTENA	(1u << 0)

/*
 * DWT is optional in ARMv7-M, and nothing documents whether TI fitted one
 * to the IPU. So probe for it the architected way rather than by reading it
 * and hoping: with FAULTMASK set (priority -1) and CCR.BFHFNMIGN set, a
 * data bus fault on a load is ignored instead of taken, and recorded in
 * BFSR. A missing DWT therefore reports "no-dwt" instead of sending the
 * core to m4_fault() and taking the heartbeat down with it.
 *
 * Nothing is written into the DWT until the read has come back clean.
 */
static int dwt_start(void)
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

	if (faulted || (ctrl & DWT_NOCYCCNT))
		return 0;

	DWT_LAR = 0xc5acce55u;		/* RAZ/WI on an M4 without the lock */
	DWT_CYCCNT = 0;
	DWT_CTRL = ctrl | DWT_CYCCNTENA;

	/* Present but stuck at zero is "absent" too. */
	a = DWT_CYCCNT;
	b = DWT_CYCCNT;
	return a != b;
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
/* As find_line(), for "coreN cpu-cycles=". */
static volatile char *find_cyc_line(unsigned id)
{
	static const char pat[] = "coreN cpu-cycles=";
	unsigned i, j;

	for (i = 0; i + sizeof(pat) < TRACE_LEN; i++) {
		for (j = 0; j < sizeof(pat) - 1; j++) {
			char want = (j == 4) ? (char)('0' + id) : pat[j];

			if (m4_trace[i + j] != want)
				break;
		}
		if (j == sizeof(pat) - 1)
			return &m4_trace[i];
	}
	return 0;
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
	put(&d, "mode: demo, DWT cycle counter per core\n");
	for (id = 0; id < 2; id++) {
		volatile char *line = d;

		put(&d, CYC_TEXT);
		line[4] = (char)('0' + id);
	}
#endif
	*d = '\0';	/* trace0 is read with strnlen(); keep it a string */
}

static void spin(void)
{
	/* volatile so this survives -Os; roughly a few ms on the IPU, which
	 * is fast enough to see motion in a one-second sample and slow
	 * enough not to hammer DDR from two cores. */
	volatile uint32_t i;

	for (i = 0; i < 300000u; i++)
		;
}

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
		volatile char *cyc = find_cyc_line(id);
		int have_dwt = dwt_start();
		unsigned i;

		if (cyc && !have_dwt)
			for (i = 0; i < BEATS_LEN; i++)
				cyc[CYC_OFF + i] = "no-dwt    "[i];

		for (;;) {
			put_dec10(line + BEATS_OFF, ++beats);
			if (cyc && have_dwt)
				put_dec10(cyc + CYC_OFF, DWT_CYCCNT);
			spin();
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
