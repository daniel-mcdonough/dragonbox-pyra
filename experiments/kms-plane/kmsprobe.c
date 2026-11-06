// kmsprobe: can the game reach a scaled display plane on the Pyra outside X? (the SoH port's work queue
// item F, report 08 §8.52-8.53.) Runs on the device, as root.
//
//   kmsprobe egl                  no master needed: GBM + the DDK's EGL, render 640x360, lock the front
//                                 buffer, AddFB2 it; prints the EGL/GL extensions that matter
//   kmsprobe plane SRC ROT SECS   needs DRM master (X switched away: chvt 2 first): show a 640x360
//                                 buffer on a free plane scaled to the whole panel, for SECS seconds.
//                                 SRC: dumb (CPU pattern), tiled (omap TILER bo, CPU pattern), egl (GBM
//                                 surface rendered by the SGX). ROT: the plane's rotation property value
//                                 (1 = 0°, 2 = 90°, 4 = 180°, 8 = 270°; X uses 8).
//   kmsprobe chain check N SYNC   no master needed: N frames of the item F chain without display. The SGX
//                                 renders a 640x360 GBM frame (a per-frame colour, green top-left corner),
//                                 its bo goes to the GC320 as a dma-buf (omapdrm PRIME -> etnaviv), which
//                                 rotates it clockwise into a 360x640 omapdrm scanout bo; the probe reads
//                                 that back and counts frames whose colour is not this frame's (the blit ran
//                                 before the SGX finished) and where the corner landed. SYNC: none, fence
//                                 (EGL_KHR_fence_sync, eglClientWaitSync before the blit), finish (glFinish).
//                                 KMSPROBE_LOAD=N draws N full-frame quads a frame to give the SGX real work.
//   kmsprobe chain plane SECS SYNC
//                                 needs master: the same chain shown on a free plane, unrotated, 360x640
//                                 scaled 2x to the 720x1280 panel, two scanout bos alternating.
//
// Needs TI's libgbm fork (git.ti.com glsdk/libgbm c5ddc6a; the DDK's GBM window system is its gbm_pvr backend;
// Mesa's libgbm, which the Pyra package symlinks as libgbm.so.2, cannot drive it). Build it privately in tigbm/:
//   gcc -O2 -fPIC -shared -include sys/sysmacros.h -o tigbm/libgbm.so.2 src/{gbm,backend,common}.c -Isrc \
//     -DMODULEDIR='"/usr/lib/gbm"' -Wl,-soname,libgbm.so.2 -ludev -ldl
// Build (on the device): gcc -O2 -o kmsprobe kmsprobe.c -Itigbm/src -I/usr/include/libdrm -I/usr/include/omap
//   -I/opt/omap5-sgx-ddk-um-linux/include -L/opt/omap5-sgx-ddk-um-linux/lib -Ltigbm
//   -Wl,-rpath,/opt/omap5-sgx-ddk-um-linux/lib -ldrm -ldrm_omap -l:libgbm.so.2 -lEGL -lGLESv2
//   -Iviv2d -ldrm_etnaviv (for chain)
// Run: sudo env LD_LIBRARY_PATH=$PWD/tigbm GBM_BACKEND=/opt/omap5-sgx-ddk-um-linux/lib/libpvrGBMWSEGL.so.1 ./kmsprobe ...
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>
#include <omap_drmif.h>
#include <gbm.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

#define W 640
#define H 360
#define SW W
#define SH H
#include "gc320.h"

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static void pattern(uint32_t* p, int pitchPx) {
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            uint32_t c = ((x / 40 + y / 40) & 1) ? 0x00ff8000 : 0x000040ff; // orange / blue checks
            if (x < 8 || y < 8 || x >= W - 8 || y >= H - 8) c = 0x00ffffff;  // white border
            if (x < 80 && y < 45) c = 0x0000ff00;                             // green: top-left corner
            p[y * pitchPx + x] = c;
        }
}

static int has(const char* list, const char* ext) {
    return list && strstr(list, ext) != NULL;
}

