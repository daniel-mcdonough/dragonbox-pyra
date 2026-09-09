/*
 * pyra-exa-fallback-bench — measure the cost of the omap5 DDX's EXA fallbacks.
 *
 * The Viv2D driver rejects some operations and lets the X server do them in
 * software. This measures what that costs, and separates three things that
 * are easy to confuse: the GC320's speed, the X server's software path, and
 * the CPU's own memory bandwidth.
 *
 * The trick used throughout is VIV2D_MAX_SIZE. Pixmaps larger than 16 MB get
 * plain malloc instead of a write-combine GPU buffer, so sizing a pixmap
 * above or below that line runs the same code against different memory and
 * isolates the mapping from the code path.
 *
 *   gcc -O2 -o pyra-exa-fallback-bench pyra-exa-fallback-bench.c -lX11
 *
 * Fills into offscreen pixmaps queue into the command stream and are not
 * synchronised by XSync, so treat any figure above about 2000 Mpix/s as
 * "queued, not executed" rather than as a throughput result. The software
 * paths are synchronous and do not have this problem.
 */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static Display *dpy;
static int errors;
static int eh(Display *d, XErrorEvent *e) { errors++; return 0; }

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void hdr(const char *s) { printf("\n== %s\n", s); }

/* depth 24 is stored at 32 bits per pixel on this server */
static int bpp_of(int depth) { return depth > 16 ? 4 : (depth > 8 ? 2 : 1); }

static volatile unsigned long sink;

static void report(const char *label, double t, int reps, double bytes, double pix)
{
	printf("  %-42s %9.2f us/op %8.1f MB/s %9.1f Mpix/s%s\n", label,
	       t / reps * 1e6, bytes * reps / t / 1e6, pix * reps / t / 1e6,
	       errors ? "  [X ERRORS]" : "");
}

static void fill(const char *label, int depth, int func, int pw, int ph, int size, int reps)
{
	Pixmap p = XCreatePixmap(dpy, DefaultRootWindow(dpy), pw, ph, depth);
	XGCValues v;
	int i;

	v.function = func;
	v.foreground = 0x00ff00ff;
	GC gc = XCreateGC(dpy, p, GCFunction | GCForeground, &v);

	for (i = 0; i < 10; i++)
		XFillRectangle(dpy, p, gc, 0, 0, size, size);
	XSync(dpy, False);

	errors = 0;
	double t0 = now();
	for (i = 0; i < reps; i++)
		XFillRectangle(dpy, p, gc, i & 15, i & 15, size, size);
	XSync(dpy, False);
	report(label, now() - t0, reps, (double)size * size * bpp_of(depth),
	       (double)size * size);

	XFreeGC(dpy, gc);
	XFreePixmap(dpy, p);
}

static void copy(const char *label, int depth, int func, int pw, int ph, int size, int reps)
{
	Pixmap s = XCreatePixmap(dpy, DefaultRootWindow(dpy), pw, ph, depth);
	Pixmap d = XCreatePixmap(dpy, DefaultRootWindow(dpy), pw, ph, depth);
	XGCValues v;
	int i;

	v.function = GXcopy;
	v.foreground = 0x00abcdef;
	GC init = XCreateGC(dpy, s, GCFunction | GCForeground, &v);
	XFillRectangle(dpy, s, init, 0, 0, pw, ph);
	XFillRectangle(dpy, d, init, 0, 0, pw, ph);
	XSync(dpy, False);

	v.function = func;
	GC gc = XCreateGC(dpy, d, GCFunction, &v);
	for (i = 0; i < 10; i++)
		XCopyArea(dpy, s, d, gc, 0, 0, size, size, 0, 0);
	XSync(dpy, False);

	errors = 0;
	double t0 = now();
	for (i = 0; i < reps; i++)
		XCopyArea(dpy, s, d, gc, 0, 0, size, size,
		          (i * 71) % (pw - size), (i * 37) % (ph - size));
	XSync(dpy, False);
	report(label, now() - t0, reps, (double)size * size * bpp_of(depth),
	       (double)size * size);

	XFreeGC(dpy, init);
	XFreeGC(dpy, gc);
	XFreePixmap(dpy, s);
	XFreePixmap(dpy, d);
}

