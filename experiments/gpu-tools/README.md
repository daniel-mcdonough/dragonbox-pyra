# GPU tools: a frame debugger (apitrace) and counters (PVRTune)

`docs/profiling-guide.md` §3.2 used to say there is no GPU profiling on this part. That was
never tested, and it was wrong: **PVRTune's hardware timing works on the stock `5.6.19-m4`
kernel and DDK, and apitrace records and replays the game** (2026-09-26).

## First result: Ship of Harkinian is not GPU-bound at the 30 fps cap

Frozen Market fixture, logic running, 30 fps cap (`SOH_BENCH_UNCAP=0`), CPU pinned at 1000 MHz,
die 61-63 °C, 42 s of steady frames (`captures/market-cap.pvrtune`, `pvrtune_frames.py`):

| | per frame | share of the 33.4 ms period |
|---|---|---|
| GPU busy (TA or 3D) | **6.9 ms** | **20.5%** |
| 3D (fragment) busy | 5.5 ms | 16.4% |
| TA (tiling) busy | 1.7 ms | 5.1% |
| render thread on-CPU (same run, `BENCH oncpu`) | 16.8 ms | 50.2% |

Each frame is two renders, told apart by the call stream in the apitrace capture:

| render | 3D time, mean (median, p95) | what it draws |
|---|---|---|
| scene: the 640×360 game framebuffer | **2.64 ms** (2.64, 3.24) | 145 draws, 11 TA kicks spread over the CPU's frame |
| present: the 1280×720 window | **2.87 ms** (2.81, 4.26) | a colour+depth clear and **one** ImGui quad (`glDrawElements`, 6 indices) sampling the game framebuffer, **alpha blending on** |

