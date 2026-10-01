// gc320.h: the GC320 2D core (etnaviv) rotating or copying a frame, shared by gc320rot.c and chainprobe.c.
// X never writes DE_ROT_ANGLE or the rotation heights and assumes them zero: every stream here puts
// them back to zero at its end, in the same submit.
#include <stdint.h>
#include <xf86drm.h>
#include <etnaviv_drmif.h>
#include "cmdstream.xml.h"
#include "state.xml.h"
#include "state_2d.xml.h"

#ifndef SW
#define SW 640
#define SH 360
#endif

static struct etna_device* dev;
static struct etna_pipe* pipe2d;
static struct etna_cmd_stream* cs;

static void load_state(uint32_t addr, uint32_t count) {
    etna_cmd_stream_emit(cs, VIV_FE_LOAD_STATE_HEADER_OP_LOAD_STATE | VIV_FE_LOAD_STATE_HEADER_OFFSET(addr >> 2) |
                                 VIV_FE_LOAD_STATE_HEADER_COUNT(count));
}
static void set(uint32_t addr, uint32_t v) {
    etna_cmd_stream_reserve(cs, 2);
    load_state(addr, 1);
    etna_cmd_stream_emit(cs, v);
}
static void set_bo(uint32_t addr, struct etna_bo* bo, uint32_t flags) {
    etna_cmd_stream_reserve(cs, 2);
    load_state(addr, 1);
    etna_cmd_stream_reloc(cs, &(struct etna_reloc){ .bo = bo, .flags = flags, .offset = 0 });
}

// Variants: how the rotation is asked for. 0 is the plain copy (640x360 -> 640x360) that proves the stream.
enum { V_COPY, V_SRC90, V_SRC270, V_DST90, V_DST270, V_SRCCFG, V_COUNT };
static const char* const vname[] __attribute__((unused)) = { "copy", "src-rot90", "src-rot270", "dst-rot90", "dst-rot270", "src-config-only" };

