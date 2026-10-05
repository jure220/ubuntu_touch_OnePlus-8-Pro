#!/bin/bash
# Cross-builds Mir 1.8.3's evdev input plugin (input-evdev.so.7) -- only that
# module, the way src/platforms/evdev/CMakeLists.txt does -- from src/ (upstream
# v1.8.3 + UBports' debian/patches, the revision of the phone's libmir1server53
# package 1.8.3-0ubports1+...~gbp5e637d) plus patches/*.patch if requested.
# Run inside qtmircross:6 (arm64 cross toolchain + libmir1*/libinput dev):
#
#   docker run --rm -v "$PWD:/b" qtmircross:6 bash /b/build.sh [stock]
set -euo pipefail
cd /b
rm -rf work out && mkdir -p out && cp -a src work
if [ "${1:-}" != stock ]; then
    for p in patches-evdev/*.patch; do patch -d work -p1 < "$p"; done
fi
S=work
sed 's/@MIR_SERVER_INPUT_PLATFORM_VERSION@/MIR_INPUT_PLATFORM_0.27/' \
    $S/src/platforms/input_platform_symbols.map.in > out/input_platform_symbols.map
CXX=aarch64-linux-gnu-g++
INC=""
for d in include/platform include/common include/core include/client include/server \
         src/include/platform src/include/common src/include/server; do INC="$INC -I$S/$d"; done
CXXFLAGS="-O2 -g -pthread -std=c++17 -fPIC -fno-strict-aliasing -Wall -Wno-psabi \
  -DMIR_VERSION_MAJOR=1 -DMIR_VERSION_MINOR=8 -DMIR_VERSION_MICRO=2 \
  -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -DLOG_NDEBUG=1 -DMIR_LIBINPUT_HAS_ACCEL_PROFILE=1 \
  $(aarch64-linux-gnu-pkg-config --cflags libinput 2>/dev/null || pkg-config --cflags libinput)"
OBJS=""
for f in evdev_device_detection button_utils libinput_device libinput_device_ptr \
         libinput_ptr platform fd_store platform_factory; do
    $CXX $CXXFLAGS $INC -c $S/src/platforms/evdev/$f.cpp -o out/$f.o
    OBJS="$OBJS out/$f.o"
done
$CXX -shared -o out/input-evdev.so.7 $OBJS \
    -Wl,--exclude-libs=ALL -Wl,--version-script,out/input_platform_symbols.map \
    -L/usr/lib/aarch64-linux-gnu -lmir1platform -lmir1common -lmir1core \
    -lboost_program_options -linput -ludev -pthread
aarch64-linux-gnu-strip --remove-section=.comment --remove-section=.note --strip-unneeded \
    -o out/input-evdev.so.7.stripped out/input-evdev.so.7
ls -la out/input-evdev.so.7*