Presenting the picture costs the GPU more than drawing the Market. That is Shipwright NEXT.md
item F (let the display controller scale 640×360) and item 4 (the part of the swap that does
not scale with the game's pixels), now with a number. Candidates, none measured: blending off
for that quad, and not clearing a colour buffer the quad covers completely.

Caveats:
- Each render shows up as four 3D kicks. What the four are (the MP2's two cores, a split
  render, ...) is not established; the table sums them.
- PVRTune's derived "GPU clock speed" counter reads 270-410 MHz and moves with load. The clock
  is a fixed 425.47 MHz (`experiments/gpu-clock/`), so treat that counter as an estimate.
- The GPU's power domain never turns off (`experiments/power-budget/`), so the 80% idle time
  saves only dynamic power.

## apitrace — frame debugger

**Works on the device** (2026-09-26): the wrapper hooks `soh.elf`, SDL's EGL and the DDK,
and the desktop replays the Pyra's trace to the right picture. A traced frozen-Market run
of 460 frames is **4.4 GB** (client-array vertex data is copied into the trace at every draw), and the game runs at ~2 fps while traced.

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
    TRACE_FILE=/home/pyra/gpu-tools/soh-market.trace SOH_BENCH_UNCAP=0 SOH_BENCH_WARMUP=30 SOH_BENCH_FRAMES=30
scp pyra@<host>:gpu-tools/soh-market.trace ~/.cache/pyra-traces/
qapitrace ~/.cache/pyra-traces/soh-market.trace
```

Open the whole trace. `apitrace trim --frames=...` output does not replay (it drops the EGL
context and every texture loaded earlier), and `gltrim` keeps 630k of the calls.

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

`apitrace-pyra-waitnative.patch` (apply before building) is needed: the DDK's
`libpvrDRI3WSEGL.so` calls `abort()` from its unimplemented `eglWaitNative`, and apitrace's X11
window code calls that. The patch uses `XSync` instead.

`eglretrace` looks up `libGLESv2.so.2`, which on the Pyra is glvnd → Mesa → llvmpipe (the
same trap as Shipwright report 6 §6.4). Point it at the DDK with a symlink directory, without
patching the source:

```sh
mkdir -p ~/ddk-shim
ln -sf /opt/omap5-sgx-ddk-um-linux/lib/libGLESv2.so.1 ~/ddk-shim/libGLESv2.so.2
ln -sf /opt/omap5-sgx-ddk-um-linux/lib/libEGL.so.1    ~/ddk-shim/libEGL.so.1
DISPLAY=:0 LD_LIBRARY_PATH=~/ddk-shim ~/apitrace/bin/eglretrace --benchmark ~/gpu-tools/soh-market.trace
```

**Status:** a full replay on the device works (461 frames, the DDK loaded, two harmless
`ComputeFrameBufferCompleteness` messages), but only at ~2 fps: the replay is bound by
parsing the 4.4 GB trace. `--loop` did nothing on the full trace, and `apitrace trim` leaves out
the EGL context and the textures, so its output replays nothing (`no current context`).
`gltrim` keeps 630k of the calls and saves nothing. Next: cut the trace at the last
`eglSwapBuffers` and loop that, or record a shorter run (a lower `SOH_BENCH_SETTLE`).

Check with `LD_DEBUG=libs` that `libpvrDRI3WSEGL.so` and the DDK's `libGLESv2` load.

Why a looped replay is worth getting working: a looped frame is
the game's GL stream with none of the game's own CPU work: the interpreter, logic and
interpolation are gone, and only the driver's CPU side and the GPU remain. If the replay runs
far faster than 30 fps, the GL side has headroom at the cap. This is not a GPU timing, because
the driver's per-draw CPU cost (~10–17 µs, Shipwright §8.37) is still in it.

## PVRTune — hardware counters

**Works.** PVRTune for SGX (SDK 17.1, PVRPerfServerDeveloper v14.143), unpacked into `pvrtune/`
(git-ignored). The server identifies `DRIVER BUILD 1.14.369.9939`, `PowerVR SGX544MP2`,
`Series5XT`, and streams HWPerf TA/3D timing events plus derived counters (tiler/renderer
active, vertex and pixel load, HSR efficiency, memory words/s, per-CPU load).

```sh
scp pvrtune/PVRPerfServer/Linux_armv7hf/PVRPerfServerDeveloper pyra@<host>:gpu-tools/
# on the device. The server dlopens libPVRScopeServices.so, which lives in the DDK.
# The help flag is -h; --help is ignored and the server starts.
LD_LIBRARY_PATH=/opt/omap5-sgx-ddk-um-linux/lib ./PVRPerfServerDeveloper \
    --sendto=/home/pyra/gpu-tools/cap.pvrtune --qat=150 --pid
# stop it with pkill -INT so the file is closed. Then, on the desktop, with no GUI interaction:
pvrtune/GUI/Linux_x86_64/PVRTuneDeveloperGUI cap.pvrtune \
    --export-csv-timing=cap-timing.csv --export-csv-counters=cap-counters.csv
./pvrtune_frames.py cap-timing.csv 12 54      # seconds into the capture
```

In file mode the server records one counter group (group 0 by default, `--group=N`). Leave
out `--sendto` and connect the GUI over the network (port 6520) for live graphs.

Background, from before it was tried:

- Imagination still distributes a legacy **"PVRTune for SGX"** (`.tgz`, Windows / Linux x64),
  with the device-side server included. It is reported working on an SGX530 BeagleBone Black.
- TI's Processor SDK documented PVRTune with PVRPerfServerDeveloper on its SGX Linux boards,
  including AM57x: the same SGX544 and the same TI DDK family as the Pyra's `1.14.3699939`.
- The Pyra's DDK ships `libPVRScopeServices.so.1`. It exports only `pvrssGetProcAddress`, and
  contains `SGXReadHWPerfCB`, the services call that reads the SGX hardware-performance buffer.

The Letux build of `pvrsrvkm_omap5_sgx544_116` turned out to have HWPerf compiled in.
