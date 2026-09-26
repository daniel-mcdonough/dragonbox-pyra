# GPU tools: a frame debugger (apitrace) and counters (PVRTune)

`docs/profiling-guide.md` §3.2 says there is no GPU profiling on this part. That was never
tested. This directory is the attempt.

## apitrace — frame debugger

**Built, not yet run on the device.**

apitrace records every EGL/GLES call through an `LD_PRELOAD` wrapper. The trace opens in
`qapitrace` on the desktop (Arch: `pacman -S apitrace`, 14.0), where each draw can be stepped
through with its GL state, bound textures, shader source and framebuffer contents. The desktop
replays the trace on Mesa's GLES2. It is a correctness and state tool. It gives no GPU timings:
GLES2 on the SGX has no timer queries.

```sh
./build-apitrace.sh            # cross-build in Shipwright's soh-pyra-cross image
./build-apitrace.sh install    # stage into out/apitrace (~124 MB with debug info)
rsync -a out/apitrace/ pyra@<host>:apitrace/
```

`APITRACE_TAG` (14.0) matches Arch's package, so the trace format is the same at both ends.
Source is cloned into `~/git/dragonbox-pyra-supporing-repos/apitrace`.

### Tracing Ship of Harkinian

Shipwright's `bench.sh run` passes any `VAR=VAL` through to the game's environment, so no
harness change is needed:

```sh
cd ~/git/Shipwright
PYRA_DIR=/home/pyra/soh-bench2 ./scripts/pyra/bench.sh run $MARKET \
    LD_PRELOAD=/home/pyra/apitrace/lib/apitrace/wrappers/egltrace.so \
    TRACE_FILE=/home/pyra/soh-market.trace SOH_BENCH_FRAMES=30
# on the device: keep only the last few frames
~/apitrace/bin/apitrace trim --frames=400-410 -o market-10f.trace soh-market.trace
```

Why the preload should catch everything:

- libultraship calls GL directly and is linked against the DDK's `libGLESv2.so.1`. The
  preloaded wrapper interposes those calls, and it finds the real ones with
  `dlsym(RTLD_NEXT)`, which returns the DDK's.
- SDL `dlopen`s `SDL_VIDEO_GL_DRIVER` (`…/libGLESv2.so.1`). apitrace only redirects
  `dlopen` for `libGLESv2.so`/`.so.2`, so that handle is left alone. SoH's own draws do not go
  through it.
- SDL's `dlopen("libEGL.so.1")` *is* redirected, so `eglSwapBuffers` is traced, and that is
  what marks frame boundaries.
- The one pointer SoH fetches itself is `glDiscardFramebufferEXT`, through
  `SDL_GL_GetProcAddress` (`gfx_opengl.cpp:1808`). If SDL resolves it from the DDK handle
  instead of through the wrapped `eglGetProcAddress`, the end-of-frame discard is missing from
  the trace. Nothing else is affected.

A traced run is slow. Its timings are not measurements.

### Replaying on the device

`eglretrace` looks up `libGLESv2.so.2`, which on the Pyra is glvnd → Mesa → llvmpipe (the
same trap as Shipwright report 6 §6.4). Point it at the DDK with a symlink directory, without
patching the source:

```sh
mkdir -p ~/ddk-shim
ln -sf /opt/omap5-sgx-ddk-um-linux/lib/libGLESv2.so.1 ~/ddk-shim/libGLESv2.so.2
ln -sf /opt/omap5-sgx-ddk-um-linux/lib/libEGL.so.1    ~/ddk-shim/libEGL.so.1
DISPLAY=:0 LD_LIBRARY_PATH=~/ddk-shim ~/apitrace/bin/eglretrace --benchmark --loop=100 market-10f.trace
```

Check the first lines of the log for `PowerVR SGX 544MP`. A looped replay of trimmed frames is
the game's GL stream with none of the game's own CPU work: the interpreter, logic and
interpolation are gone, and only the driver's CPU side and the GPU remain. If the replay runs
far faster than 30 fps, the GL side has headroom at the cap. This is not a GPU timing, because
the driver's per-draw CPU cost (~10–17 µs, Shipwright §8.37) is still in it.

## PVRTune — hardware counters

**Not obtained yet.** It needs an Imagination developer account to download.

- Imagination still distributes a legacy **"PVRTune for SGX"** (`.tgz`, Windows / Linux x64),
  with the device-side server included. It is reported working on an SGX530 BeagleBone Black.
- TI's Processor SDK documented PVRTune with PVRPerfServerDeveloper on its SGX Linux boards,
  including AM57x: the same SGX544 and the same TI DDK family as the Pyra's `1.14.3699939`.
- The Pyra's DDK ships `libPVRScopeServices.so.1`. It exports only `pvrssGetProcAddress`, and
  contains `SGXReadHWPerfCB`, the services call that reads the SGX hardware-performance buffer.

**The unknown:** whether the Letux build of `pvrsrvkm_omap5_sgx544_116` has the SGX
performance counters compiled in. Running the server settles it: counters stream or they
don't. A server/DDK version mismatch is the other known failure ("SGXPerfServer / PVRTune pair
do not match" on Imagination's forum), and may mean trying more than one legacy release.

Plan: unpack the download into `pvrtune/` here (git-ignored — redistribution terms), run the armhf
server on the Pyra and connect PVRTune from the desktop over USB networking. Take the frozen
Market fixture at the 30 fps cap, then real play.

If the counters are not there, the fallback is an `EGL_KHR_fence_sync` timestamp per frame in
Shipwright's `benchmark.cpp` (`GL_OES_egl_sync` is advertised). It gives GPU completion time
per frame, which is enough to say whether the frame is GPU-bound at the cap.
