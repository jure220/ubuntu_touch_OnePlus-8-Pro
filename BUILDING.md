# Building

The release zip is three images:

| Image | Made from |
|---|---|
| `ubuntu-touch-rootfs.tar.gz` | the stock UBports 24.04-2.x rootfs, unmodified (CI build #104, sha256 `eb7ec756...3e637773`) |
| `android-rootfs.img.gz` | the Halium 14 Android tree below, `mka systemimage`, then `device-files/make-android-rootfs.sh` |
| `halium-boot.img` | kernel + dtb from the Halium tree, ramdisk = Halium's initramfs + `device-files/initramfs-halium-scripts.patch` + `device-files/payload/` |

Everything runs in Docker; nothing needs to be installed on the host apart from
Docker, `repo` and `git`. Building Mir, qtmir and Qt Quick for arm64 uses a
native cross compiler. media-hub builds under qemu-user, so it needs
qemu-user-static with binfmt registered.

## 1. Android tree, kernel and system image

`manifests/pinned-v1.0.xml` is the exact tree v1.0 was built from: all 1280
projects pinned to the commits that were synced, with the kernel and the device
tree taken from the port's forks (branch `lineage-21-ubuntu-touch`):

- https://github.com/jure220/android_kernel_oneplus_sm8250
- https://github.com/jure220/android_device_oneplus_instantnoodlep

```sh
mkdir -p halium/android && cd halium/android
repo init --standalone-manifest --git-lfs \
    -u https://raw.githubusercontent.com/jure220/ubuntu_touch_OnePlus-8-Pro/main/manifests/pinned-v1.0.xml
repo sync -c -j8
hybris-patches/apply-patches.sh --mb
for f in <this repo>/android-patches/*.patch; do
    git -C "$(sed -n '1s/^# //p' "$f")" apply "$f"
done
```

(`-u file:///path/to/pinned-v1.0.xml` works as well. To follow the moving
branches instead, `repo init -u https://github.com/Halium/android -b
halium-14.0` and copy `manifests/{instantnoodlep,qcom-sm8250,lineage-extras}.xml`
to `.repo/local_manifests/`; Halium's hybris-patches have moved since v1.0, so
the patches below may then need rebasing.)

`android-patches/` holds the port's changes to projects that are not forked.
Each file names its project and the commit it applies to, which is the
project's revision with Halium's hybris-patches applied.

| Patch | What it changes |
|---|---|
| `halium_halium-boot` | boot header v2: embed the dtb; call `$(MKBOOTIMG)` (Android 14 removes host tools from PATH) |
| `build_soong` | no ThinLTO for Rust staticlibs (rustc and clang disagree on LLVM 17 bitcode) |
| `system_core`, `system_apex`, `system_vold` | no `reboot_on_failure`: inside the container these checks rebooted the whole phone |
| `frameworks_av` | camera service and AudioSystem fixes for running under libhybris |
| `vendor_halium_droidmedia`, `vendor_halium_libhybris` | camera recording, and the hwc2 compat layer reporting a second display as primary |

Build:

```sh
docker build -t halium-build:14 --build-arg UID=$(id -u) -f <this repo>/docker/halium-build.Dockerfile <this repo>/docker
docker run --rm -v "$PWD/../..:/work" -e ALLOW_MISSING_DEPENDENCIES=true \
    -e UNSAFE_DISABLE_HIDDENAPI_FLAGS=true halium-build:14 bash -lc '
    cd /work/halium/android && source build/envsetup.sh &&
    lunch lineage_instantnoodlep-ap2a-userdebug &&
    mka systemimage halium-boot vendorimage -j$(nproc)'
```

- `android-rootfs.img.gz`: `device-files/make-android-rootfs.sh
  out/target/product/instantnoodlep/system.img android-rootfs.img.gz` (raw
  ext4, 600 MB, `/system_ext` and `/product` replaced by links into `/system`;
  without the links Android init does not find system_ext's services). Run it
  in the halium-build image, which has simg2img and e2fsprogs.
- `halium-boot.img` is the base for the boot image in step 3.
- The vendor image is not used. Building it produces the signed, stripped
  kernel modules under
  `obj/PACKAGING/depmod_vendor_intermediates/lib/modules/0.0/vendor/lib/modules/`
  (`wlan.ko`, `xt_CHECKSUM.ko`, shipped in `device-files/payload/usr/lib/halium/modules/`).

## 2. Ubuntu-side components

Five binaries in the payload are rebuilt from Ubuntu Touch packages. Each is a
drop-in for the library in the 24.04-2.x rootfs, built from that package's
exact source plus a patch.

| Binary | Source | Patch |
|---|---|---|
| `libmir1server.so.53`, `mir1/server-platform/input-evdev.so.7` | [Mir v1.8.3](https://github.com/canonical/mir/releases/tag/v1.8.3) + `debian/` from [packaging/mir1](https://gitlab.com/ubports/development/core/packaging/mir1) `5e637dbb`, its `debian/patches/series` applied | `ubuntu/mir/patches-server/*` (upstream Mir commits, thread safety of the input device hub), `ubuntu/mir/patches-evdev/*` |
| `mir1/server-platform/graphics-android2.so.16` | [mir-android2-platform](https://gitlab.com/ubports/development/core/hybris-support/mir-android2-platform) `72f96d2f` | `ubuntu/mir-android2-platform/0001-*` |
| `libqt5mir1server.so.1` | [qtmir](https://gitlab.com/ubports/development/core/qtmir) `418ba723` | `ubuntu/qtmir/0001-*` |
| `libQt5Quick.so.5.15.13` | Ubuntu `qtdeclarative-opensource-src-gles` 5.15.13+dfsg-2 | `ubuntu/qtdeclarative/null-check-sciReply.patch` |
| `/usr/lib/halium/media-hub-server` | [media-hub](https://gitlab.com/ubports/development/core/media-hub) `3b694714` | `ubuntu/media-hub/patches/0001-*` |

Build the cross-compile images once: `ubuntu/build-images.sh`. Then build each
component in a scratch directory:

Each block starts in the root of this repository.

```sh
# Mir: libmir1server.so.53 and input-evdev.so.7
( cp -a ubuntu/mir mirwork && cd mirwork
  curl -L https://github.com/canonical/mir/archive/refs/tags/v1.8.3.tar.gz | tar xz && mv mir-1.8.3 src
  rm -rf src/debian
  curl -L https://gitlab.com/ubports/development/core/packaging/mir1/-/archive/5e637dbb3b8c55e2040e75d4743a2e6172be4d68/mir1.tar.gz \
      | tar xz --strip-components=1 -C src
  (cd src && while read -r p _; do case "$p" in ''|'#'*) continue;; esac; patch -p1 < debian/patches/$p; done < debian/patches/series)
  docker run --rm -v "$PWD:/b" mircross:1 bash /b/build-server.sh   # work-server/build/lib/libmir1server.so.53
  docker run --rm -v "$PWD:/b" mircross:1 bash /b/build-evdev.sh )  # out/input-evdev.so.7.stripped

# mir-android2-platform: graphics-android2.so.16 (reuses mirwork/aarch64.cmake)
( cd mirwork && cp ../ubuntu/mir-android2-platform/build-android2.sh .
  git clone https://gitlab.com/ubports/development/core/hybris-support/mir-android2-platform android2/src
  git -C android2/src checkout 72f96d2f69adcd1856295c36ee55ac03ad2860c5
  git -C android2/src apply "$PWD/../ubuntu/mir-android2-platform/0001-apply-initial-display-configuration-policy.patch"
  docker run --rm -v "$PWD:/b" android2cross:1 bash /b/build-android2.sh )   # graphics-android2.so.16.patched

# qtmir: libqt5mir1server.so.1
( mkdir qtmirwork && cd qtmirwork && cp ../ubuntu/qtmir/build.sh .
  git clone https://gitlab.com/ubports/development/core/qtmir qtmir-src
  git -C qtmir-src checkout 418ba72318961b9a6341c0ee9d81802ef0b61ca3
  (cd qtmir-src && patch -p1 < ../../ubuntu/qtmir/0001-qtmir-instantnoodlep.patch)
  docker run --rm -v "$PWD:/build" qtmircross:6 bash /build/build.sh )   # libqt5mir1server1_*.deb

# Qt Quick: libQt5Quick.so.5.15.13
( mkdir qtwork && cd qtwork && cp ../ubuntu/qtdeclarative/{rebuild.sh,null-check-sciReply.patch} .
  docker run --rm -v "$PWD:/build" qtbuild:deps3 bash -c \
      'cd /build && apt-get update && apt-get source --download-only qtdeclarative-opensource-src-gles=5.15.13+dfsg-2'
  docker run --rm -v "$PWD:/build" qtbuild:deps3 bash /build/rebuild.sh )
  # -> qtdeclarative-opensource-src-gles-5.15.13+dfsg/lib/libQt5Quick.so.5.15.13

# media-hub: media-hub-server
( cp -a ubuntu/media-hub mhwork && cd mhwork
  git clone https://gitlab.com/ubports/development/core/media-hub src
  docker run --rm --platform linux/arm64 -v "$PWD:/build" media-hub-build:24.04 sh /build/build.sh )
```

The shipped libraries are stripped the way `dh_strip` does it:
`aarch64-linux-gnu-strip --remove-section=.comment --remove-section=.note --strip-unneeded`.

## 3. Boot image

`device-files/payload/` is the whole device port. On the phone, the boot
image's initramfs copies it into the rootfs on the first boot after it
changes. Some binaries in it come from the builds above. The rest are:

| In the payload | From |
|---|---|
| `usr/lib/halium/hybris-libs/`, `hidl-libs/`, `hidl-libs-icu/`, `odm-blobs/shipped/`, `android.hardware.*.so`, `bin/bootctl`, `bin/vndservicemanager`, `android-overrides/` | the Android build in step 1 (`out/`), or AOSP's VNDK-30 prebuilts (`prebuilts/vndk/v30`) |
| `hybris-libs/libnativewindow.so`, `hybris-libs/android.hardware.graphics.{allocator-V1,common-V3}-ndk.so`, `hidl-libs/android.hardware.thermal@2.0.so` | AOSP libraries (Apache-2.0) from the OxygenOS 13 system image: the Android 13 builds that the stock vendor was linked against |
| `bin/dispcfg` | the device tree (`dispcfg/`) |
| `netd-stub/` | `device-files/netd-stub`, built by `device-files/build-netd-stub.sh` |
| `bin/postproc-stub.so` | `device-files/camera/postproc-stub.cpp`, built with the tree's clang: `-target aarch64-linux-android -shared -fPIC -nostdlib` |
| `dbus-peersec.so` | `device-files/mediahub-shim/dbus-peersec.c`, `aarch64-linux-gnu-gcc -shared -fPIC -O2` |
| `bin/parse-android-dynparts` | [parse-android-dynparts](https://github.com/droidian/parse-android-dynparts) (Apache-2.0), built statically on Ubuntu 24.04 arm64 |

No OnePlus file is in the payload. What the Android side needs from the odm
and modem partitions is copied on the phone at boot (see
`usr/lib/halium/odm-blobs/odm-blobs.list` and `usr/lib/halium/halium-wlan.sh`).

```sh
ANDROID_ROOT=$PWD/halium/android device-files/build-boot-payload.sh \
    halium/android/out/target/product/instantnoodlep/halium-boot.img halium-boot.img
```

The script takes the kernel and dtb from the base image, applies
`initramfs-halium-scripts.patch` to Halium's initramfs, adds the payload, and
refuses to build if the payload's kernel modules do not match the kernel's
symbol CRCs and signing key.

## 4. Zip

```sh
device-files/build-release-zip.sh halium-boot.img \
    ubuntu-touch-android9plus-rootfs-arm64.tar.gz \
    eb7ec75699b784ecfd69dbf784b0829a703af049f98145a006d0abbc3e637773 \
    android-rootfs.img.gz out.zip
```

The rootfs is UBports CI build #104 of `ubuntu-touch-rootfs/ubports/24.04-2.x`,
`ubuntu-touch-android9plus-rootfs-arm64.tar.gz`. UBports' CI keeps the artifacts
of recent builds only and #104's are gone, but the release zip carries the file
unmodified:

```sh
unzip -p instantnoodlep-ubuntu-touch-24.04-2.x-20260924.zip images/ubuntu-touch-rootfs.tar.gz \
    > ubuntu-touch-android9plus-rootfs-arm64.tar.gz
```

The script checks it against the sha256 above, then reads every member back out
of the finished zip to verify it.
