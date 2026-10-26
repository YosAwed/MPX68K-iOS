#!/bin/sh -e
# Cross-assemble cyberstick.s and pack it into a bootable XDF image.
# Needs GNU binutils for m68k, e.g. on Debian/Ubuntu:
#   apt-get install binutils-m68k-linux-gnu
# Override the tool prefix with PREFIX=... for other toolchains.
cd "$(dirname "$0")"
PREFIX=${PREFIX:-m68k-linux-gnu-}

"${PREFIX}as" -m68000 -o cyberstick.o cyberstick.s
"${PREFIX}ld" -e 0 -Ttext=0 -o cyberstick.elf cyberstick.o
"${PREFIX}objcopy" -O binary cyberstick.elf cyberstick.bin

size=$(wc -c < cyberstick.bin)
if [ "$size" -gt 1024 ]; then
    echo "error: boot code is $size bytes; the ROM IPL only loads 1024" >&2
    exit 1
fi

# XDF = raw 2HD dump: 77 cylinders x 2 heads x 8 sectors x 1024 bytes
rm -f cyberstick.xdf
dd if=/dev/zero of=cyberstick.xdf bs=1024 count=1232 status=none
dd if=cyberstick.bin of=cyberstick.xdf conv=notrunc status=none
echo "cyberstick.xdf ready ($size bytes of boot code)"
