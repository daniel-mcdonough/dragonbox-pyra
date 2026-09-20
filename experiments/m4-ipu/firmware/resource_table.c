/*
 * resource_table.c -- the contract between this firmware and remoteproc.
 *
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * The kernel finds this by section name (".resource_table"), copies it out
 * of the ELF before loading anything, and acts on it:
 *
 *   TYPE_CARVEOUT  dma_alloc_coherent() from the ipu-memory@95800000 pool
 *                  that 0011 reserved, then iommu_map(da -> that memory)
 *                  through the L2 IOMMU at 55082000. Because da is 0 and
 *                  not FW_RSC_ADDR_ANY, the kernel is required to honour
 *                  the address rather than choose one
 *                  (rproc_alloc_carveout()).
 *
 *   TYPE_TRACE     a debugfs file, read with strnlen() + simple_read_from
 *                  _buffer(), resolved lazily through rproc_da_to_va() so
 *                  it is allowed to point into the carveout above.
 *
 * Sizes: TI's own rsc_table_omap5_ipu.h asks for 6 MiB of text, 48 MiB of
 * data and 1 MiB of IPC data, which is where the 56 MiB carveout in 0011
 * comes from. This firmware is a few kilobytes and needs none of that, so
 * it asks for one megabyte and leaves the rest of the pool alone -- which
 * also demonstrates that the reservation is a pool and not a fixed block.
 *
 * reserved fields must be zero: rproc_handle_carveout() and
 * rproc_handle_trace() both reject a non-zero one.
 */
#include <stdint.h>

#define RSC_CARVEOUT	0u
#define RSC_TRACE	2u

#define TEXT_DA		0x00000000u
#define TEXT_LEN	0x00100000u	/* 1 MiB, and a 1 MiB IOMMU section */

extern volatile char m4_trace[];

struct fw_rsc_carveout {
	uint32_t da;
	uint32_t pa;
	uint32_t len;
	uint32_t flags;
	uint32_t reserved;
	uint8_t name[32];
} __attribute__((packed));

struct fw_rsc_trace {
	uint32_t da;
	uint32_t len;
	uint32_t reserved;
	uint8_t name[32];
} __attribute__((packed));

struct pyra_resource_table {
	uint32_t ver;
	uint32_t num;
	uint32_t reserved[2];
	uint32_t offset[2];

	uint32_t text_type;
	struct fw_rsc_carveout text;

	uint32_t trace_type;
	struct fw_rsc_trace trace;
} __attribute__((packed));

#define OFF(field) ((uint32_t)__builtin_offsetof(struct pyra_resource_table, field))

/*
 * Not const: rproc_start() memcpy()s the cached table back over the loaded
 * one, so this has to be in a writable segment.
 */
struct pyra_resource_table resource_table
	__attribute__((section(".resource_table"), used)) = {
	.ver = 1,
	.num = 2,
	.reserved = { 0, 0 },
	.offset = { OFF(text_type), OFF(trace_type) },

	.text_type = RSC_CARVEOUT,
	.text = {
		.da	= TEXT_DA,
		.pa	= 0,		/* ignored by the kernel; TI writes 0 */
		.len	= TEXT_LEN,
		.flags	= 0,
		.reserved = 0,
		.name	= "IPU_MEM_TEXT",
	},

	.trace_type = RSC_TRACE,
	.trace = {
		.da	= (uint32_t)(uintptr_t)m4_trace,
		.len	= 4096,
		.reserved = 0,
		.name	= "trace:ipu",
	},
};
