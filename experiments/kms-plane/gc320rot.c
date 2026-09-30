// gc320rot: the GC320 2D core (etnaviv) rotating a 640x360 frame into a 360x640 one, to price item F's
// blitter rotation (Shipwright report 08 §8.54). Runs on the device as root, alongside X (X's own 2D
// acceleration uses the same core).
//
//   gc320rot check                 one blit per variant, read back and classify the mapping
//   gc320rot run VARIANT ARMFILE PREFIX BIT HZ
//                                  blit HZ times a second while the harness's arm (ARMFILE holds
//                                  <PREFIX><value>-<n>, see SOH_BENCH_ARM_FILE) has BIT set; idle otherwise
//
// X never writes DE_ROT_ANGLE or the rotation heights and assumes them zero: every stream here puts
// them back to zero at its end.
//
// Build (on the device): gcc -O2 -o gc320rot gc320rot.c -Iviv2d -I/usr/include/libdrm -ldrm -ldrm_etnaviv
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <xf86drm.h>
#include <etnaviv_drmif.h>
#include "cmdstream.xml.h"
#include "state.xml.h"
#include "state_2d.xml.h"

#define SW 640
#define SH 360

static struct etna_device* dev;
static struct etna_pipe* pipe2d;
static struct etna_cmd_stream* cs;

static void load(uint32_t addr, uint32_t count) {
    etna_cmd_stream_emit(cs, VIV_FE_LOAD_STATE_HEADER_OP_LOAD_STATE | VIV_FE_LOAD_STATE_HEADER_OFFSET(addr >> 2) |
                                 VIV_FE_LOAD_STATE_HEADER_COUNT(count));
}
static void set(uint32_t addr, uint32_t v) {
    etna_cmd_stream_reserve(cs, 2);
    load(addr, 1);
    etna_cmd_stream_emit(cs, v);
}
static void set_bo(uint32_t addr, struct etna_bo* bo, uint32_t flags) {
    etna_cmd_stream_reserve(cs, 2);
    load(addr, 1);
    etna_cmd_stream_reloc(cs, &(struct etna_reloc){ .bo = bo, .flags = flags, .offset = 0 });
}

// Variants: how the rotation is asked for. 0 is the plain copy (640x360 -> 640x360) that proves the stream.
enum { V_COPY, V_SRC90, V_SRC270, V_DST90, V_DST270, V_SRCCFG, V_COUNT };
static const char* vname[] = { "copy", "src-rot90", "src-rot270", "dst-rot90", "dst-rot270", "src-config-only" };

