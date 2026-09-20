/*
 * m4.ld -- everything lives inside the 1 MiB carveout the resource table
 * asks for, at device address 0.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Device address 0 is not a choice. The IPU node has no ti,bootreg (only
 * the DSP does), so omap_rproc_start() never writes a boot address and the
 * M4s fetch their vector table from 0 the way any Cortex-M does. The ELF
 * entry point is therefore decoration; the first two words at 0 are what
 * actually boots this.
 *
 * Nothing is placed outside 0x00000000..0x000fffff. That keeps every
 * access inside the AMMU's reset-state mapping, which is what lets this
 * firmware skip AMMU programming entirely -- see README.md.
 */
OUTPUT_FORMAT("elf32-littlearm")
OUTPUT_ARCH(arm)
ENTRY(reset_handler)

MEMORY
{
	CARVEOUT (rwx) : ORIGIN = 0x00000000, LENGTH = 1M
}

SECTIONS
{
	.vectors 0x00000000 : {
		KEEP(*(.vectors))
	} > CARVEOUT

	.text : ALIGN(4) {
		*(.text .text.*)
		*(.rodata .rodata.*)
	} > CARVEOUT

	.data : ALIGN(4) {
		*(.data .data.*)
	} > CARVEOUT

	.resource_table : ALIGN(4) {
		KEEP(*(.resource_table))
	} > CARVEOUT

	/*
	 * Left as a normal NOBITS section on purpose. The loader zeroes
	 * memsz-filesz for the segment that contains it, so m4_trace starts
	 * at zero on every boot without being carried in the file -- which
	 * is the whole basis for "anything in the trace was written by an
	 * M4". Marking it NOLOAD would take it out of the segment and lose
	 * that.
	 */
	.bss : ALIGN(8) {
		__bss_start = .;
		*(.bss .bss.*)
		*(COMMON)
		. = ALIGN(8);
		__bss_end = .;
	} > CARVEOUT

	__image_end = .;

	/DISCARD/ : {
		*(.ARM.exidx*)
		*(.ARM.attributes)
		*(.comment)
		*(.note*)
	}
}

ASSERT(__image_end <= 0x00100000, "firmware does not fit the 1 MiB carveout")
