# R131: lavapipe (mesa 25.0.7, armhf) with every vk_cmd_queue_type_sizes[] entry 4 bytes larger,
# which is what mesa 26.2's offsetof(struct vk_cmd_queue_entry, u) gives on armhf. Needs gdb and
# mesa-vulkan-drivers-dbgsym (debian-debug archive). 213 entries and index 180 = VK_CMD_PIPELINE_BARRIER2
# hold for 25.0.7-2 only.
#   DISPLAY=:0 VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.json gdb -q -batch -x fixsizes.gdb --args vkcube --c 200
set debuginfod enabled off
set breakpoint pending on
set pagination off
break lvp_CreateDevice
commands
  silent
  printf "offsetof(u) = %d, PIPELINE_BARRIER2 size was %d\n", (int)&((struct vk_cmd_queue_entry*)0)->u, ((size_t*)&vk_cmd_queue_type_sizes)[180]
  set $i = 0
  while $i < 213
    set var ((size_t*)&vk_cmd_queue_type_sizes)[$i] = ((size_t*)&vk_cmd_queue_type_sizes)[$i] + 4
    set $i = $i + 1
  end
  printf "PIPELINE_BARRIER2 size now %d\n", ((size_t*)&vk_cmd_queue_type_sizes)[180]
  continue
end
run
bt 12
x/2i $pc
