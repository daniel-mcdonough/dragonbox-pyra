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

## Stage 1, a scaled plane: blocked by the X driver

Showing a plane needs DRM master, and X never gives it up on a VT switch: `xserver-xorg-video-armsoc-omap5`
0.6 reference-counts master (`ARMSOCSetDRMMaster`/`ARMSOCDropDRMMaster`), takes it in ScreenInit and again in
the first EnterVT (count 2), and LeaveVT only calls `drmDropMaster` at count 1. `drmSetMaster` from another
process fails with EINVAL for as long as VT 2 is in front (source: `~/git/dragonbox-pyra-build/ddx`).
