/*
 * container-check.c -- validate the AESS firmware container parser without a
 * kernel.
 *
 *     cc -O1 -Wall container-check.c -o container-check
 *     ./container-check /lib/firmware/omap_aess-adfw.bin
 *
 * This is the same walker that patch 0014 puts into
 * sound/soc/ti/aess/omap-aess-fw.c, lifted out so it can be run against a
 * real firmware file directly. On linux-firmware's omap_aess-adfw.bin it
 * reports a legacy container of 17 blocks, finds VENDOR_FW at 0xba88 whose
 * header plus four images sum exactly to its 54048-byte block, and
 * VENDOR_CONFIG at 0x18dc0. It also checks that a container with a bogus
 * size field is rejected rather than walked into.
 *
 * Exit status is 0 when both vendor blocks are found and the firmware block
 * is self-consistent.
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
typedef uint32_t __le32;
#define le32_to_cpu(x) (x)
#define SND_SOC_TPLG_MAGIC 0x41536F43
#define SND_SOC_TPLG_TYPE_VENDOR_FW 1000
#define SND_SOC_TPLG_TYPE_VENDOR_CONFIG 1001
struct omap_aess_fw_block {
	__le32 magic; __le32 abi; __le32 type;
	__le32 vendor_type; __le32 version; __le32 size;
} __attribute__((packed));
struct firmware { size_t size; const unsigned char *data; };
struct fw_header { uint32_t version, pmem_size, cmem_size, dmem_size, smem_size; };

static bool is_legacy(const struct firmware *fw, int *nblocks)
{
	size_t off = 0; int blocks = 0;
	while (off + sizeof(struct omap_aess_fw_block) <= fw->size) {
		const struct omap_aess_fw_block *b =
			(const struct omap_aess_fw_block *)(fw->data + off);
		size_t avail, size;
		if (le32_to_cpu(b->magic) != SND_SOC_TPLG_MAGIC) return false;
		off += sizeof(*b);
		avail = fw->size - off;
		size = le32_to_cpu(b->size);
		if (size > avail) return false;
		off += size; blocks++;
	}
	*nblocks = blocks;
	return off == fw->size;
}
int main(int argc, char **argv)
{
	FILE *f = fopen(argv[1], "rb"); unsigned char *buf; long n;
	fseek(f,0,SEEK_END); n=ftell(f); fseek(f,0,SEEK_SET);
	buf = malloc(n); if (fread(buf,1,n,f) != (size_t)n) return 2; fclose(f);
	struct firmware fw = { .size = n, .data = buf };
	int blocks = 0;
	printf("file %ld bytes\n", n);
	bool ok = is_legacy(&fw, &blocks);
	printf("is_legacy_container: %s (%d blocks)\n", ok ? "YES" : "no", blocks);
	if (!ok) return 1;
	size_t off = 0; int got_fw = 0, got_cfg = 0;
	while (off + sizeof(struct omap_aess_fw_block) <= fw.size) {
		const struct omap_aess_fw_block *b =
			(const struct omap_aess_fw_block *)(fw.data + off);
		const void *data = fw.data + off + sizeof(*b);
		size_t size = le32_to_cpu(b->size);
		if (le32_to_cpu(b->type) == SND_SOC_TPLG_TYPE_VENDOR_FW) {
			struct fw_header h; memcpy(&h, data, sizeof(h));
			size_t sum = sizeof(h)+h.pmem_size+h.cmem_size+h.dmem_size+h.smem_size;
			printf("  VENDOR_FW     @0x%06zx size %zu  ver 0x%x\n", off, size, h.version);
			printf("     P %u C %u D %u S %u   header+images = %zu  %s\n",
			       h.pmem_size,h.cmem_size,h.dmem_size,h.smem_size,sum,
			       sum==size ? "MATCHES block size" : "*** MISMATCH ***");
			got_fw = (sum==size);
		} else if (le32_to_cpu(b->type) == SND_SOC_TPLG_TYPE_VENDOR_CONFIG) {
			printf("  VENDOR_CONFIG @0x%06zx size %zu\n", off, size);
			got_cfg = 1;
		}
		off += sizeof(*b) + size;
	}
	printf("result: fw=%s config=%s\n", got_fw?"ok":"BAD", got_cfg?"ok":"BAD");
	/* negative control: a real topology file must be rejected */
	unsigned char fake[64] = {0}; memcpy(fake, "CoSA", 4);
	*(uint32_t*)(fake+0x14) = 0xdeadbeef;
	struct firmware bad = { .size = sizeof(fake), .data = fake };
	printf("negative control (bogus size): %s\n",
	       is_legacy(&bad,&blocks) ? "*** ACCEPTED, BAD ***" : "rejected, good");
	return !(got_fw && got_cfg);
}
