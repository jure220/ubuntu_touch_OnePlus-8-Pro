#!/bin/sh
# Builds media-hub-server with patches/0001 (repowerd lock leak race) applied
# to the exact revision the phone's package was built from (3b69471, package
# 4.7~20260611100903.31~3b69471+ubports24.04.2), so the binary is a drop-in
# for /usr/bin/media-hub-server.  Run inside media-hub-build:24.04:
#
#   docker run --rm --platform linux/arm64 -v "$PWD:/build" media-hub-build:24.04 sh /build/build.sh
#
# -O1 for the same reason as build-biometryd/build.sh: gcc-13 can hit internal
# compiler errors at -O2 under qemu-aarch64 user emulation.  Version 5.0.0 is
# what debian/rules passes (debian/VERSION).
set -e
cd /build/src
git config --global --add safe.directory /build/src
git checkout -q -- .
git checkout -q 3b69471
git apply ../patches/0001-power-fix-repowerd-lock-leak-race.patch
rm -rf build && mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_CXX_FLAGS="-O1" -DCMAKE_C_FLAGS="-O1" \
         -DENABLE_TESTS=OFF -DENABLE_DOC=OFF \
         -DMEDIA_HUB_VERSION_MAJOR=5 -DMEDIA_HUB_VERSION_MINOR=0 -DMEDIA_HUB_VERSION_PATCH=0 \
         -DCMAKE_INSTALL_PREFIX=/usr
make -j"$(nproc)" media-hub-server
strip -o /build/media-hub-server src/service/media-hub-server
echo "=== built ==="
ls -la /build/media-hub-server
