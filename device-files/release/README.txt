Ubuntu Touch 24.04-2.x (Halium 14) for the OnePlus 8 Pro
========================================================
Device: instantnoodlep  (IN2020 / IN2021 / IN2023 / IN2025)
Version 1.0 -- port by Z3PHYR

INSTALL
  1. Unlock the bootloader (this wipes the phone).
  2. Boot a recovery that can mount userdata and dynamic partitions
     (TWRP or OrangeFox for instantnoodlep).
  3. Format Data (not just "wipe") and choose ext4 as the file system.
     OrangeFox defaults to f2fs, which this port cannot boot from; the zip
     refuses to install on f2fs.
  4. Flash this zip. It also switches off verified boot (see below).
  5. Reboot. First boot takes 2-3 minutes.

  Installing over an earlier build of this port without formatting keeps
  your settings, apps and WiFi networks; the installer removes the port's own
  old system files from /userdata/system-data so the new ones take effect.

  First boot runs Ubuntu Touch's first-run setup. User: phablet; the
  passcode you set there is the password (it is empty until then).
  Settings > About > Developer Mode turns on ADB (over USB). SSH is a
  separate service and is off, as on every Ubuntu Touch device. To use it,
  put your public key in /home/phablet/.ssh/authorized_keys (password
  logins are disabled) and run in the Terminal app:
      sudo systemctl enable --now ssh
  It listens on WiFi and on the USB network (phone at 10.15.19.82).

WHAT IT DOES
  vbmeta     <- verification switched off (the two flags that
                `fastboot --disable-verity --disable-verification` sets),
                because the boot image is not signed with OnePlus's key.
                Flashing your stock vbmeta.img undoes it.
  boot       <- halium-boot.img. The device port (systemd units, helper
                scripts, wlan.ko, xt_CHECKSUM.ko) is inside this image and
                installs itself into the rootfs on first boot.
  userdata   <- rootfs.img (Ubuntu Touch 24.04-2.x arm64, 6 GB)
                android-rootfs.img (Halium Android 14 system)
  On first boot the boot image also builds /userdata/odm-blobs from YOUR
  OWN PHONE's odm partition, and every boot it reads the WiFi firmware from
  your phone's modem partition (see below).