// Source and destination strides in bytes; 0 means packed.
static void blit_stride(int v, struct etna_bo* src, uint32_t srcStride, struct etna_bo* dst, uint32_t dstStride) {
    const int portrait = v != V_COPY;
    const uint32_t dw = portrait ? SH : SW, dh = portrait ? SW : SH;
    const uint32_t fmt = DE_FORMAT_A8R8G8B8;

    uint32_t srcRot = VIVS_DE_SRC_ROTATION_CONFIG_ROTATION_DISABLE, dstRot = VIVS_DE_DEST_ROTATION_CONFIG_ROTATION_DISABLE;
    uint32_t angle = VIVS_DE_ROT_ANGLE_SRC(DE_ROT_MODE_ROT0) | VIVS_DE_ROT_ANGLE_DST(DE_ROT_MODE_ROT0) |
                     VIVS_DE_ROT_ANGLE_SRC_MASK | VIVS_DE_ROT_ANGLE_DST_MASK;
    uint32_t srcW = SW, srcH = SH, rx = SW, ry = SH; // source size and the rectangle drawn
    switch (v) {
    case V_SRC90:
    case V_SRC270:
        srcRot = VIVS_DE_SRC_ROTATION_CONFIG_ROTATION_ENABLE | VIVS_DE_SRC_ROTATION_CONFIG_WIDTH(SW);
        angle = VIVS_DE_ROT_ANGLE_SRC(v == V_SRC90 ? DE_ROT_MODE_ROT90 : DE_ROT_MODE_ROT270) |
                VIVS_DE_ROT_ANGLE_DST(DE_ROT_MODE_ROT0) | VIVS_DE_ROT_ANGLE_SRC_MASK | VIVS_DE_ROT_ANGLE_DST_MASK;
        srcW = SH; srcH = SW; rx = SH; ry = SW; // the rectangle in the destination's (rotated) space
        break;
    case V_DST90:
    case V_DST270:
        dstRot = VIVS_DE_DEST_ROTATION_CONFIG_ROTATION_ENABLE | VIVS_DE_DEST_ROTATION_CONFIG_WIDTH(dw);
        angle = VIVS_DE_ROT_ANGLE_SRC(DE_ROT_MODE_ROT0) |
                VIVS_DE_ROT_ANGLE_DST(v == V_DST90 ? DE_ROT_MODE_ROT90 : DE_ROT_MODE_ROT270) |
                VIVS_DE_ROT_ANGLE_SRC_MASK | VIVS_DE_ROT_ANGLE_DST_MASK;
        break; // the rectangle in the source's space
    case V_SRCCFG:
        srcRot = VIVS_DE_SRC_ROTATION_CONFIG_ROTATION_ENABLE | VIVS_DE_SRC_ROTATION_CONFIG_WIDTH(SW);
        srcW = SH; srcH = SW; rx = SH; ry = SW;
        break;
    }

    // One submit for the whole blit and its reset: a flush in between would let X's 2D work run with
    // the rotation still set.
    etna_cmd_stream_reserve(cs, 80);
    set_bo(VIVS_DE_SRC_ADDRESS, src, ETNA_RELOC_READ);
    set(VIVS_DE_SRC_STRIDE, srcStride ? srcStride : SW * 4);
    set(VIVS_DE_SRC_ROTATION_CONFIG, srcRot);
    set(VIVS_DE_SRC_CONFIG, VIVS_DE_SRC_CONFIG_SOURCE_FORMAT(fmt) | VIVS_DE_SRC_CONFIG_SWIZZLE(DE_SWIZZLE_ARGB) |
                                VIVS_DE_SRC_CONFIG_LOCATION_MEMORY | VIVS_DE_SRC_CONFIG_PE10_SOURCE_FORMAT(fmt));
    set(VIVS_DE_SRC_ORIGIN, VIVS_DE_SRC_ORIGIN_X(0) | VIVS_DE_SRC_ORIGIN_Y(0));
    set(VIVS_DE_SRC_SIZE, VIVS_DE_SRC_SIZE_X(srcW) | VIVS_DE_SRC_SIZE_Y(srcH));
    set(VIVS_DE_SRC_ROTATION_HEIGHT, VIVS_DE_SRC_ROTATION_HEIGHT_HEIGHT(SH));
    set_bo(VIVS_DE_DEST_ADDRESS, dst, ETNA_RELOC_WRITE);
    set(VIVS_DE_DEST_STRIDE, dstStride ? dstStride : dw * 4);
    set(VIVS_DE_DEST_ROTATION_CONFIG, dstRot);
    set(VIVS_DE_DEST_CONFIG, VIVS_DE_DEST_CONFIG_FORMAT(fmt) | VIVS_DE_DEST_CONFIG_SWIZZLE(DE_SWIZZLE_ARGB) |
                                 VIVS_DE_DEST_CONFIG_COMMAND_BIT_BLT | VIVS_DE_DEST_CONFIG_TILED_DISABLE |
                                 VIVS_DE_DEST_CONFIG_MINOR_TILED_DISABLE);
    set(VIVS_DE_DEST_ROTATION_HEIGHT, VIVS_DE_DEST_ROTATION_HEIGHT_HEIGHT(dh));
    set(VIVS_DE_ROT_ANGLE, angle);
    set(VIVS_DE_ROP, VIVS_DE_ROP_ROP_FG(0xcc) | VIVS_DE_ROP_ROP_BG(0xcc) | VIVS_DE_ROP_TYPE_ROP4);
    set(VIVS_DE_CLIP_TOP_LEFT, VIVS_DE_CLIP_TOP_LEFT_X(0) | VIVS_DE_CLIP_TOP_LEFT_Y(0));
    set(VIVS_DE_CLIP_BOTTOM_RIGHT, VIVS_DE_CLIP_BOTTOM_RIGHT_X(v == V_DST90 || v == V_DST270 ? SW : dw) |
                                       VIVS_DE_CLIP_BOTTOM_RIGHT_Y(v == V_DST90 || v == V_DST270 ? SH : dh));
    set(VIVS_DE_CONFIG, 0);
    set(VIVS_DE_ALPHA_CONTROL, VIVS_DE_ALPHA_CONTROL_ENABLE_OFF);

    etna_cmd_stream_reserve(cs, 4);
    etna_cmd_stream_emit(cs, VIV_FE_DRAW_2D_HEADER_OP_DRAW_2D | VIV_FE_DRAW_2D_HEADER_COUNT(1));
    etna_cmd_stream_emit(cs, 0);
    etna_cmd_stream_emit(cs, VIV_FE_DRAW_2D_TOP_LEFT_X(0) | VIV_FE_DRAW_2D_TOP_LEFT_Y(0));
    etna_cmd_stream_emit(cs, VIV_FE_DRAW_2D_BOTTOM_RIGHT_X(rx) | VIV_FE_DRAW_2D_BOTTOM_RIGHT_Y(ry));
    set(VIVS_GL_FLUSH_CACHE, VIVS_GL_FLUSH_CACHE_PE2D);

    // Put back what X assumes: no rotation anywhere.
    set(VIVS_DE_ROT_ANGLE, VIVS_DE_ROT_ANGLE_SRC(DE_ROT_MODE_ROT0) | VIVS_DE_ROT_ANGLE_DST(DE_ROT_MODE_ROT0) |
                               VIVS_DE_ROT_ANGLE_SRC_MASK | VIVS_DE_ROT_ANGLE_DST_MASK);
    set(VIVS_DE_SRC_ROTATION_HEIGHT, 0);
    set(VIVS_DE_DEST_ROTATION_HEIGHT, 0);
    set(VIVS_DE_SRC_ROTATION_CONFIG, 0);
    set(VIVS_DE_DEST_ROTATION_CONFIG, 0);
}

static inline void blit(int v, struct etna_bo* src, struct etna_bo* dst) { blit_stride(v, src, 0, dst, 0); }

// The 2D pipe on the etnaviv render node; returns 0 on success.
static int gc320_open(void) {
    int fd = drmOpenWithType("etnaviv", NULL, DRM_NODE_RENDER);
    if (fd < 0) return -1;
    dev = etna_device_new(fd);
    for (unsigned core = 0; core < 4 && !pipe2d; core++) {
        struct etna_gpu* gpu = etna_gpu_new(dev, core);
        if (!gpu) break;
        uint64_t feat = 0;
        etna_gpu_get_param(gpu, ETNA_GPU_FEATURES_0, &feat);
        if (feat & (1 << 9)) pipe2d = etna_pipe_new(gpu, ETNA_PIPE_2D); // chipFeatures_PIPE_2D
    }
    if (!pipe2d) return -1;
    cs = etna_cmd_stream_new(pipe2d, 0x1000, NULL, NULL);
    return 0;
}
