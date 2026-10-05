# IR Camera — the OnePlus 8 Pro's colour-filter camera on Ubuntu Touch

The phone has five rear-facing sensors. Four are reachable from the normal
camera app; the fifth — the 5 MP colour-filter ("photochrom") GC5035, **camera
id 4** — is not, because it does not advertise `BACKWARD_COMPATIBLE` and Ubuntu
Touch's camera stack speaks Android's Camera **API1**, which can only open
cameras that do.

This is a Camera2 client that can — a click package with a live viewfinder, plus
a command-line tool (`ircam-shot`) for enumeration and scripted captures.

It needs the [Ubuntu Touch port for the OnePlus 8 Pro](https://github.com/jure220/ubuntu_touch_OnePlus-8-Pro)
(see "Prerequisite on the device" below). Pictures are saved to `~/Pictures`.

## Install

Download from the release page either

* `ircam.z3phyr_<version>_arm64.click` and install it on the phone, in the
  Terminal app:

      pkcon install-local --allow-untrusted ~/Downloads/ircam.z3phyr_1.0.0_arm64.click

  or from a PC over USB (Developer Mode on):

      adb push ircam.z3phyr_1.0.0_arm64.click /home/phablet/
      adb shell pkcon install-local --allow-untrusted /home/phablet/ircam.z3phyr_1.0.0_arm64.click

* or `ircam-z3phyr-<version>-flashable.zip` and flash it in recovery
  (OrangeFox) after the Ubuntu Touch zip. Recovery cannot run Ubuntu Touch's
  click tool, so the zip stages the package on userdata with a one-shot
  systemd unit (`flashable/ircam-install.service`); on the next boot that unit
  runs `click install` and removes itself.

The app is unconfined (`ircam.apparmor`): it talks to Android's camera service
over binder through libhybris, which no AppArmor policy group allows.

Uninstall: `click unregister --user=phablet ircam.z3phyr`.

## Build

    ./build-click.sh     # -> dist/ircam.z3phyr_<version>_arm64.click,
                         #    dist/ircam-z3phyr-<version>-flashable.zip

Everything runs in containers built from `docker/`; nothing is installed on the
host. The QML plugin is compiled natively in an arm64 container, so the host
needs qemu-user binfmt registered (for example
`docker run --rm --privileged multiarch/qemu-user-static -p yes`).

## How it reaches Android

`libcamera2ndk.so` is a bionic (Android) library; a glibc program cannot link
it. So nothing Android is linked at build time at all:

```
glibc dlopen  ->  libhybris-common.so.1
                    android_dlopen  ->  libcamera2ndk.so    (Camera2 NDK)
                                        libmediandk.so      (AImageReader)
                                        libbinder_ndk.so    (binder threadpool)
```

Every Android entry point is a function pointer bound by `android_dlsym`, listed
once in `src/hybris_ndk.h` so a typo fails loudly at startup naming the symbol.

Two things are easy to get wrong here and cost a lot of time:

* **You must start a binder threadpool.** CameraService calls *back* into this
  process — the capture buffers live in a BufferQueue we own. With no listener
  threads those transactions are never answered, and the symptom is not an error
  but silence: streams configure, the sensor powers up, and no frame ever
  arrives (`Camera3-Stream: startConfiguration: Cannot query consumer endpoint
  usage!`). Android apps get the threadpool free from the ART runtime.
* **`/apex/com.android.i18n/lib64` must be on the hybris path.** libcamera2ndk
  pulls in libandroid_runtime, whose dependency closure needs `libicu.so`, and
  bionic's default search path is only `/system/lib64`, `/odm/lib64`,
  `/vendor/lib64` — apex directories are not on it.

## The app

    click/qml/Main.qml   Lomiri UI: viewfinder, shutter, camera picker, exposure
    plugin/              libircamplugin.so, the QML module "IRCam 1.0"
    src/                 shared C: hybris loader, stream selection, image writers

Frames travel camera thread → QImage → queued signal → scene-graph texture, so
there is no file round-trip; the only per-frame CPU work is the YUV→RGB pass.

The colour-filter sensor has no hardware auto-exposure (no `BACKWARD_COMPATIBLE`
means no 3A), so the app always drives `SENSOR_EXPOSURE_TIME` /
`SENSOR_SENSITIVITY` itself. By default it runs **software auto**: it meters
preview brightness and nudges exposure/ISO toward a mid-grey target, pushing
updates into the live repeating request (no session restart). Manual mode keeps
the sliders; Apply calls `applySettings()` which does the same live update —
never `stop()`/`start()`, which used to freeze the UI.

The desktop file locks the app to portrait (`X-Ubuntu-Supported-Orientations`).

Three containers do the building: `ircam-build:24.04` cross-compiles the C tool,
`ircam-qt:24.04` is an **arm64** image run under emulation so the plugin links
against exactly the Qt 5.15.13 the phone has, and `ircam-click:24.04` carries
UBports' `click` tool, which packs the tree.

## Headers

`ndk/` holds verbatim copies of the AOSP headers, refreshed by
`./sync-ndk-headers.sh` from `halium/android`, so struct layouts and enum values
match the `.so` files on the device exactly rather than being retyped. `ndk/compat/`
adds four one-line stubs for headers the camera ones include but never really
use (`jni.h`, `android/native_window.h`, `android/hardware_buffer.h`,
`cutils/native_handle.h`) and neutralises bionic's `__INTRODUCED_IN`.

## Command-line tool

`ircam-shot` is inside the click (`/opt/click.ubuntu.com/ircam.z3phyr/current/bin/`):

```sh
export HYBRIS_LD_LIBRARY_PATH=/system/lib64:/vendor/lib64:/odm/lib64:/apex/com.android.i18n/lib64
ircam-shot --list                                     # enumerate
ircam-shot --id 4 --format jpeg --exposure-ms 200 --iso 1600
```

Options: `--id N`, `--out DIR` (default `$HOME/Pictures`), `--format
jpeg|yuv|raw16`, `--size WxH`, `--frames N`, `--timeout S`, `--iso N`,
`--exposure-ms M`, `--auto`, `--list`.

Camera 4 has no auto-exposure to lean on (no `BACKWARD_COMPATIBLE`, so no 3A),
so the program drives the sensor manually by default on such cameras. Its limits
are ISO 100–1600 and 66.7 µs – 199.7 ms; there is **no flash** on this sensor.

A JPEG-only session is a trap: Qualcomm's CHI layer then selects
`UsecaseJPEGEncodeSnapshot` / `JPEGEncodeSnapshotOnly` with `Realtime
SelectedMode W=0, H=0, FPS:0` — a stills pipeline with no live path. Prefer a
preview-sized YUV stream (and add a JPEG stream alongside it for stills), which
is what real camera apps configure.

## Output formats

JPEG comes straight from the HAL's encoder and is written as-is. YUV_420_888 is
converted to RGB and written as PNG, and RAW16 as 16-bit PGM — both by
`src/imgwrite.c`, which has no dependencies: PNG permits deflate streams built
entirely from "stored" blocks, so a valid file needs only CRC-32 and Adler-32.
The files are larger than they need to be, but nothing is lost and there is no
libpng/libjpeg to cross-compile and keep in sync.

## Prerequisite on the device

Camera2 is refused for **every** camera unless the system image carries the
port's `CameraServiceProxyWrapper::isCameraDisabled()` fix (in
`android-patches/frameworks_av.patch` of the port's repository). Without it every open returns `ERROR_CAMERA_DISABLED`.
Set `persist.halium.camera.strict_device_policy=1` to restore stock AOSP
behaviour (and lose Camera2).
