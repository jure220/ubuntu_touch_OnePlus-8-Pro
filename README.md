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

## How it is built

The zip contains:

- the **stock UBports 24.04-2.x rootfs**, byte-for-byte as published by UBports
  (CI build #104);
- a **Halium 14** Android system image;
- the **boot image**: kernel plus the device port, which installs itself into
  the rootfs on first boot.

No proprietary OnePlus files are shipped. On first boot the port copies the
files it needs (camera tuning, audio calibration, radio libraries, vibration
waveforms...) from your own phone's odm partition.

The README inside the zip lists every change the port makes.

## Source

[`source/`](source) holds every modified open-source component as patches
against public upstream revisions, with build notes in
[`source/README.txt`](source/README.txt):

| Component | Base |
|---|---|
| Linux kernel 4.19 | LineageOS `android_kernel_oneplus_sm8250`, `lineage-21` |
| Mir 1.8.3 | UBports `mir1` 1.8.3-0ubports1 |
| mir-android2-platform | UBports, commit 72f96d2 |
| qtmir 0.7.2 | UBports 24.04-2.x package |
| Qt Quick 5.15.13 | Ubuntu `qtdeclarative-opensource-src-gles` 5.15.13+dfsg-2 |
| media-hub | UBports, commit 3b69471 |

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
