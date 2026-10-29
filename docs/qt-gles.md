# GLES2 for toolkits: the SONAME gap between the blob and glvnd

> **Type: instructions.** Steps to follow.

Tested 2026-09-18 on the running unit, kernel `5.6.19-freq`. Works.

`gl4es.md` covers desktop GL, which this image gets by translation. This
document covers the other half: programs that ask for **GLES2 by linking the
distribution's `libGLESv2`**, which is every Qt5 toolkit program. As shipped,
none of them render. The cause is not the driver and not the X server, and the
cure is one symlink.

`device/pyra-gles` is the wrapper that applies it.

## The symptom: a context that works and a GL that does not

`qmlscene` on a trivial Qt Quick scene, with `QSG_INFO=1`:

    qt.scenegraph.general: threaded render loop
    ./dri3_ws.c:843: WSEGL_SwapControlInterval: WSEGL_SwapControlInterval 1
    qt.scenegraph.general: opengl texture atlas dimensions: -1370018632x-1370018632
    qt.scenegraph.general: GL_VENDOR:
    qt.scenegraph.general: GL_RENDERER:
    qt.scenegraph.general: GL_VERSION:
    qt.scenegraph.general: Max Texture Size: 0
    QOpenGLShaderProgram: could not create shader program
    QOpenGLShader: could not create shader
    shader compilation failed:
    ""

Read the second line before the empty ones. `WSEGL_SwapControlInterval` is
printed by `libpvrDRI3WSEGL`, so EGL came from the DDK blob, found the X
server, negotiated a DRI3 window and created a real context on the SGX. The
window is correct. Then every GL call into it returns nothing: no vendor
string, no renderer string, a maximum texture size of zero, and no shader that
will compile.

Nothing is logged as an error anywhere, because from EGL's point of view
nothing failed.

## Why: two GLES2 libraries with different SONAMEs

There are two GLES2 implementations on this image.

| Which | File | SONAME | From |
| --- | --- | --- | --- |
| The SGX blob | `/opt/omap5-sgx-ddk-um-linux/lib/libGLESv2.so.1` | `libGLESv2.so.1` | the DDK, `1.14@3699939` |
| glvnd's dispatcher | `/usr/lib/arm-linux-gnueabihf/libGLESv2.so.2` | `libGLESv2.so.2` | `libgles2` 1.7.0-1+b2 |

`/etc/ld.so.conf.d/01_omap5-sgx-ddk-um-linux.conf` sorts first, which is what
gets `libEGL.so.1` resolved to the blob rather than to `libegl1`. But the
DDK ships no file called `libGLESv2.so.**2**`, and Qt — like anything built
against the archive's headers — records `libGLESv2.so.2` in its `DT_NEEDED`.
Path order cannot help with a name that does not exist. `LD_DEBUG=libs` on the
failing run, with no shim:

    calling init: /lib/arm-linux-gnueabihf/libGLESv2.so.2          <- glvnd, for Qt's GL calls
    calling init: /opt/omap5-sgx-ddk-um-linux/lib/libEGL.so.1      <- the blob, for Qt's EGL
    calling init: /opt/omap5-sgx-ddk-um-linux/lib/libGLESv2.so     <- the blob's own, loaded by its EGL

Both implementations are in the process, side by side, and Qt is talking to the
wrong one. glvnd routes a GL call to whichever vendor owns the current context,
and it learns its vendors from `/usr/share/glvnd/egl_vendor.d/`, which on this
image contains exactly one file, `50_mesa.json`. The blob is older than glvnd
and registers nothing there. So glvnd holds a context it has no vendor for, and
every entry point is a stub.

This is why the failure looks like a broken driver and is not one.

## The fix: one symlink, in front, per program

    ln -s /opt/omap5-sgx-ddk-um-linux/lib/libGLESv2.so.1  <dir>/libGLESv2.so.2
    LD_LIBRARY_PATH=<dir> <program>

`device/pyra-gles` does exactly that and nothing else. It keeps the symlink in
the caller's cache directory, rebuilds it on every run so a DDK upgrade cannot
leave it dangling, and refuses to build it against a file that does not carry
the SONAME `libGLESv2.so.1`:

    pyra-gles /usr/lib/arm-linux-gnueabihf/qt5/bin/qmlscene scene.qml
    pyra-gles --check
    pyra-gles --undo

No root, and nothing to install. The same run as above, with it:

    calling init: /home/pyra/.cache/pyra-gles/libGLESv2.so.2
    calling init: /opt/omap5-sgx-ddk-um-linux/lib/libEGL.so.1

glvnd is now not loaded at all, and the blob's GLES2 is loaded once, under both
of its names.

## Which programs this affects, and which it does not

The line is how the program gets to GLES2, not what it draws.

