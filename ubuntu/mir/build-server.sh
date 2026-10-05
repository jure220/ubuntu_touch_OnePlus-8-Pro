#!/bin/bash
# Cross-builds libmir1server.so.53 from src/ (upstream Mir v1.8.3 + UBports'
# debian/patches = the phone's 1.8.3-0ubports1+...~gbp5e637d) plus
# patches-server/ (upstream thread-safety fixes for the input device hub,
# canonical/mir 645248d997 44faae8bc0 8a9ed5d4db 2a534ee5f9 e8b38c771c
# 1a8601a6a4, which never reached the 1.8 branch).
#
#   docker run --rm -v "$PWD:/b" mircross:1 bash /b/build-server.sh [stock]
set -euo pipefail
cd /b
J=$(nproc)
if [ ! -d work-server ]; then
    cp -a src work-server
    if [ "${1:-}" != stock ]; then
        for p in patches-server/*.patch; do patch -d work-server -p1 < "$p"; done
    fi
fi
T=/b/aarch64.cmake
cat > $T <<'TC'
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_FIND_ROOT_PATH /usr/aarch64-linux-gnu /usr)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_LIBRARY_ARCHITECTURE aarch64-linux-gnu)
TC
export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
export PKG_CONFIG_PATH=
mkdir -p work-server/build && cd work-server/build
[ -f CMakeCache.txt ] || cmake .. -DCMAKE_TOOLCHAIN_FILE=$T \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
    -DCMAKE_INSTALL_LIBEXECDIR=lib/aarch64-linux-gnu/mir \
    -DMIR_ENABLE_TESTS=OFF -DMIR_BUILD_INTERPROCESS_TESTS=OFF \
    -DMIR_FATAL_COMPILE_WARNINGS=OFF -DMIR_ENABLE_WLCS_TESTS=OFF \
    -DMIR_EGL_SUPPORTED=ON -DMIR_LINK_TIME_OPTIMIZATION=OFF -DMIR_USE_LD=ld \
    -DMIR_PLATFORM=mesa-kms \
    -DProtobuf_PROTOC_EXECUTABLE=/usr/bin/protoc -DCAPNP_EXECUTABLE=/usr/bin/capnp \
    > /b/cmake-server.log 2>&1 || { tail -40 /b/cmake-server.log; exit 1; }
make -j$J mir1server
ls -la lib/libmir1server.so*
