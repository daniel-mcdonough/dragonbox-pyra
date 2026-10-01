// gc320rot: the GC320 2D core (etnaviv) rotating a 640x360 frame into a 360x640 one, to price item F's
// blitter rotation (Shipwright report 08 §8.54). Runs on the device as root, alongside X (X's own 2D
// acceleration uses the same core).
//
//   gc320rot check                 one blit per variant, read back and classify the mapping
//   gc320rot run VARIANT ARMFILE PREFIX BIT HZ
//                                  blit HZ times a second while the harness's arm (ARMFILE holds
//                                  <PREFIX><value>-<n>, see SOH_BENCH_ARM_FILE) has BIT set; idle otherwise
//
// The blit itself is in gc320.h.
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
#include "gc320.h"

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
    if (gc320_open()) { printf("no etnaviv 2D pipe\n"); return 1; }
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
