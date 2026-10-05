# Ubuntu Touch for the OnePlus 8 Pro

Ubuntu Touch 24.04-2.x (Halium 14) for the OnePlus 8 Pro (`instantnoodlep`,
IN2020 / IN2021 / IN2023 / IN2025).

**Port by Z3PHYR.** The download is on the
[Releases](https://github.com/jure220/ubuntu_touch_OnePlus-8-Pro/releases) page:
one recovery-flashable zip.

## What works

- Display at 1080x2376 / 120 Hz, touch, WiFi, Bluetooth, audio, vibration
- Cameras (three rear lenses with a lens switcher, front), video recording
- Calls with audio, SMS, mobile data
- GPS / A-GPS, NFC, sensors, auto-brightness, alert slider, status-bar flashlight
- Deep sleep, with alarms waking the phone
- External monitor over USB-C (DisplayPort), desktop mode
- Waydroid (Android apps in a container)

**Not working / Unknown:**
Fingerprint enrolment, microphone (My device has faulty hardware)

## Install

You need an unlocked bootloader and the phone on **stock OxygenOS 13**: the
port uses the vendor and odm partitions that OxygenOS 13 leaves on the phone.

1. Boot a recovery that can mount userdata and dynamic partitions, for example
   OrangeFox for OnePlus 8 / 8 Pro (`fastboot boot OrangeFox.img`).
2. Wipe > Format Data, and choose **ext4** as the file system.
3. Flash the zip. It also switches off verified boot (vbmeta), because the boot
   image is not signed by OnePlus.
4. Reboot.

## IR Camera app

The fifth rear camera (the 5 MP colour-filter "photochrom" sensor) is not
reachable from the stock camera app. The **IR Camera** app opens it, with a
live viewfinder and manual or automatic exposure. It is on the
[Releases](https://github.com/jure220/ubuntu_touch_OnePlus-8-Pro/releases) page
as a click package and as a recovery-flashable zip; source and install notes
are in [`apps/ircam/`](apps/ircam).

## How it is built

The zip contains:

- the **stock UBports 24.04-2.x rootfs**, byte-for-byte as published by UBports
  (CI build #104);
- a **Halium 14** Android system image;
- the **boot image**: kernel plus the device port, which installs itself into
  the rootfs on first boot.

The port does not ship OnePlus's device files: it copies what it needs
(camera tuning, audio calibration, radio libraries, vibration waveforms, WiFi
firmware...) from your own phone's odm and modem partitions. The Android
system image is a LineageOS 21 build and, like every LineageOS build, contains
the system_ext libraries from LineageOS's vendor repository (Qualcomm's IMS,
Wi-Fi Display and DPM libraries, and OnePlus's IMS extension).

The README inside the zip lists every change the port makes.

## Source

Everything needed to rebuild the zip is public. [BUILDING.md](BUILDING.md)
walks through it.

| What | Where |
|---|---|
| Linux kernel 4.19 | [jure220/android_kernel_oneplus_sm8250](https://github.com/jure220/android_kernel_oneplus_sm8250/tree/lineage-21-ubuntu-touch), branch `lineage-21-ubuntu-touch` (LineageOS `lineage-21` + the port's commits) |
| Device tree | [jure220/android_device_oneplus_instantnoodlep](https://github.com/jure220/android_device_oneplus_instantnoodlep/tree/lineage-21-ubuntu-touch), branch `lineage-21-ubuntu-touch` |
| Android tree | [`manifests/`](manifests) (local manifests for Halium 14), [`android-patches/`](android-patches) (changes to Halium and AOSP projects) |
| Device port | [`device-files/payload/`](device-files/payload): systemd units, scripts, udev rules, configs, prebuilt libraries; installed into the rootfs by the boot image |
| Boot image and zip | [`device-files/`](device-files): `build-boot-payload.sh`, `initramfs-halium-scripts.patch`, `build-release-zip.sh`, the installer |
| IR Camera app | [`apps/ircam/`](apps/ircam): Camera2 client through libhybris, QML plugin, click and flashable-zip packaging |
| Mir, mir-android2-platform, qtmir, Qt Quick, media-hub | [`ubuntu/`](ubuntu): patches against the exact package sources, Dockerfiles and build scripts |

## Security

The bootloader has to stay unlocked, so nothing verifies the boot image. The
Android side runs SELinux in permissive mode, and click apps are not confined.
Anyone with physical access can read the phone's data. The README in the zip
has the details.

## Credits

Built on the work of [UBports](https://ubports.com) (Ubuntu Touch, Lomiri),
[Halium](https://halium.org), [LineageOS](https://lineageos.org) (kernel and
device trees for the OnePlus 8 series) and the upstream Mir, Qt and Ayatana
projects.

No warranty. Flashing this replaces the operating system on your phone.
