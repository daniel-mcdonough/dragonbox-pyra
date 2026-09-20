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

	for (;;) {
		put_dec10(line + BEATS_OFF, ++beats);
		spin();
	}
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
