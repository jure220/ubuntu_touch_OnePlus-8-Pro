#!/bin/bash
# Copy the Camera2/NDK headers out of the AOSP tree this device's system image
# was built from, so the app is compiled against exactly the struct layouts and
# enum values its libcamera2ndk.so exports. Re-run if the tree is updated.
set -e
cd "$(dirname "$0")"
T=../../halium/android
cp -v $T/frameworks/av/camera/ndk/include/camera/*.h              ndk/camera/
cp -v $T/frameworks/av/media/ndk/include/media/NdkImage.h         ndk/media/
cp -v $T/frameworks/av/media/ndk/include/media/NdkImageReader.h   ndk/media/
cp -v $T/frameworks/av/media/ndk/include/media/NdkMediaError.h    ndk/media/
