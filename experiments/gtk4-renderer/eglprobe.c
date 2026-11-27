/* R131: make the EGL context requests GTK 4.18 makes, against whatever libEGL.so.1 resolves to.
 * Needs libegl-dev and libx11-dev on the card (not in the image). Build and run there:
 *   gcc -O1 -o eglprobe eglprobe.c -lEGL -lX11 && DISPLAY=:0 ./eglprobe
 */
#define _GNU_SOURCE
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <X11/Xlib.h>
#include <stdio.h>
#include <dlfcn.h>
#include <link.h>

static void try(EGLDisplay d, EGLConfig c, EGLenum api, int major, int minor, const char *what)
{
	EGLint a[] = { EGL_CONTEXT_MAJOR_VERSION_KHR, major, EGL_CONTEXT_MINOR_VERSION_KHR, minor, EGL_NONE };
	EGLBoolean b = eglBindAPI(api);
	EGLContext ctx = eglCreateContext(d, c, EGL_NO_CONTEXT, a);
	printf("%-28s bindAPI=%d context=%s error=0x%x\n", what, b, ctx ? "OK" : "NULL", eglGetError());
	if (ctx) {
		EGLBoolean m = eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx);
		printf("%-28s surfaceless makeCurrent=%d error=0x%x\n", "", m, eglGetError());
		eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
		eglDestroyContext(d, ctx);
	}
}

int main(void)
{
	Display *x = XOpenDisplay(NULL);
	EGLDisplay d = eglGetDisplay((EGLNativeDisplayType)x);
	EGLint maj, min, n;
	Dl_info info;
	if (dladdr((void *)eglGetDisplay, &info)) printf("eglGetDisplay from %s\n", info.dli_fname);
	if (!eglInitialize(d, &maj, &min)) { printf("eglInitialize failed 0x%x\n", eglGetError()); return 1; }
	printf("EGL %d.%d\nvendor: %s\nversion: %s\nclient APIs: %s\nextensions: %s\n", maj, min,
	       eglQueryString(d, EGL_VENDOR), eglQueryString(d, EGL_VERSION),
	       eglQueryString(d, EGL_CLIENT_APIS), eglQueryString(d, EGL_EXTENSIONS));
	printf("client extensions: %s\n", eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS));
	printf("eglGetProcAddress(eglQueryDisplayAttribEXT) = %p\n", (void *)eglGetProcAddress("eglQueryDisplayAttribEXT"));
	EGLint attr[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
	                  EGL_ALPHA_SIZE, 8, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE };
	EGLConfig c;
	if (!eglChooseConfig(d, attr, &c, 1, &n) || n < 1) { printf("no RGBA8888 ES2 window config\n"); return 1; }
	EGLint rt; eglGetConfigAttrib(d, c, EGL_RENDERABLE_TYPE, &rt);
	printf("config renderable type 0x%x (ES3 bit 0x40 %s, GL bit 0x8 %s)\n", rt, rt & 0x40 ? "set" : "clear", rt & 0x8 ? "set" : "clear");
	try(d, c, EGL_OPENGL_API, 3, 3, "GL 3.3 (GTK first)");
	try(d, c, EGL_OPENGL_ES_API, 3, 0, "GLES 3.0 (GTK floor)");
	try(d, c, EGL_OPENGL_API, 3, 0, "GL legacy");
	try(d, c, EGL_OPENGL_ES_API, 2, 0, "GLES 2.0 (not asked by GTK)");
	return 0;
}
