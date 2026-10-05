#!/bin/bash
# Build a boot image carrying device-files/payload/:
#     build-boot-payload.sh [BASE.img] [OUT.img] [kernel] [dtb]
#
# BASE is a halium-boot.img: either an earlier image of this port or a fresh
# `mka halium-boot` (upstream initramfs; initramfs-halium-scripts.patch is then
# applied to it here). ANDROID_ROOT points at the Halium tree (default
# halium/android next to device-files/).
#
# The boot image is the single source of truth for this port: the initramfs
# carries /halium-device/{STAMP,rootfs}, and scripts/halium's
# install_halium_device_payload() copies that tree into the Ubuntu rootfs on
# first boot after the STAMP changes. So shipping a change means rebuilding
# this image and flashing it.
#
# Kernel and dtb are taken unchanged from the existing image -- only the
# ramdisk is rebuilt -- so a payload change can never alter the kernel.
#
# Use GNU cpio, NOT mkbootfs: the initramfs has 215 hardlinked busybox applets
# and mkbootfs writes each one in full (39 MB of files became a 372 MB cpio).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Default base: release15, whose initramfs has both installer fixes (see
# RELEASE.md, TRAP 1 and TRAP 2). Never overwrite the base by default.
BASE=${1:-$ROOT/flash/halium-boot-release15.img}
OUT=${2:-$ROOT/flash/halium-boot-new.img}
# Optional 3rd/4th args: use a freshly built kernel/dtb instead of BASE's.
#
# WHY THIS EXISTS: the RAMDISK must always come from BASE, because this port's
# initramfs carries a patched scripts/halium containing
# install_halium_device_payload() -- the function that copies /halium-device/rootfs
# into the real rootfs on first boot. A stock AOSP-built halium-boot.img does NOT
# have it. Building from that image produces something that looks correct (the
# payload tree is present, the STAMP is right) but silently installs nothing, so
# a fresh device comes up with none of the port's fixes. That was nearly shipped
# on 2026-09-19; the symptom was the on-device STAMP never changing after a flash.
# So: kernel from the new build, ramdisk from the known-good port image.
NEWKERNEL=${3:-}
NEWDTB=${4:-}
ANDROID_ROOT=${ANDROID_ROOT:-$ROOT/halium/android}
MKBOOTIMG=$ANDROID_ROOT/system/tools/mkbootimg/mkbootimg.py
UNPACK=$ANDROID_ROOT/system/tools/mkbootimg/unpack_bootimg.py
[ -f "$BASE" ] || { echo "usage: $0 BASE.img [OUT.img] [kernel] [dtb]  (no $BASE)" >&2; exit 1; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

echo "== unpacking $BASE"
python3 "$UNPACK" --boot_img "$BASE" --out "$W/out" > "$W/unpack.txt"
CMDLINE=$(sed -n 's/^command line args: //p' "$W/unpack.txt")

echo "== extracting ramdisk"
mkdir -p "$W/rd"
( cd "$W/rd" && gzip -dc "$W/out/ramdisk" | cpio -idm --quiet )

# An upstream initramfs (a plain `mka halium-boot`) lacks the function that
# installs the payload: add it from the published patch.
if ! grep -q install_halium_device_payload "$W/rd/scripts/halium" 2>/dev/null; then
    echo "== applying initramfs-halium-scripts.patch to the upstream initramfs"
    patch -d "$W/rd" -p1 -s < "$ROOT/device-files/initramfs-halium-scripts.patch"
fi

echo "== refreshing /halium-device from device-files/payload"
rm -rf "$W/rd/halium-device/rootfs"
mkdir -p "$W/rd/halium-device/rootfs"
cp -a "$ROOT/device-files/payload/." "$W/rd/halium-device/rootfs/"

# The stamp is what makes first boot notice there is something new to install.
# Symlinks count too: a unit enabled or masked by a link alone must still
# trigger a reinstall.
STAMP=$(cd "$W/rd/halium-device/rootfs" && { find . -type f -exec md5sum {} +; \
        find . -type l -printf '%p -> %l\n'; } | LC_ALL=C sort | md5sum | cut -c1-16)
echo "$STAMP" > "$W/rd/halium-device/STAMP"
echo "$STAMP" > "$ROOT/device-files/payload-STAMP"
echo "   stamp $STAMP"

echo "== packing ramdisk"
( cd "$W/rd" && find . | LC_ALL=C sort | cpio -o -H newc --owner=0:0 --quiet ) \
    | gzip -9 > "$W/ramdisk.new"

echo "== building boot image"
# guard: refuse to build an image whose initramfs cannot install the payload
if ! grep -rq install_halium_device_payload "$W/rd/scripts/" 2>/dev/null; then
    echo "!! BASE initramfs has no install_halium_device_payload() in scripts/." >&2
    echo "!! The payload would never be installed on the device. Refusing." >&2
    exit 1
fi

KERNEL_IN="$W/out/kernel"
DTB_IN="$W/out/dtb"
if [ -n "$NEWKERNEL" ]; then
    echo "== using external kernel $NEWKERNEL"
    KERNEL_IN="$NEWKERNEL"
fi
if [ -n "$NEWDTB" ]; then
    echo "== using external dtb $NEWDTB"
    DTB_IN="$NEWDTB"
fi

# guard: refuse to pair a kernel with modules it will reject.
#
# The payload ships prebuilt modules (wlan.ko, xt_CHECKSUM.ko).  This kernel is
# built with CONFIG_MODVERSIONS, so a module loads only if every symbol CRC it
# recorded matches the kernel's -- vermagic alone proves nothing.  On 2026-09-20
# adding CONFIG_TIPC=y changed 147 of wlan.ko's CRCs while leaving vermagic
# identical; the image built and booted fine and the phone simply had no wifi,
# which, wifi being the only way in, is indistinguishable from a hung boot.
#
# When the kernel being packed is the one in the build tree we can check it
# exactly, against that tree's Module.symvers.  (A kernel taken unchanged from
# BASE is the one the payload modules were last shipped with, so there is
# nothing new to check.)
OUTK=$ANDROID_ROOT/out/target/product/instantnoodlep
SYMVERS=$OUTK/obj/KERNEL_OBJ/Module.symvers
if [ -f "$SYMVERS" ] && [ -f "$OUTK/kernel" ] \
   && [ "$(md5sum < "$KERNEL_IN")" = "$(md5sum < "$OUTK/kernel")" ]; then
    echo "== checking payload modules against this kernel's symbol CRCs"
    # CONFIG_MODULE_SIG_FORCE: an unsigned or foreign-signed module is refused
    # just as surely as one with the wrong CRCs, so check the signature too.
    SIGCHK=()
    if grep -q '^CONFIG_MODULE_SIG_FORCE=y' "$OUTK/obj/KERNEL_OBJ/.config" 2>/dev/null; then
        SIGCHK=(--cert "$OUTK/obj/KERNEL_OBJ/certs/signing_key.x509")
    fi
    if ! python3 "$ROOT/device-files/check-module-abi.py" "${SIGCHK[@]}" "$SYMVERS" \
            "$ROOT"/device-files/payload/usr/lib/halium/modules/*.ko; then
        echo "!! payload modules do not match this kernel. Copy the signed," >&2
        echo "!! already-stripped ones from" >&2
        echo "!!   $OUTK/obj/PACKAGING/kernel_modules_intermediates/lib/modules/*/kernel/" >&2
        echo "!! (NOT obj/KERNEL_OBJ/: those are unsigned; do not strip them" >&2
        echo "!! yourself: stripping removes the signature) and rebuild." >&2
        exit 1
    fi
elif [ -n "$NEWKERNEL" ]; then
    echo "!! external kernel given but no matching Module.symvers to check" >&2
    echo "!! the payload modules against. Refusing rather than guessing." >&2
    exit 1
fi

python3 "$MKBOOTIMG" \
    --kernel "$KERNEL_IN" \
    --ramdisk "$W/ramdisk.new" \
    --dtb "$DTB_IN" \
    --cmdline "$CMDLINE" \
    --base 0x00000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --tags_offset 0x00000100 \
    --dtb_offset 0x0000000001f00000 \
    --pagesize 4096 \
    --header_version 2 \
    --board "${BOOT_BOARD:-Z3PHYR}" \
    --output "$W/boot.new"

# boot_a is 96 MB (/dev/sde11). Refuse to produce something that cannot be flashed.
SIZE=$(stat -c%s "$W/boot.new")
LIMIT=$((96 * 1024 * 1024))
if [ "$SIZE" -gt "$LIMIT" ]; then
    echo "!! $SIZE bytes exceeds the 96 MB boot partition" >&2
    exit 1
fi

cp "$W/boot.new" "$OUT"
echo "== $OUT  $SIZE bytes ($((SIZE / 1024 / 1024)) MB of 96 MB)"
md5sum "$OUT"