// GBM + EGL: returns the locked bo, or NULL.
static struct gbm_device* gdev;
static struct gbm_surface* gsurf;
static EGLDisplay dpy;
static EGLSurface esurf;
// LOAD (env KMSPROBE_LOAD, default 0): full-frame quads drawn in the frame's colour after the clear, so a
// frame takes real 3D time (the game's is ~5 ms) and a blit that runs too early has something to miss.
static int load = -1;
static GLuint loadProg;
static GLint loadCol;
static void load_init(void) {
    const char* e = getenv("KMSPROBE_LOAD");
    load = e ? atoi(e) : 0;
    if (!load) return;
    const char* vs = "attribute vec2 p; void main() { gl_Position = vec4(p, 0.0, 1.0); }";
    const char* fs = "precision mediump float; uniform vec4 c; void main() { gl_FragColor = c; }";
    GLuint v = glCreateShader(GL_VERTEX_SHADER), f = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(v, 1, &vs, NULL); glCompileShader(v);
    glShaderSource(f, 1, &fs, NULL); glCompileShader(f);
    loadProg = glCreateProgram();
    glAttachShader(loadProg, v); glAttachShader(loadProg, f);
    glBindAttribLocation(loadProg, 0, "p");
    glLinkProgram(loadProg);
    loadCol = glGetUniformLocation(loadProg, "c");
    printf("load: %d full-frame quads a frame\n", load);
}
static double tIssue, tSwap, tLock; // egl_frame's split, summed over frames
static struct gbm_bo* egl_frame(int fd, int frame) {
    if (!gdev) {
        gdev = gbm_create_device(fd);
        printf("gbm_create_device: %p\n", (void*)gdev);
        if (!gdev) return NULL;
        // The DDK's EGL (1.14) predates platform displays: a GBM device passed as the native display
        // picks its GBM window system.
        dpy = eglGetDisplay((EGLNativeDisplayType)gdev);
        EGLint maj = 0, min = 0;
        if (!eglInitialize(dpy, &maj, &min)) {
            printf("eglInitialize failed: 0x%x\n", eglGetError());
            return NULL;
        }
        printf("EGL %d.%d vendor '%s' version '%s'\n", maj, min, eglQueryString(dpy, EGL_VENDOR),
               eglQueryString(dpy, EGL_VERSION));
        const char* ext = eglQueryString(dpy, EGL_EXTENSIONS);
        printf("EGL extensions: %s\n", ext);
        printf("  dma_buf_import %d  image_base %d  image_pixmap %d  native_pixmap_gbm %d\n",
               has(ext, "EGL_EXT_image_dma_buf_import"), has(ext, "EGL_KHR_image_base"),
               has(ext, "EGL_KHR_image_pixmap"), has(ext, "EGL_MESA_image_dma_buf_export"));
        eglBindAPI(EGL_OPENGL_ES_API);
        EGLint cattr[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                           EGL_BLUE_SIZE, 8, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE };
        EGLConfig cfgs[64];
        EGLint n = 0;
        eglChooseConfig(dpy, cattr, cfgs, 64, &n);
        printf("configs: %d\n", n);
        gsurf = gbm_surface_create(gdev, W, H, GBM_FORMAT_XRGB8888, GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
        printf("gbm_surface_create XRGB8888: %p\n", (void*)gsurf);
        if (!gsurf) return NULL;
        EGLConfig cfg = NULL;
        for (int i = 0; i < n; i++) {
            EGLint vid = 0;
            eglGetConfigAttrib(dpy, cfgs[i], EGL_NATIVE_VISUAL_ID, &vid);
            if (vid == GBM_FORMAT_XRGB8888 || vid == GBM_FORMAT_ARGB8888) { cfg = cfgs[i]; break; }
        }
        if (!cfg && n) { cfg = cfgs[0]; printf("no config with an XRGB visual; taking the first\n"); }
        esurf = eglCreateWindowSurface(dpy, cfg, (EGLNativeWindowType)gsurf, NULL);
        if (esurf == EGL_NO_SURFACE) {
            printf("eglCreateWindowSurface failed: 0x%x\n", eglGetError());
            return NULL;
        }
        EGLint ctxattr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
        EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxattr);
        if (!eglMakeCurrent(dpy, esurf, esurf, ctx)) {
            printf("eglMakeCurrent failed: 0x%x\n", eglGetError());
            return NULL;
        }
        printf("GL renderer '%s'\nGL extensions: %s\n", glGetString(GL_RENDERER), glGetString(GL_EXTENSIONS));
    }
    // A frame: a clear that cycles colour, and a scissored green corner so orientation shows.
    double e0 = now();
    glDisable(GL_SCISSOR_TEST);
    float k = (frame % 60) / 60.0f;
    glClearColor(k, 0.25f, 1.0f - k, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    if (load < 0) load_init();
    if (load) {
        static const float quad[] = { -1, -1, 1, -1, -1, 1, 1, 1 };
        glUseProgram(loadProg);
        glUniform4f(loadCol, k, 0.25f, 1.0f - k, 1);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, quad);
        glEnableVertexAttribArray(0);
        // Blending (ONE, ZERO: the same result) so the SGX's hidden-surface removal cannot drop all but the last.
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ZERO);
        for (int i = 0; i < load; i++) glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        glDisable(GL_BLEND);
    }
    glEnable(GL_SCISSOR_TEST);
    glScissor(0, H - 45, 80, 45); // GL's origin is bottom-left: this is the top-left corner
    glClearColor(0, 1, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    double e1 = now();
    if (!eglSwapBuffers(dpy, esurf)) {
        printf("eglSwapBuffers failed: 0x%x\n", eglGetError());
        return NULL;
    }
    double e2 = now();
    struct gbm_bo* b = gbm_surface_lock_front_buffer(gsurf);
    double e3 = now();
    tIssue += e1 - e0; tSwap += e2 - e1; tLock += e3 - e2;
    return b;
}

