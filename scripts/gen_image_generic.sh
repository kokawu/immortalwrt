#!/bin/sh
# Copyright (C) 2006-2012 OpenWrt.org
set -e -x

if [ $# -ne 5 ] && [ $# -ne  6 ]; then
    echo "SYNTAX: $0 <file> <kernel size> <kernel directory> <rootfs size> <rootfs image> [<align>]"
    exit 1
fi

OUTPUT="$1"
KERNELSIZE="$2"
KERNELDIR="$3"
KERNELPARTTYPE=${KERNELPARTTYPE:-83}
ROOTFSSIZE="$4"
ROOTFSIMAGE="$5"
ROOTFSPARTTYPE=${ROOTFSPARTTYPE:-83}
ALIGN="$6"

rm -f "$OUTPUT"

head=16
sect=63

# create partition table
# When building a GPT disk (GUID set), add a small BIOS Boot partition (type 0xEF02)
# before kernel/rootfs to support GRUB BIOS embedding on GPT. This preserves UEFI
# boot and enables legacy BIOS boot without changing higher-level configs.
if [ -n "$GUID" ]; then
    # Upstream GPT layout: [kernel KERNELSIZE] [rootfs ROOTFSSIZE]
    set $(ptgen -o "$OUTPUT" -h $head -s $sect -g \
        -t "${KERNELPARTTYPE}" -p "${KERNELSIZE}m${PARTOFFSET:+@$PARTOFFSET}" \
        -t "${ROOTFSPARTTYPE}" -p "${ROOTFSSIZE}m" \
        ${ALIGN:+-l $ALIGN} ${SIGNATURE:+-S 0x$SIGNATURE} -G $GUID)
    # Convert byte offsets to 512-byte sectors for dd seek/count usage
    KERNELOFFSET="$(($1 / 512))"
    KERNELSIZE="$2"
    ROOTFSOFFSET="$(($3 / 512))"
    # IMPORTANT: ROOTFSSIZE is used as a sector count when padding with dd
    # (bs=512). Convert bytes -> sectors to avoid oversized writes.
    ROOTFSSIZE="$(($4 / 512))"
else
    set $(ptgen -o "$OUTPUT" -h $head -s $sect \
        -t "${KERNELPARTTYPE}" -p "${KERNELSIZE}m${PARTOFFSET:+@$PARTOFFSET}" \
        -t "${ROOTFSPARTTYPE}" -p "${ROOTFSSIZE}m" \
        ${ALIGN:+-l $ALIGN} ${SIGNATURE:+-S 0x$SIGNATURE})
    KERNELOFFSET="$(($1 / 512))"
    KERNELSIZE="$2"
    ROOTFSOFFSET="$(($3 / 512))"
    ROOTFSSIZE="$(($4 / 512))"
fi

# Using mcopy -s ... is using READDIR(3) to iterate through the directory
# entries, hence they end up in the FAT filesystem in traversal order which
# breaks reproducibility.
# Implement recursive copy with reproducible order.
dos_dircopy() {
  local entry
  local baseentry
  for entry in "$1"/* ; do
    if [ -f "$entry" ]; then
      mcopy -i "$OUTPUT.kernel" "$entry" ::"$2"
    elif [ -d "$entry" ]; then
      baseentry="$(basename "$entry")"
      mmd -i "$OUTPUT.kernel" ::"$2""$baseentry"
      dos_dircopy "$entry" "$2""$baseentry"/
    fi
  done
}

[ -n "$PADDING" ] && dd if=/dev/zero of="$OUTPUT" bs=512 seek="$ROOTFSOFFSET" conv=notrunc count="$ROOTFSSIZE"
dd if="$ROOTFSIMAGE" of="$OUTPUT" bs=512 seek="$ROOTFSOFFSET" conv=notrunc

if [ -n "$GUID" ]; then
    [ -n "$PADDING" ] && dd if=/dev/zero of="$OUTPUT" bs=512 seek="$((ROOTFSOFFSET + ROOTFSSIZE))" conv=notrunc count="$sect"
    mkfs.fat --invariant -n kernel -C "$OUTPUT.kernel" -S 512 "$((KERNELSIZE / 1024))"
    LC_ALL=C dos_dircopy "$KERNELDIR" /
else
    make_ext4fs -J -L kernel -l "$KERNELSIZE" ${SOURCE_DATE_EPOCH:+-T ${SOURCE_DATE_EPOCH}} "$OUTPUT.kernel" "$KERNELDIR"
fi
dd if="$OUTPUT.kernel" of="$OUTPUT" bs=512 seek="$KERNELOFFSET" conv=notrunc
rm -f "$OUTPUT.kernel"

