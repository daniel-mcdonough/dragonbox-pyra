# Why GTK 4 crashes without fix 34

Fix 34 sets `GSK_RENDERER=cairo`. Without it, every GTK 4 program on the
trixie card (zenity, pavucontrol) aborts before it draws, each time with a
different glibc heap error. This folder holds the tools used to find out why
(2026-11-27, R99 test card, kernel `5.6.19-m4-kbdled`). The commands and
output are in [docs/verification-log.md](../../docs/verification-log.md)
(R131), and the summary is in [docs/fixes.md](../../docs/fixes.md), fix 34.

## The chain

1. **GTK 4.18 cannot get GL from the SGX.** libepoxy opens `libEGL.so.1`, and
   `ldconfig` resolves that to the DDK blob in `/opt/omap5-sgx-ddk-um-linux/lib`
   (its directory comes first in `ld.so.conf.d`). glvnd and mesa's EGL never
   load. The blob is EGL 1.4 with OpenGL ES 2.0 only. GTK asks for GL 3.3,
   GLES 3.0, then legacy GL, and `eglCreateContext` fails all three with
   `EGL_BAD_MATCH`. GTK says `Not using GL: Unable to create a GL context`.
2. **GTK then falls back to Vulkan.** On X11, `gsk_renderer_new_for_surface`
   turns down Vulkan first ("platform is not Wayland"). After GL fails, it tries
   `get_renderer_for_vulkan_fallback`, which accepts any device, CPU devices
   included. The only working device is lavapipe (mesa's software Vulkan,
   `llvmpipe (LLVM 19.1.7, 128 bits)`).
3. **lavapipe corrupts the heap on armhf.** mesa 25.0.7's generated
   `vk_cmd_queue.c` sizes each recorded command as
   `sizeof(struct vk_cmd_<name>) + sizeof(struct vk_cmd_queue_entry_base)`. On
   armhf the base is 20 bytes. The union `u` that holds the command sits at
   offset 24, because it contains 64-bit members and the ARM EABI aligns them to
   8. So every command's allocation is 4 bytes short, and each
   `vkCmd*` call writes past the end of its block. `vkcube` crashes the same
   way, so GTK is only the messenger.

Mesa fixed the size in 26.2.0, commit `9b7b28d7d5ed` ("vk/cmd_queue: simplify
gross struct duplication"), by using `offsetof(struct vk_cmd_queue_entry, u)`.
Trixie has 25.0.7, and trixie-backports' 26.1.6 still has the old line.

With the size table corrected in memory (`fixsizes.gdb`), the heap errors are
gone. llvmpipe's JIT code then calls address 0 in a rasterizer thread. So
lavapipe on armhf has at least one more fault, which nobody has investigated.

## Files

- `eglprobe.c`: makes GTK's three context requests, plus GLES 2.0, against
  `libEGL.so.1`, and prints the EGL strings. The build line is at the top.
- `fixsizes.gdb`: runs vkcube on lavapipe with every
  `vk_cmd_queue_type_sizes[]` entry 4 bytes larger.

## Tools that did and did not work here

- **valgrind is no use on armhf.** Debian's `default.supp` has a suppression,
  `stack-clash-protection-armhf`, that matches every `Addr4` error in every
  object. Memcheck then reported "0 errors", and segfaulted in the Vulkan loader
  (`vkEnumerateInstanceExtensionProperties`) before vkcube drew anything. That
  segfault is at a stack address and looks like a stack overflow. It isn't one.
- **electric-fence under gdb found the bad write at once:**
  `LD_PRELOAD=/usr/lib/libefence.so.0.0`, then `run` and `bt`. Add
  `EF_ALLOW_MALLOC_0=1`, or efence aborts on the first zero-size malloc.
- Debug symbols: `deb http://deb.debian.org/debian-debug trixie-debug main`,
  then `libgtk-4-1-dbgsym`, `mesa-vulkan-drivers-dbgsym`, `libvulkan1-dbgsym`.
  Everything installed for this run was removed afterwards.