static void getimg(const char *label, int pw, int ph, int size, int reps)
{
	Pixmap p = XCreatePixmap(dpy, DefaultRootWindow(dpy), pw, ph, 24);
	XGCValues v;
	int i;

	v.function = GXcopy;
	v.foreground = 0x00123456;
	GC gc = XCreateGC(dpy, p, GCFunction | GCForeground, &v);
	XFillRectangle(dpy, p, gc, 0, 0, pw, ph);
	XSync(dpy, False);

	errors = 0;
	double t0 = now();
	for (i = 0; i < reps; i++) {
		XImage *im = XGetImage(dpy, p, 0, 0, size, size, AllPlanes, ZPixmap);
		if (im)
			XDestroyImage(im);
	}
	report(label, now() - t0, reps, (double)size * size * 4, (double)size * size);

	XFreeGC(dpy, gc);
	XFreePixmap(dpy, p);
}

static void memcpy_floor(void)
{
	size_t n = 1000 * 1000;
	char *a = malloc(n), *b = malloc(n);
	int i;

	if (!a || !b)
		return;
	memset(a, 1, n);
	memset(b, 2, n);
	double t0 = now();
	for (i = 0; i < 200; i++) {
		memcpy(b, a, n);
		sink += (unsigned char)b[i];
	}
	report("userspace memcpy 1MB", now() - t0, 200, (double)n, 0);
	free(a);
	free(b);
}

int main(void)
{
	int n, i;

	dpy = XOpenDisplay(NULL);
	if (!dpy) {
		fprintf(stderr, "cannot open display\n");
		return 1;
	}
	XSetErrorHandler(eh);

	XPixmapFormatValues *pf = XListPixmapFormats(dpy, &n);
	printf("server pixmap formats:");
	for (i = 0; i < n; i++)
		printf(" %d/%d", pf[i].depth, pf[i].bits_per_pixel);
	printf("\n");
	XFree(pf);

	hdr("baselines");
	memcpy_floor();
	copy("hardware copy 500x500 d24 (4MB pixmaps)", 24, GXcopy, 1024, 1024, 500, 400);
	copy("software copy 500x500 d24 (26MB pixmaps)", 24, GXcopy, 2560, 2560, 500, 100);

	hdr("fallback 1: raster ops other than GXcopy");
	fill("XOR fill 1000x1000 d24 (GPU buffer)", 24, GXxor, 1024, 1024, 1000, 40);
	fill("XOR fill 1000x1000 d24 (malloc)", 24, GXxor, 2560, 2560, 1000, 40);
	fill("copy fill 1000x1000 d24 (malloc, control)", 24, GXcopy, 2560, 2560, 1000, 400);

	hdr("fallback 2: A8 destination, split by operation");
	fill("A8 fill 1000x1000 (GPU buffer)", 8, GXcopy, 2048, 2048, 1000, 400);
	fill("A8 fill 1000x1000 (malloc)", 8, GXcopy, 8192, 4096, 1000, 400);
	copy("A8 copy 1000x1000 (GPU buffer)", 8, GXcopy, 2048, 2048, 1000, 40);
	copy("A8 copy 1000x1000 (malloc)", 8, GXcopy, 8192, 4096, 1000, 40);

	hdr("does the write-combine mapping cost anything? (readback)");
	getimg("GetImage 1000x1000 d24 (GPU buffer)", 1024, 1024, 1000, 20);
	getimg("GetImage 1000x1000 d24 (malloc)", 2560, 2560, 1000, 20);

	hdr("fallback 3: per-operation size, for a Viv2DPrepareCopy cutoff");
	copy("copy 8x8 d24", 24, GXcopy, 1024, 1024, 8, 20000);
	copy("copy 16x16 d24", 24, GXcopy, 1024, 1024, 16, 20000);
	copy("copy 32x32 d24", 24, GXcopy, 1024, 1024, 32, 20000);
	copy("copy 64x64 d24", 24, GXcopy, 1024, 1024, 64, 20000);

	XCloseDisplay(dpy);
	return 0;
}
