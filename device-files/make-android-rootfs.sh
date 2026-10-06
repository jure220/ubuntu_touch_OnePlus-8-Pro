#!/bin/bash
# Turn the build's system.img into the zip's images/android-rootfs.img.gz:
#     make-android-rootfs.sh out/target/product/<device>/system.img android-rootfs.img.gz
# Runs anywhere with simg2img and e2fsprogs (the halium-build:14 image has both).
#
#  1. sparse -> raw ext4 (the phone loop-mounts it from userdata);
#  2. shrink to 600 MB (the build pads the image to the system partition size);
#  3. replace the empty /system_ext and /product directories with symlinks to
#     /system/system_ext and /system/product. AOSP creates those compat links
#     only when it builds separate partition images; this port merges both
#     into system (BoardConfig.mk), and without the links Android init never
#     finds /system_ext/etc/init, so hwservicemanager does not start and the
#     display HALs never register.
# No root and no loop mount: the edits are made with debugfs.
set -euo pipefail
IN=$1 OUT=$2
SIZE=${ANDROID_ROOTFS_SIZE:-600M}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
RAW=$W/android-rootfs.img

if [ "$(head -c 4 "$IN" | od -An -tx1 | tr -d ' ')" = "3aff26ed" ]; then
    simg2img "$IN" "$RAW"
else
    cp "$IN" "$RAW"
fi
e2fsck -fy "$RAW" >/dev/null || [ $? -le 1 ]
resize2fs "$RAW" "$SIZE" >/dev/null

debugfs -w -f - "$RAW" >/dev/null 2>"$W/debugfs.err" <<'EOF'
rmdir /system_ext
rmdir /product
symlink /system_ext /system/system_ext
symlink /product /system/product
EOF
for l in system_ext product; do
    t=$(debugfs -R "stat /$l" "$RAW" 2>/dev/null | sed -n 's/^Fast link dest: "\(.*\)"$/\1/p')
    [ "$t" = "/system/$l" ] || { cat "$W/debugfs.err" >&2; echo "!! /$l is not a link to /system/$l" >&2; exit 1; }
done
debugfs -R "stat /system/system_ext/bin/hwservicemanager" "$RAW" 2>/dev/null | grep -q "Type: regular" \
    || { echo "!! no /system/system_ext/bin/hwservicemanager in the image" >&2; exit 1; }
e2fsck -fn "$RAW" >/dev/null

gzip -9 -n -c "$RAW" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "$OUT: $(stat -c %s "$RAW") bytes raw, $(stat -c %s "$OUT") gzipped"