HOW THIS IMAGE IS BUILT (and why there is no personal data in it)
  The Ubuntu side is the STOCK UBports rootfs, byte-for-byte as published:

    https://ci.ubports.com/job/ubuntu-touch-rootfs/job/ubports%2F24.04-2.x/
        104/artifact/ubuntu-touch-android9plus-rootfs-arm64.tar.gz
    sha256 eb7ec75699b784ecfd69dbf784b0829a703af049f98145a006d0abbc3e637773
    (build #104, 2026-09-23 -- the newest 24.04-2.x rootfs at release time)

  It is not modified, and nothing is captured from anyone's phone, so there
  is no user data in it by construction rather than by scrubbing.

  Everything specific to this port lives in the boot image instead. The
  initramfs carries /halium-device/{STAMP,rootfs}, and the first boot after
  the STAMP changes copies that tree into the rootfs. So:

      zip  =  pinned upstream rootfs  +  this port's boot image

  Full source (kernel and device tree, Android-tree patches, the boot image
  payload, Mir, qtmir, Qt Quick, media-hub and every build script):
  https://github.com/jure220/ubuntu_touch_OnePlus-8-Pro

  What the boot image overlays (only things the stock rootfs lacks):
    libqt5mir1server.so.1     qtmir, rebuilt with DisplayPort fixes; the
                              external monitor's UI scale is configurable
                              (EXTERNAL_GRID_UNIT_PX, set to 9 here; upstream
                              fixes it at 8, which made panel icons such as
                              the battery too small to read)
    libQt5Quick.so.5.15.13    Qt5 fix for a null deref that crashed the shell
    Mir (3 rebuilt libraries) unplugging the dock no longer crashes the
                              whole session (upstream thread-safety fix
                              backported to Mir 1.8); the desktop is no longer
                              shifted left, and the shell no longer fails to
                              start, when the phone boots or restarts with a
                              monitor already attached
    ShellScreen.qml           dual-primary-screen and Loader sizing fixes
    ImageResolver.qml         undefined-to-QUrl guard
    camera app (3 QML files)  lens buttons 0.6x / 1x / 2.2x for the three rear
                              cameras; the flip animation only when switching
                              between front and rear, a short fade between
                              rear lenses; viewfinder no longer black when the
                              app is opened lying flat
    kernel camera fix         a sensor is no longer reset when an unrelated
                              program (GStreamer's plugin scanner) merely
                              opens and closes its device node; that reset
                              made the camera open to a black viewfinder
    media-hub (rebuilt)       closing a video while it played left a
                              "keep awake" lock behind, and the phone then
                              never deep-slept again until a reboot
    deviceinfo halium.yaml    grid unit + display cutouts (camera, screen curve)
    odm build.prop            the phone names itself "OnePlus 8 Pro" instead of
                              the Qualcomm reference board ("Kona for arm64"),
                              in Waydroid and as the USB/MTP device on a PC.
                              A Waydroid set up before this release keeps the
                              old name: run  sudo waydroid upgrade --offline
                              and rename it under Android Settings > About
                              phone > Device name (Android stores that once)
    libhwc2_compat_layer.so   bound over the read-only Android image
    16 systemd units          15 of them enabled; dpkg-db-backup and logrotate
                              masked (they fail on the read-only root)
    70-halium-audio.rules     udev: Qualcomm audio node ownership (call audio)
    99-halium-gpu.rules       udev: GPU/ion nodes usable by the shell (without
                              it the shell segfaults on a clean install)
    76-halium-wlan-names.rules  keep the wifi interface named wlan0
    70-halium-flashlight.rules  udev: torch LED writable by the session, so
                              the status-bar flashlight switch works
    wifi MAC                  your phone's own factory MAC, read from persist
                              (a stable per-phone address if that is missing)
    user-session drop-ins     PulseAudio: vendor-era libui first on the
                              libhybris path (audio HAL); media-hub: start
                              after the codec2 store (video backend); session
                              D-Bus: dbus-peersec.so (see SECURITY below);
                              url-dispatcher: retry while the shell starts
    10-halium-wowlan.conf     NetworkManager: keep wifi associated across suspend
    10-halium-odm-vintf.conf  systemd drop-in: start the IQcRilAudio passthrough
                              (call audio), which the stock unit skips on this
                              device because it looks for the VINTF manifest
                              only under /vendor and ours is under /odm
    ril_subscription.conf     ofono over hwbinder, both SIM slots
                              ("binder:name=slot1" and "slot2"), spelled out so
                              the call-audio passthrough above finds them too
    netd HIDL stub            android.system.net.netd@1.1::INetd. Qualcomm's
                              netmgrd waits forever for a netd service, which
                              Halium does not ship; without it mobile data
                              could never start
    odm-blobs builder         see "ODM BLOBS" below

ODM AND FIRMWARE FILES ARE NOT SHIPPED
  The Halium container needs 381 files from OnePlus's odm partition (NFC,
  fingerprint, camera modules and tuning, audio calibration, radio libraries,
  vibration waveforms, the WiFi driver config, the telephony VINTF manifest).
  Those are proprietary OxygenOS files, so they are not in this zip: on first
  boot the port copies exactly that list off your phone's own odm partition
  into /userdata/odm-blobs, and merges the stock telephony manifest. The WiFi
  firmware (QCA6390) is read the same way from your phone's modem partition
  at every boot. Keep the stock odm and modem partitions intact (do not flash
  a different ROM's super/odm or modem over them). Nothing is downloaded.

  The Halium Android system image is a LineageOS 21 build. Like every
  LineageOS build it contains the system_ext libraries from LineageOS's
  vendor repository (Qualcomm's IMS, Wi-Fi Display and DPM libraries, and
  OnePlus's IMS extension). The boot image carries
  open-source code only: Mir, Qt, media-hub, the kernel modules and Android
  libraries built from source, AOSP's VNDK-30 prebuilts, and four AOSP
  libraries (Apache-2.0) taken from the OxygenOS 13 system image.

KNOWN STATE
  Working : display 1080x2376 @ 120 Hz, touch, WiFi, Bluetooth, audio,
            cameras incl. video recording, GPS/A-GPS, NFC, sensors,
            auto-brightness, ADB, Waydroid (Android 13 in a container),
            alert slider -> silent/vibrate/ring,
            EXTERNAL DISPLAY over USB-C (DisplayPort alt mode), with the
            punch-hole camera and the curved screen edge declared as display
            cutouts so the status bar lays out around them
  Cellular: voice calls with audio, SMS and mobile data,
            tested with a SIM in slot 1. Mobile data connects by itself; with
            WiFi off, DNS and browsing go over the cellular link, and WiFi is
            preferred whenever it is connected.
            Not yet tested: a SIM in slot 2 (the slot is detected and ready).
  Unknown : the microphone. The developer's phone has a faulty microphone,
            so it could not be verified.

            Call audio needed two fixes, both in the overlay list above: the
            audio-calibration node permissions (70-halium-audio.rules) and the
            call-audio passthrough, which the stock unit skipped on this device
            and which needs "transport=binder:name=slot1" in ofono's config
            (10-halium-odm-vintf.conf, ril_subscription.conf). If a call is
            ever silent, look at
                journalctl --user -u audiosystem-passthrough-qti
            first.
  Not working:
            fingerprint enrolment. The sensor and trustlet are fine; the
            calibration state in the trustzone app reads caliState=0x10 and
            enrolment needs bits 0+1 set. Calibration can only be run from
            OnePlus's engineering mode under stock OxygenOS. It is stored in
            the persist partition, which survives a ROM install, so
            calibrating on stock carries over.
  Parked  : 1440p. Works, but the status bar renders wrong. Disabled by
            default (/userdata/.no-qhd).

  DEEP SLEEP (battery)
            Fixed. The kernel is built with CONFIG_PM_AUTOSLEEP=y, which is
            what repowerd's own suspend backend needs; without it repowerd
            fell back to logind, never initiated a suspend at all, and turned
            the DISPLAY ON at every resume -- the phone appeared to wake up by
            itself every few minutes. Measured after the fix: hundreds of real
            suspends per hour and zero logind sleep cycles.

            WiFi is configured for WoWLAN (see 10-halium-wowlan.conf). Without
            it, cfg80211 tears the association down on every suspend and
            re-runs DHCP on every resume -- measured at 290 re-associations and
            289 failed DHCP leases in 3.5 h. With it: zero.

            Consequence worth knowing: the phone now really sleeps, so it stops
            answering the network promptly while suspended. That is correct
            behaviour, not a fault.

  Note also: a USB cable blocks suspend entirely (dwc3 refuses with -16,
            "USB is outside LPM"). That is normal, but it means suspend can
            only ever be tested with the cable out.

  IDLE POWER, HONESTLY
            Idle draw was measured at roughly 210-225 mA with NO SIM CARD
            INSERTED, and ~100 % of the wakeups in that state come from the
            modem, which has no network to camp on and retries continuously.
            That number is therefore NOT representative of normal use and
            should be re-measured with a SIM in before drawing any conclusion
            about battery life.

SECURITY POSTURE (read before trusting this with anything)
  The bootloader must stay unlocked for a Halium port to boot at all, so
  androidboot.verifiedbootstate=orange and nothing verifies the kernel or
  boot image. The Android side is a userdebug build signed with test-keys;
  that is not checked by anything in this configuration and cannot be
  improved without OnePlus's signing keys. SELinux runs Permissive inside
  the container, and AppArmor CANNOT be enabled on this kernel (its active
  LSM is SELinux, which the container requires), so click apps are NOT
  confined. Anyone with physical access and a USB cable can read userdata.
  Because nothing is confined, the session D-Bus reports every client as
  "unconfined" (a small LD_PRELOAD shim, dbus-peersec.so); media-hub
  otherwise crashes on the SELinux label and nothing can play.

NO WARRANTY. This replaces the OS on your phone.