static uint32_t add_fb(int fd, uint32_t handle, uint32_t pitch, uint64_t mod) {
    uint32_t handles[4] = { handle }, pitches[4] = { pitch }, offsets[4] = { 0 }, id = 0;
    uint64_t mods[4] = { mod };
    int r = mod ? drmModeAddFB2WithModifiers(fd, W, H, DRM_FORMAT_XRGB8888, handles, pitches, offsets, mods, &id,
                                             DRM_MODE_FB_MODIFIERS)
                : drmModeAddFB2(fd, W, H, DRM_FORMAT_XRGB8888, handles, pitches, offsets, &id, 0);
    if (r) printf("AddFB2 (handle %u pitch %u) failed: %s\n", handle, pitch, strerror(errno));
    return r ? 0 : id;
}

static uint32_t prop_id(int fd, uint32_t obj, uint32_t type, const char* name) {
    drmModeObjectProperties* props = drmModeObjectGetProperties(fd, obj, type);
    uint32_t id = 0;
    for (uint32_t i = 0; props && i < props->count_props; i++) {
        drmModePropertyRes* p = drmModeGetProperty(fd, props->props[i]);
        if (p && !strcmp(p->name, name)) id = p->prop_id;
        drmModeFreeProperty(p);
    }
    drmModeFreeObjectProperties(props);
    return id;
}

// ---- chain: SGX -> dma-buf -> GC320 rotate -> omapdrm scanout bo ----

static PFNEGLCREATESYNCKHRPROC pCreateSync;
static PFNEGLCLIENTWAITSYNCKHRPROC pClientWait;
static PFNEGLDESTROYSYNCKHRPROC pDestroySync;

// The red channel the SGX writes for frame f (green 0x40, blue 1-k), as XRGB8888 read back.
static int red_of(int f) { return (int)((f % 60) / 60.0f * 255.0f + 0.5f); }

struct imp { struct etna_bo* bo; int fd; };
static void imp_free(struct gbm_bo* b, void* d) {
    (void)b;
    struct imp* i = d;
    etna_bo_del(i->bo);
    close(i->fd);
    free(i);
}

