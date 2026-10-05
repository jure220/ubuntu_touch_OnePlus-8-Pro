#!/bin/bash
# Build the stub INetd HIDL service (device-files/netd-stub) inside the Halium
# tree and copy the binary into the boot payload.  Run from the project root;
# uses the halium-build:14 Docker image like every other Android-side build.
#
# The source of truth is device-files/netd-stub/.  It is copied into the tree
# at vendor/halium/netd-stub because Soong only sees Android.bp files there.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TREE=$ROOT/halium/android
NAME=android.system.net.netd@1.1-service.stub
DEST=$ROOT/device-files/payload/usr/lib/halium/netd-stub

rm -rf "$TREE/vendor/halium/netd-stub"
cp -r "$ROOT/device-files/netd-stub" "$TREE/vendor/halium/netd-stub"

docker run --rm -v "$ROOT:/work" -v "$ROOT/.containerhome:/home/build" \
    -e HOME=/home/build -e ALLOW_MISSING_DEPENDENCIES=true \
    -e UNSAFE_DISABLE_HIDDENAPI_FLAGS=true halium-build:14 bash -lc "
    cd /work/halium/android && source build/envsetup.sh >/dev/null 2>&1
    lunch lineage_instantnoodlep-ap2a-userdebug >/dev/null 2>&1 || exit 1
    m $NAME"

OUT=$TREE/out/target/product/instantnoodlep/vendor/bin/hw/$NAME
mkdir -p "$DEST"
cp "$OUT" "$DEST/$NAME"
cp "$ROOT/device-files/netd-stub/$NAME.rc" "$DEST/$NAME.rc"
ls -la "$DEST"