static void blit(int v, struct etna_bo* src, struct etna_bo* dst) {
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
    set(VIVS_DE_SRC_STRIDE, SW * 4);
    set(VIVS_DE_SRC_ROTATION_CONFIG, srcRot);
    set(VIVS_DE_SRC_CONFIG, VIVS_DE_SRC_CONFIG_SOURCE_FORMAT(fmt) | VIVS_DE_SRC_CONFIG_SWIZZLE(DE_SWIZZLE_ARGB) |
                                VIVS_DE_SRC_CONFIG_LOCATION_MEMORY | VIVS_DE_SRC_CONFIG_PE10_SOURCE_FORMAT(fmt));
    set(VIVS_DE_SRC_ORIGIN, VIVS_DE_SRC_ORIGIN_X(0) | VIVS_DE_SRC_ORIGIN_Y(0));
    set(VIVS_DE_SRC_SIZE, VIVS_DE_SRC_SIZE_X(srcW) | VIVS_DE_SRC_SIZE_Y(srcH));
    set(VIVS_DE_SRC_ROTATION_HEIGHT, VIVS_DE_SRC_ROTATION_HEIGHT_HEIGHT(SH));
    set_bo(VIVS_DE_DEST_ADDRESS, dst, ETNA_RELOC_WRITE);
    set(VIVS_DE_DEST_STRIDE, dw * 4);
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

static uint32_t code(int x, int y) { return 0xff000000u | ((uint32_t)y << 12) | (uint32_t)x; }

// What the destination holds, as a map from destination (u, v) to source (x, y).
static const char* classify(const uint32_t* d, int dw, int dh, int* bestMiss) {
    struct { const char* name; int w, h; } maps[] = {
        { "identity", SW, SH }, { "rot90cw", SH, SW }, { "rot90ccw", SH, SW }, { "transpose", SH, SW },
        { "antitranspose", SH, SW },
    };
    const char* best = "none";
    *bestMiss = dw * dh + 1;
    for (int m = 0; m < 5; m++) {
        if (maps[m].w != dw || maps[m].h != dh) continue;
        int miss = 0;
        for (int v = 0; v < dh; v++)
            for (int u = 0; u < dw; u++) {
                int x, y;
                switch (m) {
                case 0: x = u; y = v; break;
                case 1: x = v; y = SH - 1 - u; break;          // clockwise: source's left column on top
                case 2: x = SW - 1 - v; y = u; break;          // counter-clockwise
                case 3: x = v; y = u; break;
                default: x = SW - 1 - v; y = SH - 1 - u; break;
                }
                if (d[v * dw + u] != code(x, y)) miss++;
            }
        if (miss < *bestMiss) { *bestMiss = miss; best = maps[m].name; }
    }
    return best;
}

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: gc320rot check | run VARIANT ARMFILE PREFIX BIT HZ\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    int fd = drmOpenWithType("etnaviv", NULL, DRM_NODE_RENDER);
    if (fd < 0) { perror("etnaviv render node"); return 1; }
    dev = etna_device_new(fd);
    struct etna_gpu* gpu = NULL;
    for (unsigned core = 0; core < 4 && !pipe2d; core++) {
        gpu = etna_gpu_new(dev, core);
        if (!gpu) break;
        uint64_t feat = 0;
        etna_gpu_get_param(gpu, ETNA_GPU_FEATURES_0, &feat);
        if (feat & (1 << 9)) pipe2d = etna_pipe_new(gpu, ETNA_PIPE_2D); // chipFeatures_PIPE_2D
    }
    if (!pipe2d) { printf("no 2D pipe\n"); return 1; }
    cs = etna_cmd_stream_new(pipe2d, 0x1000, NULL, NULL);
    struct etna_bo* src = etna_bo_new(dev, SW * SH * 4, DRM_ETNA_GEM_CACHE_WC);
    struct etna_bo* dst = etna_bo_new(dev, SW * SH * 4, DRM_ETNA_GEM_CACHE_WC);
    uint32_t* s = etna_bo_map(src);
    etna_bo_cpu_prep(src, DRM_ETNA_PREP_WRITE);
    for (int y = 0; y < SH; y++)
        for (int x = 0; x < SW; x++) s[y * SW + x] = code(x, y);
    etna_bo_cpu_fini(src);
    uint32_t* d = etna_bo_map(dst);

    if (!strcmp(argv[1], "check")) {
        for (int v = 0; v < V_COUNT; v++) {
            etna_bo_cpu_prep(dst, DRM_ETNA_PREP_WRITE);
            memset(d, 0, SW * SH * 4);
            etna_bo_cpu_fini(dst);
            double t0 = now();
            blit(v, src, dst);
            etna_cmd_stream_finish(cs);
            double ms = (now() - t0) * 1e3;
            etna_bo_cpu_prep(dst, DRM_ETNA_PREP_READ);
            int miss;
            const int portrait = v != V_COPY;
            const char* m = classify(d, portrait ? SH : SW, portrait ? SW : SH, &miss);
            printf("variant %-16s -> %-13s mismatches %6d of %d  (%.2f ms)  d[0]=%08x d[1]=%08x\n", vname[v], m, miss,
                   SW * SH, ms, d[0], d[1]);
            etna_bo_cpu_fini(dst);
        }
        return 0;
    }

    if (strcmp(argv[1], "run") || argc < 7) { fprintf(stderr, "bad args\n"); return 2; }
    int v = atoi(argv[2]);
    const char* armFile = argv[3];
    const char* prefix = argv[4];
    long bit = strtol(argv[5], NULL, 0);
    double period = 1.0 / atof(argv[6]);
    double next = now(), lastCheck = 0, lastReport = now();
    int on = 0, blits = 0;
    for (;;) {
        double t = now();
        if (t - lastCheck >= 0.25) {
            lastCheck = t;
            char buf[128] = { 0 };
            FILE* f = fopen(armFile, "r");
            if (f) { if (!fgets(buf, sizeof buf, f)) buf[0] = 0; fclose(f); }
            size_t n = strlen(prefix);
            int was = on;
            on = !strncmp(buf, prefix, n) && (strtol(buf + n, NULL, 10) & bit) != 0;
            if (on != was) printf("%.0f %s (%s)\n", t, on ? "blitting" : "idle", buf);
            if (!strncmp(buf, "end", 3)) break;
        }
        if (on) {
            blit(v, src, dst);
            etna_cmd_stream_flush(cs);
            blits++;
        }
        if (t - lastReport >= 10) {
            printf("%.0f blits/s %.1f\n", t, blits / (t - lastReport));
            blits = 0;
            lastReport = t;
        }
        next += period;
        double w = next - now();
        if (w > 0) usleep((useconds_t)(w * 1e6)); else next = now();
    }
    etna_cmd_stream_finish(cs);
    return 0;
}
