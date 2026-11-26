/* xsend: send one key press or one left click to the X display, through XTest.
 *
 *   xsend key <keysym> [modifier-keysym]   e.g. xsend key Escape, xsend key Return Alt_L
 *   xsend click <x> <y>                    root coordinates
 *
 * The trixie image has no xdotool and no X development headers, but it has
 * libX11 and libXtst, so the few prototypes needed are declared here:
 *
 *   gcc -O1 -o xsend xsend.c /usr/lib/arm-linux-gnueabihf/libXtst.so.6 \
 *       /usr/lib/arm-linux-gnueabihf/libX11.so.6
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct _XDisplay Display;
typedef unsigned long KeySym;
typedef unsigned char KeyCode;

Display *XOpenDisplay(const char *);
int XCloseDisplay(Display *);
int XFlush(Display *);
KeySym XStringToKeysym(const char *);
KeyCode XKeysymToKeycode(Display *, KeySym);
int XTestFakeKeyEvent(Display *, unsigned, int, unsigned long);
int XTestFakeButtonEvent(Display *, unsigned, int, unsigned long);
int XTestFakeMotionEvent(Display *, int, int, int, unsigned long);

int main(int argc, char **argv)
{
	Display *d = XOpenDisplay(NULL);
	if (!d) {
		fputs("cannot open display\n", stderr);
		return 1;
	}
	if (argc >= 3 && !strcmp(argv[1], "key")) {
		KeySym sym = XStringToKeysym(argv[2]);
		KeyCode mod = 0, key = sym ? XKeysymToKeycode(d, sym) : 0;
		if (!key) {
			fprintf(stderr, "no keycode for %s\n", argv[2]);
			return 1;
		}
		if (argc >= 4) {
			mod = XKeysymToKeycode(d, XStringToKeysym(argv[3]));
			XTestFakeKeyEvent(d, mod, 1, 0);
		}
		XTestFakeKeyEvent(d, key, 1, 0);
		XFlush(d);
		usleep(80000);
		XTestFakeKeyEvent(d, key, 0, 0);
		if (mod)
			XTestFakeKeyEvent(d, mod, 0, 0);
	} else if (argc >= 4 && !strcmp(argv[1], "click")) {
		XTestFakeMotionEvent(d, -1, atoi(argv[2]), atoi(argv[3]), 0);
		XFlush(d);
		usleep(80000);
		XTestFakeButtonEvent(d, 1, 1, 0);
		XFlush(d);
		usleep(80000);
		XTestFakeButtonEvent(d, 1, 0, 0);
	} else {
		fputs("usage: xsend key <keysym> [modifier] | xsend click <x> <y>\n", stderr);
		XCloseDisplay(d);
		return 2;
	}
	XFlush(d);
	XCloseDisplay(d);
	return 0;
}