// The etnaviv view of a GBM bo, imported once and kept on the bo.
static struct etna_bo* import_gbm(int fd, struct gbm_bo* b) {
    struct imp* i = gbm_bo_get_user_data(b);
    if (i) return i->bo;
    int pfd = -1;
    if (drmPrimeHandleToFD(fd, gbm_bo_get_handle(b).u32, DRM_CLOEXEC, &pfd)) {
        printf("PRIME export of the GBM bo failed: %s\n", strerror(errno));
        return NULL;
    }
    struct etna_bo* eb = etna_bo_from_dmabuf(dev, pfd);
    printf("GBM bo %p (handle %u stride %u): dma-buf %d -> etnaviv %p\n", (void*)b, gbm_bo_get_handle(b).u32,
           gbm_bo_get_stride(b), pfd, (void*)eb);
    if (!eb) { close(pfd); return NULL; }
    i = calloc(1, sizeof *i);
    i->bo = eb; i->fd = pfd;
    gbm_bo_set_user_data(b, i, imp_free);
    return eb;
}

struct dst { struct omap_bo* ob; struct etna_bo* eb; uint32_t* map; uint32_t fb; };
static int make_dst(int fd, struct omap_device* od, struct dst* d) {
    d->ob = omap_bo_new(od, SH * SW * 4, OMAP_BO_SCANOUT | OMAP_BO_WC);
    if (!d->ob) { printf("omap_bo_new scanout failed\n"); return -1; }
    int pfd = omap_bo_dmabuf(d->ob);
    d->eb = pfd >= 0 ? etna_bo_from_dmabuf(dev, pfd) : NULL;
    printf("scanout bo handle %u: dma-buf %d -> etnaviv %p\n", omap_bo_handle(d->ob), pfd, (void*)d->eb);
    if (pfd >= 0) close(pfd);
    if (!d->eb) return -1;
    d->map = omap_bo_map(d->ob);
    uint32_t handles[4] = { omap_bo_handle(d->ob) }, pitches[4] = { SH * 4 }, offsets[4] = { 0 };
    if (drmModeAddFB2(fd, SH, SW, DRM_FORMAT_XRGB8888, handles, pitches, offsets, &d->fb, 0)) {
        printf("AddFB2 360x640 failed: %s\n", strerror(errno));
        d->fb = 0;
    }
    return 0;
}

enum { SYNC_NONE, SYNC_FENCE, SYNC_FINISH };

// Render frame f, wait as SYNC says, blit into d. Returns the locked GBM bo (release it after), or NULL.
static double tRender, tWait, tBlit;
static struct gbm_bo* chain_frame(int fd, int f, int sync, struct dst* d) {
    double t0 = now();
    struct gbm_bo* b = egl_frame(fd, f); // eglSwapBuffers, then lock
    double t1 = now();
    if (!b) return NULL;
    // The fence goes in after the swap: it signals when everything before it, the frame included, is done.
    if (sync == SYNC_FENCE) {
        EGLSyncKHR fs = pCreateSync(dpy, EGL_SYNC_FENCE_KHR, NULL);
        pClientWait(dpy, fs, EGL_SYNC_FLUSH_COMMANDS_BIT_KHR, EGL_FOREVER_KHR);
        pDestroySync(dpy, fs);
    } else if (sync == SYNC_FINISH) {
        glFinish();
    }
    double t2 = now();
    struct etna_bo* src = import_gbm(fd, b);
    if (!src) { gbm_surface_release_buffer(gsurf, b); return NULL; }
    blit_stride(V_DST90, src, gbm_bo_get_stride(b), d->eb, SH * 4);
    etna_cmd_stream_finish(cs);
    double t3 = now();
    tRender += t1 - t0; tWait += t2 - t1; tBlit += t3 - t2;
    return b;
}

