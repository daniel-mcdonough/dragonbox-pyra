# Can the game reach a scaled display plane outside X? (Shipwright NEXT.md item F)

Shipwright report 08 §8.52 priced the present pass at 0.13-0.16 W and found no plane reachable under X.
This is the feasibility test for the other road: the game on KMS itself. `kmsprobe.c` (build and run lines
in its header) runs on the device as root.

## Stage 0, render on KMS without X: works (2026-09-30)

- Mesa's libgbm (what the Pyra DDK package symlinks as `libgbm.so.2`) cannot drive the DDK: its DRI backend
  finds no 3D render driver next to omapdrm ("Error creating gpu or npu") and segfaults.
- The DDK's `libpvrGBMWSEGL` *is* the `gbm_pvr` backend (it exports `gbm_backend`) for TI's libgbm fork
  (git.ti.com glsdk/libgbm, a copy in `~/git/dragonbox-pyra-supporing-repos/libgbm`). It must be that repo's
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
`~/git/dragonbox-pyra-build/ddx/patches/0001-...`, which `build-ddx.sh` applies) drops it on LeaveVT and
re-takes it on EnterVT. Installed on the device as **0.6+dropmaster1** since 2026-09-30; the stock .deb is in
`~/git/dragonbox-pyra-build/ddx/stock/` and `~/kmsprobe/` on the device (`sudo dpkg -i` it and restart
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