**Affected: anything with `libGLESv2.so.2` in its `DT_NEEDED`.** That is what
linking `-lGLESv2` against the archive's headers produces, and it is what
`libQt5Gui.so.5` carries:

    readelf -d /usr/lib/arm-linux-gnueabihf/libQt5Gui.so.5 | grep GLES
     0x00000001 (NEEDED)   Shared library: [libGLESv2.so.2]

**Not affected: anything that loads GLES2 itself at runtime.** `glmark2-es2` is
the useful control, because it is a pure GLES2 program that has always worked
here. It links neither library — `ldd` on it shows no `libEGL` and no
`libGLESv2` at all — and dlopens them by unversioned name instead, which lands
in the DDK directory:

    calling init: /opt/omap5-sgx-ddk-um-linux/lib/libEGL.so
    calling init: /opt/omap5-sgx-ddk-um-linux/lib/libGLESv2.so

It scores the same with the shim and without it — `pulsar` at 566 fps either
way — which is the cleanest demonstration that this is a linking problem and
not a driver one. Programs built against the DDK directly, like
`device/pyra-gles2-smoke.c` with its `-L/opt/omap5-sgx-ddk-um-linux/lib`, are
in the same clear.

**`ldconfig` will never create this link for you.** It files a library under
the SONAME recorded inside it, and the blob's says `.so.1`. The link has to be
made by hand, which is also why nothing in the archive has ever made it.

## What it gets you

Same scene, same machine, with the shim:

    GL_VENDOR:    Imagination Technologies
    GL_RENDERER:  PowerVR SGX 544MP
    GL_VERSION:   OpenGL ES 2.0 build 1.14@3699939 (MAIN)
    Max Texture Size: 4096
    threaded render loop

Measured fullscreen at 1280x720, frames counted from
`QSG_RENDER_TIMING=1` over eleven seconds:

| Scene | FPS | Median render |
| --- | --- | --- |
| 64 rotating rectangles, each with a text label | 117 | 5 ms |
| One animated card plus a row of eight tiles | 171 | 0 ms |

Qt Quick is not the constraint on this hardware. The first two or three frames
cost 60–90 ms because each shader is compiled on the SGX as it is first used —
about 8 ms apiece — so expect a visible pause at first paint and nothing after
it.

One thing to know before porting assets: the compressed texture formats the
blob advertises are PVRTC, PVRTC2 and ETC1. There is no S3TC. Textures
compressed for a desktop GPU will be decompressed on the CPU, or refused.

## Why this is not put into `ld.so.conf`

The same reason `gl4es` ships as a wrapper rather than replacing mesa's
`libGL`, and one more.

Adding the shim directory to `ld.so.conf` would hand the blob **every** GLES2
program on the machine, including the ones that must not have it: anything
rendering to a display that is not the local X server has no DRI3 window to
integrate with, and the blob is not a general-purpose software fallback the way
mesa is. One badly-placed link would turn a working remote or offscreen GLES
program into the failure at the top of this page, in the other direction and
just as silently.

Per program, by name, deliberately.

## What is not affected

- **gl4es.** It implements `glX*` itself and dlopens the blob by the blob's own
  name, so desktop GL through gl4es never went near this and needs no shim.
  `gl4es` and `pyra-gles` can be combined on one command line, in either order,
  but there is no reason to: a program either links `libGL` or links
  `libGLESv2`.
- **Programs that dlopen GLES2 themselves, or link the blob directly.** See the
  section above: `glmark2-es2` and `pyra-gles2-smoke.c` never had this problem,
  which is exactly why nothing warned about it.
- **The X server's GLX**, which fix 4 disables and this does not restore.

## Qt on this image, specifically

Debian's armhf Qt 5.15.15 is **already the GLES build** — `libQt5Gui.so.5`
links `libGLESv2.so.2`, not `libGL.so.1`. There is nothing to swap, and
`libqt5gui5-gles` (which exists in the archive for the architectures where the
default is desktop GL) is neither needed nor wanted here.

Two things cost time when reproducing this:

- `/usr/bin/qmlscene` is `qtchooser`'s wrapper and fails with `could not find a
  Qt installation of ''`. Run `/usr/lib/arm-linux-gnueabihf/qt5/bin/qmlscene`
  directly, or `qmlscene -qt5`.
- The Qt Quick runtime is not in the base image. `qmlscene`,
  `qml-module-qtquick2` and `qml-module-qtquick-window2` are enough to test.

## Status

This is a helper, not one of the numbered fixes: `pc/pyra-trixie-prep.sh` does not
install it and the card does not depend on it. Whether it should be promoted —
it is a silent, total failure of a whole class of software, which is the same
argument the other eight rest on — is an open decision.

It is also the prerequisite that made `docs/pegasus.md` worth writing.
