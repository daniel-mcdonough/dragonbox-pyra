/*
 * Minimal X11 + EGL + GLES2 smoke test for the Pyra's SGX 544MP.
 *
 * Deliberately not the DDK's own gles2test1: that is a direct-KMS test that
 * wants DRM master and fails whenever X is running, on bookworm too.
 *
 *   gcc -O2 -o pyra-gles2-smoke pyra-gles2-smoke.c \
 *       -I/opt/omap5-sgx-ddk-um-linux/include \
 *       -L/opt/omap5-sgx-ddk-um-linux/lib -lEGL -lGLESv2 -lX11
 */

#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <X11/Xlib.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>

#define WIN_W 320
#define WIN_H 240
#define RUN_SECONDS 5.0

static double now_sec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec + (double) ts.tv_nsec / 1e9;
}

static void report_ext(Display *dpy, const char *name, const char *note)
{
    int op, ev, err;
    if (XQueryExtension(dpy, name, &op, &ev, &err))
        printf("  %-10s present\n", name);
    else
        printf("  %-10s ABSENT%s\n", name, note ? note : "");
}

int main(void)
{
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "cannot open display (set DISPLAY and XAUTHORITY)\n");
        return 1;
    }

    printf("X extensions:\n");
    report_ext(dpy, "DRI3", "  <- needed by libpvrDRI3WSEGL");
    report_ext(dpy, "Present", "  <- needed by libpvrDRI3WSEGL");
    report_ext(dpy, "GLX", "  (expected: disabled by fix 4)");

    int scr = DefaultScreen(dpy);
    Window win = XCreateSimpleWindow(dpy, RootWindow(dpy, scr),
                                     0, 0, WIN_W, WIN_H, 0,
                                     BlackPixel(dpy, scr), BlackPixel(dpy, scr));
    XStoreName(dpy, win, "pyra gles2 smoke test");
    XMapWindow(dpy, win);
    XSync(dpy, False);

    EGLDisplay ed = eglGetDisplay((EGLNativeDisplayType) dpy);
    if (ed == EGL_NO_DISPLAY) {
        fprintf(stderr, "eglGetDisplay failed\n");
        return 1;
    }

    EGLint emaj, emin;
    if (!eglInitialize(ed, &emaj, &emin)) {
        fprintf(stderr, "eglInitialize failed: 0x%x\n", eglGetError());
        return 1;
    }

    printf("\nEGL:\n");
    printf("  EGL_VERSION  %d.%d\n", emaj, emin);
    printf("  EGL_VENDOR   %s\n", eglQueryString(ed, EGL_VENDOR));
    printf("  version str  %s\n", eglQueryString(ed, EGL_VERSION));

    if (!eglBindAPI(EGL_OPENGL_ES_API)) {
        fprintf(stderr, "eglBindAPI failed: 0x%x\n", eglGetError());
        return 1;
    }

    const EGLint cfg_attr[] = {
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE,        5,
        EGL_GREEN_SIZE,      6,
        EGL_BLUE_SIZE,       5,
        EGL_NONE
    };
    EGLConfig cfg;
    EGLint ncfg = 0;
    if (!eglChooseConfig(ed, cfg_attr, &cfg, 1, &ncfg) || ncfg < 1) {
        fprintf(stderr, "eglChooseConfig found nothing: 0x%x\n", eglGetError());
        return 1;
    }

    EGLSurface surf = eglCreateWindowSurface(ed, cfg, (EGLNativeWindowType) win, NULL);
    if (surf == EGL_NO_SURFACE) {
        fprintf(stderr, "eglCreateWindowSurface failed: 0x%x\n", eglGetError());
        return 1;
    }

    const EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext ctx = eglCreateContext(ed, cfg, EGL_NO_CONTEXT, ctx_attr);
    if (ctx == EGL_NO_CONTEXT) {
        fprintf(stderr, "eglCreateContext failed: 0x%x\n", eglGetError());
        return 1;
    }
    if (!eglMakeCurrent(ed, surf, surf, ctx)) {
        fprintf(stderr, "eglMakeCurrent failed: 0x%x\n", eglGetError());
        return 1;
    }

    printf("\nGLES2:\n");
    printf("  GL_VENDOR    %s\n", (const char *) glGetString(GL_VENDOR));
    printf("  GL_RENDERER  %s\n", (const char *) glGetString(GL_RENDERER));
    printf("  GL_VERSION   %s\n", (const char *) glGetString(GL_VERSION));

    /* Uncapped, so the number reflects the driver rather than the panel. */
    eglSwapInterval(ed, 0);

    unsigned long frames = 0;
    double t0 = now_sec(), t = t0;
    while ((t = now_sec()) - t0 < RUN_SECONDS) {
        float p = (float) ((t - t0) / RUN_SECONDS);
        glClearColor(0.15f + 0.5f * p, 0.10f, 0.55f - 0.4f * p, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        if (!eglSwapBuffers(ed, surf)) {
            fprintf(stderr, "eglSwapBuffers failed: 0x%x\n", eglGetError());
            return 1;
        }
        frames++;
    }

    double elapsed = t - t0;
    printf("\nthroughput (clear + swap, %dx%d, vsync off):\n", WIN_W, WIN_H);
    printf("  %lu frames in %.2f s = %.0f fps\n", frames, elapsed, frames / elapsed);

    eglMakeCurrent(ed, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(ed, ctx);
    eglDestroySurface(ed, surf);
    eglTerminate(ed);
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
