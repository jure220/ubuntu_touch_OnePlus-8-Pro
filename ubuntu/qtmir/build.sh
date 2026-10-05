#!/bin/bash
set -e
cd /build/qtmir-src
export DEBIAN_FRONTEND=noninteractive
export DEB_BUILD_OPTIONS="nocheck parallel=8"
echo "=== cross-building for arm64 (native compiler) ==="
dpkg-buildpackage -us -uc -b -aarm64 -j8 -d
echo "=== BUILD OK ==="
ls -la /build/*.deb
