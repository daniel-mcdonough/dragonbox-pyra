# Can the game reach a scaled display plane outside X? (the SoH port's display-plane item)

Shipwright report 08 §8.52 priced the present pass at 0.13-0.16 W and found no plane reachable under X.
This is the feasibility test for the other road: the game on KMS itself. `kmsprobe.c` (build and run lines
in its header) runs on the device as root.

## Stage 0, render on KMS without X: works (2026-09-30)

- Mesa's libgbm (what the Pyra DDK package symlinks as `libgbm.so.2`) cannot drive the DDK: its DRI backend
  finds no 3D render driver next to omapdrm ("Error creating gpu or npu") and segfaults.
- The DDK's `libpvrGBMWSEGL` *is* the `gbm_pvr` backend (it exports `gbm_backend`) for TI's libgbm fork
  (git.ti.com glsdk/libgbm, a local copy (`libgbm`)). It must be that repo's
  **77a737d** layout (12 device functions; HEAD's `surface_import` shifts them) built with a **32-bit
  `struct stat`** (`-U_TIME_BITS -U_FILE_OFFSET_BITS -D_TIME_BITS=32 -D_FILE_OFFSET_BITS=32`): trixie's gcc
  defaults to time64, the frontend copies its larger stat into the device and overwrites the backend's
  function pointers. Built privately in `~/kmsprobe/tigbm`, loaded only with `LD_LIBRARY_PATH`.
- EGL takes its window system from `/etc/powervr.ini` (`libpvrDRI3WSEGL.so`, X). A `powervr.ini` in the
  working directory overrides it per process: `[default]` / `WindowSystem=libpvrGBMWSEGL.so.1`.
- Then: EGL 1.4 (IMG 1.14@3699939), PowerVR SGX 544MP renders a 640×360 XRGB8888 GBM surface, the front
  buffer (stride 2560) takes `drmModeAddFB2`. No master needed for any of that.
  No `EGL_EXT_image_dma_buf_import`; `EGL_KHR_surfaceless_context` is there.

## Stage 1, a scaled plane: works, except that the SGX cannot render into a rotatable buffer (2026-09-30)

**X kept DRM master on another VT.** `xserver-xorg-video-armsoc-omap5` 0.6 reference-counts master
(`ARMSOCSetDRMMaster`/`ARMSOCDropDRMMaster`), takes it in ScreenInit and again in the first EnterVT (count 2),
and LeaveVT only calls `drmDropMaster` at count 1: it never dropped, and `drmSetMaster` elsewhere failed with
EINVAL for as long as another VT was in front. `armsoc-0001-leavevt-drop-drm-master.patch` (a copy of
`../dragonbox-pyra-build/ddx/patches/0001-...`, which `build-ddx.sh` applies) drops it on LeaveVT and
re-takes it on EnterVT. Installed on the device as **0.6+dropmaster1** since 2026-09-30; the stock .deb is in
`../dragonbox-pyra-build/ddx/stock/` and `~/kmsprobe/` on the device (`sudo dpkg -i` it and restart
lightdm to go back). X came back and re-took master after every switch. Caveat: a program still holding master
when X's VT returns makes X's EnterVT fail; release the display before `chvt 7`.

`planetest.sh` (VT 2, five cases, back to VT 7), plane-2 on crtc-0 (720x1280 panel):

| buffer | rotation | result |
| --- | --- | --- |
| dumb (CPU filled) | 0 | accepted, 640x360 scaled to 720x405 |
| dumb | 270 | EINVAL: omapdrm rotates only TILER buffers |
| omap TILER (`omap_bo_new_tiled`, pitch 2560) | 270 | **accepted, 640x360 scaled 2x and rotated to 720x1280** |
| SGX through GBM | 0 | **accepted, rendered and flipped at 60.1 fps, 0 failures** |
| SGX through GBM | 270 | EINVAL: GBM's buffers are linear |

No DSS errors in dmesg. Accepted by the kernel; nobody watched the panel during these runs.

**The missing link.** DDK 1.14 renders only into its own GBM surface buffers (`libdbm`: linear or FBC
layouts; this backend predates TI libgbm's `surface_import`; EGL has no dma-buf or pixmap import), so the SGX
cannot draw straight into a TILER buffer. A rotated scanout needs the rotation elsewhere: a 640x360 rotate-copy
into a portrait 360x640 surface (a quarter of today's 1280x720 pass), the scene rendered rotated in the first
place (clip-space rotation in the interpreter, viewports/scissors/framebuffer reads transposed), or the GC320
2D core (etnaviv) blitting into TILER.

## The GC320 rotates exactly (2026-09-30)

`gc320rot.c` (register headers vendored in `viv2d/` from the armsoc driver, MIT) drives the GC320's 2D pipe through
libdrm_etnaviv's render node, alongside X. `gc320rot check` blits a coordinate-coded 640×360 source into 360×640
and classifies the result: source rotation gives an exact 90° counter-clockwise turn, destination rotation an
exact 90° clockwise one (0 mismatches of 230,400 each; `DE_ROT_ANGLE`'s mode field changes nothing on this core,
the rotation-config bits do it). ~1.2 ms a blit including submit and wait. X never writes the rotation registers,
so every stream resets them at its end and is reserved as one submit; X's desktop drew normally afterwards.
A GC320-rotated frame is linear, so the plane shows it unrotated, scaled 2×: no TILER buffer needed.
Watts: power-budget README, 2026-09-30 (+0.043 W against the skipped quad, vs +0.075 W for the SGX rotate-copy and +0.158 W for today's quad).

## The whole chain: SGX → dma-buf → GC320 rotate → scaled plane, 60 fps (2026-10-02)

`kmsprobe chain check N none|fence|finish` (alongside X, no master) and `chain plane SECS SYNC` (via
`chaintest.sh [SECS] [LOAD] [SYNC]`, which does the VT switch). The GC320 stream lives in `gc320.h`, shared with
`gc320rot`. `KMSPROBE_LOAD=N` draws N blended (ONE, ZERO) full-frame quads per frame: opaque ones cost nothing,
because the SGX's hidden-surface removal drops all but the last.

- The SGX's GBM bo exports from omapdrm (`drmPrimeHandleToFD` on card0) and imports into etnaviv
  (`etna_bo_from_dmabuf`); so do two `omap_bo_new(SCANOUT | WC)` 360×640 destination bos, which AddFB2 takes at
  pitch 1440. Imported once per GBM bo (kept as the bo's user data).
- `gbm_surface_lock_front_buffer` blocks until the SGX has finished the frame: at load 0/200/600 the lock is
  0.75/4.77/12.53 ms while issuing is 0.02/0.53/2.01 and the swap ~0.1. With no wait at all, 0 of ~1,400 frames
  were stale; an EGL fence after the lock waits a flat ~0.3 ms. Exception, not reproduced: the very first frame
  after boot read with its top rows still black.
- On the panel: 60.1 fps, 0 failures, blit 1.27 ms wall; the owner saw it the right way up (green top-left,
  landscape) with smooth colour and no tearing. plane-0 (X's 1280×720 fb) kept scanning out underneath: a game
  build should disable it while it runs.

Report: Shipwright report 08 §8.55.
