/*
 * start.S -- reset entry for the Pyra IPU test firmware.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * BOTH Cortex-M4s arrive here. The device tree gives the IPU
 * resets = <&prm_core 0>, <&prm_core 1>, which are RM_IPU_RSTCTRL bits 0
 * and 1 -- CPU0 and CPU1 (bit 2, the MMU/cache reset, belongs to
 * omap-iommu). omap_rproc_start() deasserts both, so the second M4 starts
 * fetching from device address 0 as well, and every line below runs twice.
 * TI hit the same thing and answered it with BIOS.smpEnabled = true.
 *
 * Neither core can ask the hardware which one it is, so the first one here
 * claims the name "core 0" by writing m4_core_claim. That read-modify-write
 * is not atomic and does not need to be: reset_control_array_deassert()
 * deasserts one line at a time, and omap_reset_deassert() polls RSTST until
 * the first reset has completed before the second one is written
 * (drivers/soc/ti/omap_prm.c). Core 0 is therefore microseconds ahead, not
 * cycles. If that ever stopped being true the failure is visible rather than
 * dangerous: both cores would claim 0 and the trace would show core1 never
 * reaching its loop.
 *
 * Nothing here needs a stack, because nothing here can use one until it
 * knows which of the two stacks is its own.
 */
	.syntax	unified
	.cpu	cortex-m4
	.thumb

	.section .vectors, "a", %progbits
	.align	2
	.global	__vectors
__vectors:
	.word	m4_stacks + 4096	/* 0  initial MSP, core 0's stack top */
	.word	reset_handler		/* 1  Reset */
	.word	fault_handler		/* 2  NMI */
	.word	fault_handler		/* 3  HardFault */
	.word	fault_handler		/* 4  MemManage */
	.word	fault_handler		/* 5  BusFault */
	.word	fault_handler		/* 6  UsageFault */
	.word	0, 0, 0, 0		/* 7-10 reserved */
	.word	fault_handler		/* 11 SVCall */
	.word	fault_handler		/* 12 DebugMon */
	.word	0			/* 13 reserved */
	.word	fault_handler		/* 14 PendSV */
	.word	fault_handler		/* 15 SysTick */

	.text
	.align	2
	.thumb_func
	.type	reset_handler, %function
	.global	reset_handler
reset_handler:
	ldr	r0, =m4_core_claim
	ldr	r1, [r0]
	cbnz	r1, 1f

	/* first one here: take core 0 and the first stack */
	movs	r2, #1
	str	r2, [r0]
	ldr	sp, =(m4_stacks + 4096)
	movs	r0, #0
	b	2f
1:
	/* second one here: core 1, the second stack */
	ldr	sp, =(m4_stacks + 8192)
	movs	r0, #1
2:
	bl	m4_main
3:
	b	3b			/* m4_main never returns */
	.size	reset_handler, . - reset_handler

	.align	2
	.thumb_func
	.type	fault_handler, %function
	.global	fault_handler
fault_handler:
	bl	m4_fault
4:
	b	4b
	.size	fault_handler, . - fault_handler

	.end
