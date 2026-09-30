// kmsprobe: can the game reach a scaled display plane on the Pyra outside X? (Shipwright NEXT.md
// item F, report 08 §8.52-8.53.) Runs on the device, as root.
//
//   kmsprobe egl                  no master needed: GBM + the DDK's EGL, render 640x360, lock the front
//                                 buffer, AddFB2 it; prints the EGL/GL extensions that matter
//   kmsprobe plane SRC ROT SECS   needs DRM master (X switched away: chvt 2 first): show a 640x360
//                                 buffer on a free plane scaled to the whole panel, for SECS seconds.
//                                 SRC: dumb (CPU pattern), tiled (omap TILER bo, CPU pattern), egl (GBM
//                                 surface rendered by the SGX). ROT: the plane's rotation property value
//                                 (1 = 0°, 2 = 90°, 4 = 180°, 8 = 270°; X uses 8).
//
// Needs TI's libgbm fork (git.ti.com glsdk/libgbm c5ddc6a; the DDK's GBM window system is its gbm_pvr backend;
// Mesa's libgbm, which the Pyra package symlinks as libgbm.so.2, cannot drive it). Build it privately in tigbm/:
//   gcc -O2 -fPIC -shared -include sys/sysmacros.h -o tigbm/libgbm.so.2 src/{gbm,backend,common}.c -Isrc \
//     -DMODULEDIR='"/usr/lib/gbm"' -Wl,-soname,libgbm.so.2 -ludev -ldl
// Build (on the device): gcc -O2 -o kmsprobe kmsprobe.c -Itigbm/src -I/usr/include/libdrm -I/usr/include/omap
//   -I/opt/omap5-sgx-ddk-um-linux/include -L/opt/omap5-sgx-ddk-um-linux/lib -Ltigbm
//   -Wl,-rpath,/opt/omap5-sgx-ddk-um-linux/lib -ldrm -ldrm_omap -l:libgbm.so.2 -lEGL -lGLESv2
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
    glDisable(GL_SCISSOR_TEST);
    float k = (frame % 60) / 60.0f;
    glClearColor(k, 0.25f, 1.0f - k, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glEnable(GL_SCISSOR_TEST);
    glScissor(0, H - 45, 80, 45); // GL's origin is bottom-left: this is the top-left corner
    glClearColor(0, 1, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    if (!eglSwapBuffers(dpy, esurf)) {
        printf("eglSwapBuffers failed: 0x%x\n", eglGetError());
        return NULL;
    }
    return gbm_surface_lock_front_buffer(gsurf);
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

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: kmsprobe egl | plane dumb|tiled|egl ROT SECS\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0); // a crash in the driver must not eat the output
    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("card0"); return 1; }
    drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
    // X drops master in LeaveVT; give a VT switch a few seconds to land.
    int master = 0, tries = 0;
    for (; tries < (strcmp(argv[1], "plane") ? 1 : 20) && !master; tries++) {
        master = drmSetMaster(fd) == 0;
        if (!master) usleep(250000);
    }
    printf("DRM master: %s (%d tries%s%s)\n", master ? "yes" : "no", tries, master ? "" : ", ", master ? "" : strerror(errno));

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
