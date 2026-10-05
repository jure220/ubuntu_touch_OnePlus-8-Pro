#!/bin/bash
# Cross-builds graphics-android2.so.16 from android2/src (UBports
# mir-android2-platform 72f96d2 = the phone's
# mir1-platform-graphics-android2-16 1.8.0~20260320103600.20~72f96d2) with
# android2/0001-apply-initial-display-configuration-policy.patch applied.
#
#   docker run --rm -v "$PWD:/b" android2cross:1 bash /b/build-android2.sh
set -euo pipefail
cd /b/android2/src
# android-headers-28 is arch:all and ships its .pc in /usr/lib/pkgconfig
export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig:/usr/lib/pkgconfig
export PKG_CONFIG_PATH=
mkdir -p build && cd build
[ -f CMakeCache.txt ] || cmake .. -DCMAKE_TOOLCHAIN_FILE=/b/aarch64.cmake \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
    -DCMAKE_INSTALL_LIBEXECDIR=lib/aarch64-linux-gnu/mir1 \
    -DMIR_ENABLE_TESTS=OFF -DMIR_LINK_TIME_OPTIMIZATION=OFF \
    > /b/cmake-android2.log 2>&1 || { tail -40 /b/cmake-android2.log; exit 1; }
make -j$(nproc) mirplatformgraphicsandroid
F=$(find . -name "graphics-android2.so*" -type f | head -1)
aarch64-linux-gnu-strip --remove-section=.comment --remove-section=.note --strip-unneeded -o /b/graphics-android2.so.16.patched $F
ls -la $F /b/graphics-android2.so.16.patched