static int chain(int fd, int argc, char** argv, int master) {
    if (argc < 5) { fprintf(stderr, "usage: kmsprobe chain check N SYNC | chain plane SECS SYNC\n"); return 2; }
    const int isPlane = !strcmp(argv[2], "plane");
    const int n = atoi(argv[3]);
    const int sync = !strcmp(argv[4], "fence") ? SYNC_FENCE : !strcmp(argv[4], "finish") ? SYNC_FINISH : SYNC_NONE;
    if (isPlane && !master) { printf("RESULT chain plane: FAIL (not master; switch X away first)\n"); return 1; }
    if (gc320_open()) { printf("RESULT chain: FAIL (no etnaviv 2D pipe)\n"); return 1; }
    struct omap_device* od = omap_device_new(fd);
    struct dst d[2] = { 0 };
    if (make_dst(fd, od, &d[0]) || make_dst(fd, od, &d[1])) { printf("RESULT chain: FAIL (scanout bo)\n"); return 1; }

    struct gbm_bo* first = egl_frame(fd, 0); // sets EGL up
    if (!first) { printf("RESULT chain: FAIL (egl)\n"); return 1; }
    gbm_surface_release_buffer(gsurf, first);
    const char* ext = eglQueryString(dpy, EGL_EXTENSIONS);
    pCreateSync = (PFNEGLCREATESYNCKHRPROC)eglGetProcAddress("eglCreateSyncKHR");
    pClientWait = (PFNEGLCLIENTWAITSYNCKHRPROC)eglGetProcAddress("eglClientWaitSyncKHR");
    pDestroySync = (PFNEGLDESTROYSYNCKHRPROC)eglGetProcAddress("eglDestroySyncKHR");
    printf("EGL_KHR_fence_sync %d (%p)\n", has(ext, "EGL_KHR_fence_sync"), (void*)pCreateSync);
    if (sync == SYNC_FENCE && (!has(ext, "EGL_KHR_fence_sync") || !pCreateSync)) {
        printf("RESULT chain: FAIL (no EGL_KHR_fence_sync)\n");
        return 1;
    }

    if (!isPlane) {
        int stale = 0, cornerOk = 0, frames = 0;
        for (int f = 1; f <= n; f++) {
            struct dst* t = &d[f & 1];
            omap_bo_cpu_prep(t->ob, OMAP_GEM_WRITE);
            memset(t->map, 0, SH * SW * 4); // a blit that never lands reads as black
            omap_bo_cpu_fini(t->ob, OMAP_GEM_WRITE);
            struct gbm_bo* b = chain_frame(fd, f, sync, t);
            if (!b) break;
            frames++;
            omap_bo_cpu_prep(t->ob, OMAP_GEM_READ);
            // Clockwise: the source's top-left lands top-right of the portrait frame. Sample the body at the
            // middle and the corner 10 px in from the top-right; green there means the orientation is right
            // and the SGX frame was read top-down.
            uint32_t body = t->map[(SW / 2) * SH + SH / 2], corner = t->map[10 * SH + (SH - 11)];
            uint32_t otherCorners[3] = { t->map[10 * SH + 10], t->map[(SW - 11) * SH + 10], t->map[(SW - 11) * SH + SH - 11] };
            omap_bo_cpu_fini(t->ob, OMAP_GEM_READ);
            int r = (body >> 16) & 0xff, want = red_of(f);
            int bad = abs(r - want) > 2;
            stale += bad;
            int ok = (corner & 0xffffff) == 0x00ff00;
            cornerOk += ok;
            if (f <= 3 || bad || !ok)
                if (f <= 3 || stale <= 10)
                    printf("frame %3d body %08x (red %3d, want %3d)%s corner(tr) %08x others %08x %08x %08x\n", f,
                           body, r, want, bad ? " STALE" : "", corner, otherCorners[0], otherCorners[1], otherCorners[2]);
            gbm_surface_release_buffer(gsurf, b);
        }
        printf("RESULT chain check sync=%s: %d frames, %d stale, corner top-right green in %d; ms/frame render+lock "
               "%.2f (issue %.2f swap %.2f lock %.2f) wait %.2f import+blit+finish %.2f\n",
               argv[4], frames, stale, cornerOk, tRender * 1e3 / frames, tIssue * 1e3 / (frames + 1),
               tSwap * 1e3 / (frames + 1), tLock * 1e3 / (frames + 1), tWait * 1e3 / frames, tBlit * 1e3 / frames);
        return 0;
    }

    // plane: crtc and a free overlay, as in the plane mode
    drmModeRes* res = drmModeGetResources(fd);
    uint32_t crtc = 0; int crtcIdx = -1;
    drmModeModeInfo mode = { 0 };
    for (int i = 0; i < res->count_crtcs; i++) {
        drmModeCrtc* c = drmModeGetCrtc(fd, res->crtcs[i]);
        if (c && c->mode_valid && crtcIdx < 0) { crtc = c->crtc_id; crtcIdx = i; mode = c->mode; }
        drmModeFreeCrtc(c);
    }
    drmModePlaneRes* pr = drmModeGetPlaneResources(fd);
    uint32_t plane = 0;
    for (uint32_t i = 0; pr && i < pr->count_planes && !plane; i++) {
        drmModePlane* p = drmModeGetPlane(fd, pr->planes[i]);
        uint32_t tprop = prop_id(fd, p->plane_id, DRM_MODE_OBJECT_PLANE, "type");
        drmModeObjectProperties* props = drmModeObjectGetProperties(fd, p->plane_id, DRM_MODE_OBJECT_PLANE);
        uint64_t type = 99;
        for (uint32_t k = 0; k < props->count_props; k++)
            if (props->props[k] == tprop) type = props->prop_values[k];
        drmModeFreeObjectProperties(props);
        if (type == DRM_PLANE_TYPE_OVERLAY && (p->possible_crtcs & (1u << crtcIdx)) && !p->fb_id) plane = p->plane_id;
        drmModeFreePlane(p);
    }
    if (crtcIdx < 0 || !plane || !d[0].fb || !d[1].fb) { printf("RESULT chain plane: FAIL (crtc/plane/fb)\n"); return 1; }
    uint32_t rprop = prop_id(fd, plane, DRM_MODE_OBJECT_PLANE, "rotation");
    drmModeObjectSetProperty(fd, plane, DRM_MODE_OBJECT_PLANE, rprop, DRM_MODE_ROTATE_0);
    printf("crtc %u mode %ux%u plane %u\n", crtc, mode.hdisplay, mode.vdisplay, plane);
    double t0 = now(), tend = t0 + n;
    int frames = 0, fails = 0;
    while (now() < tend) {
        struct dst* t = &d[frames & 1];
        struct gbm_bo* b = chain_frame(fd, frames + 1, sync, t);
        if (!b) { fails++; break; }
        if (drmModeSetPlane(fd, plane, crtc, t->fb, 0, 0, 0, mode.hdisplay, mode.vdisplay, 0, 0, SH << 16, SW << 16))
            fails++;
        gbm_surface_release_buffer(gsurf, b);
        frames++;
    }
    double el = now() - t0;
    drmModeSetPlane(fd, plane, crtc, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    printf("RESULT chain plane sync=%s: %d frames in %.2f s (%.1f fps), %d failures; ms/frame render+lock %.2f wait "
           "%.2f import+blit+finish %.2f\n",
           argv[4], frames, el, frames / el, fails, tRender * 1e3 / frames, tWait * 1e3 / frames, tBlit * 1e3 / frames);
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: kmsprobe egl | plane dumb|tiled|egl ROT SECS | chain check N SYNC | chain plane SECS SYNC\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0); // a crash in the driver must not eat the output
    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("card0"); return 1; }
    drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
    // X drops master in LeaveVT; give a VT switch a few seconds to land.
    int master = 0, tries = 0;
    const int wantMaster = !strcmp(argv[1], "plane") || (!strcmp(argv[1], "chain") && argc > 2 && !strcmp(argv[2], "plane"));
    for (; tries < (wantMaster ? 20 : 1) && !master; tries++) {
        master = drmSetMaster(fd) == 0;
        if (!master) usleep(250000);
    }
    printf("DRM master: %s (%d tries%s%s)\n", master ? "yes" : "no", tries, master ? "" : ", ", master ? "" : strerror(errno));

    if (!strcmp(argv[1], "chain")) return chain(fd, argc, argv, master);

    if (!strcmp(argv[1], "egl")) {
        struct gbm_bo* bo = egl_frame(fd, 0);
        if (!bo) { printf("RESULT egl: FAIL (no front buffer)\n"); return 1; }
        uint32_t h = gbm_bo_get_handle(bo).u32, pitch = gbm_bo_get_stride(bo);
        printf("front bo: %ux%u stride %u handle %u format 0x%x\n", gbm_bo_get_width(bo), gbm_bo_get_height(bo),
               pitch, h, gbm_bo_get_format(bo));
        uint32_t fb = add_fb(fd, h, pitch, 0);
        printf("RESULT egl: %s (fb %u)\n", fb ? "OK" : "FAIL at AddFB2", fb);
        // Time 300 frames of render + lock/release (no display): does the surface cycle?
        gbm_surface_release_buffer(gsurf, bo);
        double t0 = now();
        for (int i = 1; i <= 300; i++) {
            struct gbm_bo* b = egl_frame(fd, i);
            if (!b) { printf("frame %d: no buffer\n", i); break; }
            gbm_surface_release_buffer(gsurf, b);
        }
        printf("300 frames in %.3f s\n", now() - t0);
        return 0;
    }

    if (strcmp(argv[1], "plane") || argc < 5) { fprintf(stderr, "bad args\n"); return 2; }
    if (!master) { printf("RESULT plane: FAIL (not master; switch X away first)\n"); return 1; }
    const char* src = argv[2];
    uint64_t rot = strtoull(argv[3], NULL, 0);
    int secs = atoi(argv[4]);

    drmModeRes* res = drmModeGetResources(fd);
    uint32_t crtc = 0; int crtcIdx = -1;
    drmModeModeInfo mode = { 0 };
    for (int i = 0; i < res->count_crtcs; i++) {
        drmModeCrtc* c = drmModeGetCrtc(fd, res->crtcs[i]);
        if (c && c->mode_valid && crtcIdx < 0) { crtc = c->crtc_id; crtcIdx = i; mode = c->mode; }
        drmModeFreeCrtc(c);
    }
    if (crtcIdx < 0) { printf("RESULT plane: FAIL (no active CRTC)\n"); return 1; }
    printf("crtc %u mode %ux%u\n", crtc, mode.hdisplay, mode.vdisplay);
    drmModePlaneRes* pr = drmModeGetPlaneResources(fd);
    uint32_t plane = 0;
    for (uint32_t i = 0; i < pr->count_planes; i++) {
        drmModePlane* p = drmModeGetPlane(fd, pr->planes[i]);
        uint32_t tprop = prop_id(fd, p->plane_id, DRM_MODE_OBJECT_PLANE, "type");
        drmModeObjectProperties* props = drmModeObjectGetProperties(fd, p->plane_id, DRM_MODE_OBJECT_PLANE);
        uint64_t type = 99;
        for (uint32_t k = 0; k < props->count_props; k++)
            if (props->props[k] == tprop) type = props->prop_values[k];
        drmModeFreeObjectProperties(props);
        printf("plane %u type %llu crtcs 0x%x fb %u\n", p->plane_id, (unsigned long long)type, p->possible_crtcs, p->fb_id);
        if (!plane && type == DRM_PLANE_TYPE_OVERLAY && (p->possible_crtcs & (1u << crtcIdx)) && !p->fb_id)
            plane = p->plane_id;
        drmModeFreePlane(p);
    }
    if (!plane) { printf("RESULT plane: FAIL (no free overlay)\n"); return 1; }

    uint32_t fb = 0;
    struct omap_device* od = NULL;
    struct omap_bo* ob = NULL;
    struct gbm_bo* gbo = NULL;
    if (!strcmp(src, "dumb")) {
        struct drm_mode_create_dumb cd = { .width = W, .height = H, .bpp = 32 };
        if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) { perror("create dumb"); return 1; }
        struct drm_mode_map_dumb md = { .handle = cd.handle };
        drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md);
        uint32_t* p = mmap(NULL, cd.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, md.offset);
        pattern(p, cd.pitch / 4);
        fb = add_fb(fd, cd.handle, cd.pitch, 0);
    } else if (!strcmp(src, "tiled")) {
        od = omap_device_new(fd);
        ob = omap_bo_new_tiled(od, W, H, OMAP_BO_TILED_32 | OMAP_BO_SCANOUT | OMAP_BO_WC);
        if (!ob) { printf("RESULT plane: FAIL (omap_bo_new_tiled)\n"); return 1; }
        uint32_t* p = omap_bo_map(ob);
        uint32_t size = omap_bo_size(ob);
        // The CPU view of a TILER 2D buffer is linear with the container's stride; take it from the size.
        uint32_t pitch = size / H;
        printf("tiled bo size %u -> pitch %u\n", size, pitch);
        omap_bo_cpu_prep(ob, OMAP_GEM_WRITE);
        pattern(p, pitch / 4);
        omap_bo_cpu_fini(ob, OMAP_GEM_WRITE);
        fb = add_fb(fd, omap_bo_handle(ob), pitch, 0);
        if (!fb) fb = add_fb(fd, omap_bo_handle(ob), W * 4, 0);
    } else if (!strcmp(src, "egl")) {
        gbo = egl_frame(fd, 0);
        if (!gbo) { printf("RESULT plane: FAIL (egl)\n"); return 1; }
        fb = add_fb(fd, gbm_bo_get_handle(gbo).u32, gbm_bo_get_stride(gbo), 0);
    }
    if (!fb) { printf("RESULT plane: FAIL (no fb)\n"); return 1; }

    // Rotation first (legacy SetPlane has no rotation argument), then the scaled plane over the whole
    // panel. The panel is 720x1280; a rotated 640x360 source fills it at 2x.
    uint32_t rprop = prop_id(fd, plane, DRM_MODE_OBJECT_PLANE, "rotation");
    int rr = drmModeObjectSetProperty(fd, plane, DRM_MODE_OBJECT_PLANE, rprop, rot);
    printf("rotation %llu: %s\n", (unsigned long long)rot, rr ? strerror(-rr) : "ok");
    uint32_t cw = mode.hdisplay, ch = mode.vdisplay;
    if (rot == DRM_MODE_ROTATE_0 || rot == DRM_MODE_ROTATE_180) { cw = mode.hdisplay; ch = mode.hdisplay * H / W; }
    int r = drmModeSetPlane(fd, plane, crtc, fb, 0, 0, 0, cw, ch, 0, 0, W << 16, H << 16);
    printf("SetPlane %u -> %ux%u from %dx%d: %s\n", plane, cw, ch, W, H, r ? strerror(errno) : "ok");
    if (r) { printf("RESULT plane %s rot %llu: FAIL\n", src, (unsigned long long)rot); return 1; }

    // For egl, keep rendering and flipping the plane to the new buffer every frame for SECS seconds.
    double t0 = now(), tend = t0 + secs;
    int frames = 0, fails = 0;
    if (gbo) {
        struct gbm_bo* shown = gbo;
        uint32_t shownFb = fb;
        while (now() < tend) {
            struct gbm_bo* nb = egl_frame(fd, ++frames);
            if (!nb) { fails++; break; }
            uint32_t nfb = add_fb(fd, gbm_bo_get_handle(nb).u32, gbm_bo_get_stride(nb), 0);
            if (!nfb || drmModeSetPlane(fd, plane, crtc, nfb, 0, 0, 0, cw, ch, 0, 0, W << 16, H << 16)) fails++;
            drmModeRmFB(fd, shownFb);
            gbm_surface_release_buffer(gsurf, shown);
            shown = nb; shownFb = nfb;
        }
        printf("egl: %d frames in %.2f s (%.1f fps), %d failures\n", frames, now() - t0, frames / (now() - t0), fails);
    } else {
        sleep(secs);
    }
    drmModeSetPlane(fd, plane, crtc, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    printf("RESULT plane %s rot %llu: shown\n", src, (unsigned long long)rot);
    return 0;
}
