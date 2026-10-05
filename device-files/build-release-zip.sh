#!/bin/bash
# Assemble the recovery-flashable release zip from pinned inputs, then verify
# every member by streaming it back OUT of the finished archive (RELEASE.md
# TRAP 3: never trust the inputs you believe you put in).
#
#   device-files/build-release-zip.sh <halium-boot.img> <rootfs.tar.gz> <rootfs-sha256> \
#                                     <android-rootfs.img.gz> <out.zip>
#
# <rootfs-sha256> is the sha256 of the pinned UPSTREAM artifact.  The rootfs is
# shipped unmodified, so byte-identity with upstream is what proves it carries
# no personal data (it does contain stock skeleton files such as an empty
# /etc/machine-id and /home/phablet/.bashrc; those are UBports', not ours).
#
# META-INF/ and README.txt come from device-files/release/.  Images are STORED
# (they are already compressed); the installer streams them with unzip -p.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BOOT=$1 ROOTFS=$2 ROOTFS_SHA=$3 ANDROID=$4 OUT=$5
REL=$ROOT/device-files/release
for f in "$BOOT" "$ROOTFS" "$ANDROID" "$REL/README.txt" "$REL/port-owned-etc.list" \
         "$REL/META-INF/com/google/android/update-binary" \
         "$REL/META-INF/com/google/android/updater-script"; do
    [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done
gzip -t "$ROOTFS" && gzip -t "$ANDROID"
[ "$(sha256sum < "$ROOTFS" | cut -d' ' -f1)" = "$ROOTFS_SHA" ] \
    || { echo "!! $ROOTFS is not the pinned upstream artifact" >&2; exit 1; }
sh -n "$REL/META-INF/com/google/android/update-binary"
# Every /etc path the payload ships must be on the installer's clean-up list,
# or an install over an earlier release keeps the stale copy (update-binary 5b).
_miss=$(cd "$ROOT/device-files/payload" && find etc \( -type f -o -type l \) | LC_ALL=C sort \
        | LC_ALL=C comm -23 - <(LC_ALL=C sort "$REL/port-owned-etc.list"))
[ -z "$_miss" ] || { echo "!! add to release/port-owned-etc.list:" >&2; echo "$_miss" >&2; exit 1; }

rm -f "$OUT.tmp"
python3 - "$OUT.tmp" "$REL" "$BOOT" "$ANDROID" "$ROOTFS" <<'PY'
import sys, zipfile, os
out, rel, boot, android, rootfs = sys.argv[1:]
with zipfile.ZipFile(out, "w", allowZip64=True) as z:
    def add(src, name, comp, mode):
        zi = zipfile.ZipInfo.from_file(src, name)
        zi.compress_type = comp
        zi.external_attr = (0o100000 | mode) << 16
        with open(src, "rb") as f, z.open(zi, "w", force_zip64=True) as w:
            while True:
                b = f.read(1 << 20)
                if not b: break
                w.write(b)
    D = zipfile.ZIP_DEFLATED; S = zipfile.ZIP_STORED
    add(os.path.join(rel, "META-INF/com/google/android/update-binary"),
        "META-INF/com/google/android/update-binary", D, 0o755)
    add(os.path.join(rel, "META-INF/com/google/android/updater-script"),
        "META-INF/com/google/android/updater-script", D, 0o644)
    add(os.path.join(rel, "README.txt"), "README.txt", D, 0o644)
    add(os.path.join(rel, "port-owned-etc.list"), "port-owned-etc.list", D, 0o644)
    add(boot, "images/halium-boot.img", S, 0o644)
    add(android, "images/android-rootfs.img.gz", S, 0o644)
    add(rootfs, "images/ubuntu-touch-rootfs.tar.gz", S, 0o644)
PY
mv "$OUT.tmp" "$OUT"

echo "== verifying members against the archive itself"
chk() {  # <member> <source>
    local a b
    a=$(unzip -p "$OUT" "$1" | sha256sum | cut -d' ' -f1)
    b=$(sha256sum < "$2" | cut -d' ' -f1)
    [ "$a" = "$b" ] && echo "   ok  $1  $a" || { echo "!! MISMATCH $1" >&2; exit 1; }
}
chk META-INF/com/google/android/update-binary "$REL/META-INF/com/google/android/update-binary"
chk README.txt "$REL/README.txt"
chk port-owned-etc.list "$REL/port-owned-etc.list"
chk images/halium-boot.img "$BOOT"
chk images/android-rootfs.img.gz "$ANDROID"
chk images/ubuntu-touch-rootfs.tar.gz "$ROOTFS"

echo "== rootfs member is the pinned upstream artifact, and carries no secrets"
[ "$(unzip -p "$OUT" images/ubuntu-touch-rootfs.tar.gz | sha256sum | cut -d' ' -f1)" = "$ROOTFS_SHA" ] \
    || { echo "!! rootfs member differs from upstream" >&2; exit 1; }
if unzip -p "$OUT" images/ubuntu-touch-rootfs.tar.gz | tar tzvf - \
     | grep -E '\./root/\.ssh/.|\.bash_history$|ssh_host_|system-connections/.|authorized_keys' \
     || unzip -p "$OUT" images/ubuntu-touch-rootfs.tar.gz | tar tzvf - \
        | awk '$6=="./etc/machine-id" && $3!=0' | grep .; then
    echo "!! secrets found in rootfs" >&2; exit 1
fi
echo "   upstream sha256 matches, no keys/credentials/machine-id"
sha256sum "$OUT" | tee "$OUT.sha256"
ls -la "$OUT"
