#
# Builds omap5-ipu-fw.xem4, the test firmware for the Pyra's two Cortex-M4s.
#
# SPDX-License-Identifier: BSD-3-Clause
#
#   make                 build it
#   make info            show what was built
#   make clean
#
# The toolchain is plain arm-none-eabi-gcc. TI's own route -- XDCtools,
# SYS/BIOS, IPC and the TI CGT ARM compiler -- is about a gigabyte of
# downloads behind a login and produces a MessageQ/rpmsg firmware; it is the
# right answer once there is something to communicate, and the wrong one for
# finding out whether the kernel half works at all.
#
# .xem4 is TI's extension for an M4 image and is what the device tree's
# firmware-name asks for. It is an ordinary ELF.
#
# --no-warn-rwx-segments: there is one segment and it is the whole carveout.
# The M4 has no MMU of its own to enforce page permissions with, and the
# IOMMU entry the kernel builds from the resource table carries flags=0
# like TI's own tables do, so a W^X split would buy nothing here.
#
CROSS   ?= arm-none-eabi-
CC      = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy
READELF = $(CROSS)readelf
SIZE    = $(CROSS)size

TARGET  = omap5-ipu-fw.xem4
OBJS    = start.o main.o resource_table.o

# -fno-pie: the loader wants ET_EXEC with fixed addresses, and a PIE would
#   also pull in relocation machinery nothing here would run.
# -fno-builtin: no libc, so gcc must not turn a loop into a memset() call.
# -fno-common: two cores sharing tentative definitions is not worth finding
#   out about the hard way.
CFLAGS  = -mcpu=cortex-m4 -mthumb -mfloat-abi=soft \
	  -ffreestanding -fno-builtin -fno-pie -fno-common \
	  -Os -g -std=gnu99 \
	  -Wall -Wextra -Werror

LDFLAGS = -mcpu=cortex-m4 -mthumb -mfloat-abi=soft \
	  -nostdlib -nostartfiles -static -T m4.ld \
	  -Wl,-Map=$(TARGET).map -Wl,--build-id=none \
	  -Wl,--no-warn-rwx-segments

all: $(TARGET)

$(TARGET): $(OBJS) m4.ld
	$(CC) $(LDFLAGS) -o $@ $(OBJS)
	@$(SIZE) $@

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.S
	$(CC) $(CFLAGS) -c -o $@ $<

info: $(TARGET)
	@echo "== header =="
	@$(READELF) -h $(TARGET) | grep -E 'Class|Data|Type|Machine|Entry'
	@echo "== segments =="
	@$(READELF) -l $(TARGET) | grep -E 'LOAD|Type.*Offset'
	@echo "== sections =="
	@$(READELF) -S $(TARGET) | grep -E 'resource_table|\.bss|\.text|\.data|\.vectors'
	@echo "== reset vector =="
	@$(OBJCOPY) -O binary --only-section=.vectors $(TARGET) /dev/stdout | od -An -tx4 -N8
	@echo "== resource table =="
	@$(OBJCOPY) -O binary --only-section=.resource_table $(TARGET) /dev/stdout | od -An -tx4

clean:
	rm -f $(OBJS) $(TARGET) $(TARGET).map

.PHONY: all info clean
