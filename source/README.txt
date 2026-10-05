Source for the modified components in
instantnoodlep-ubuntu-touch-24.04-2.x-20260924.zip (v1.0)
=================================================

Everything below is a patch against a public upstream revision. Apply it to
that revision and build as upstream does. The rest of the port (scripts,
systemd units, udev rules, QML) ships as plain text inside the boot image under
/halium-device/rootfs and needs no separate source.


KERNEL  (GPL-2.0)
  Binary   images/halium-boot.img, "4.19.324-perf-g8bd8dca04eac-dirty #48"
  Base     https://github.com/LineageOS/android_kernel_oneplus_sm8250
           branch lineage-21, commit 8bd8dca04eac4ef1b642b8440d5cfaed86e5dbf8
  Patch    kernel/kernel-oneplus-sm8250-ubuntu-touch.patch   (git apply)
  Config   vendor/kona-perf_defconfig + vendor/debugfs.config
           + vendor/halium.config (added by the patch)
  Compiler Android clang 17.0.2 (r487747c), the AOSP 14 prebuilt
  Changes  - touchscreen: declare the ABS_MT_WIDTH_MAJOR and ABS_MT_PRESSURE
             ranges; libinput rejected the device without them
           - qcom,qmp-aop mailbox: no wake registration on an IRQF_NO_SUSPEND
             interrupt; it woke the phone from every suspend
           - waitid(P_PIDFD) backport from 5.4 (needed by glib 2.80)
           - camera sensor: a close by an unrelated process no longer resets
             the camera provider's sensor state (black viewfinder)
           - halium.config: options Halium needs, incl. CONFIG_PM_AUTOSLEEP=y,
             and CONFIG_RTC_SYSTOHC off (the RTC is not writable from Linux;
             the NTP write-back retried every second)
  The wifi module (wlan.ko) is built from the same tree, unmodified.

MIR  (GPL-2.0 / GPL-3.0)
  Binaries libmir1server.so.53, mir1/server-platform/input-evdev.so.7
  Base     UBports mir1 1.8.3-0ubports1 (upstream Mir v1.8.3 with the package's
           debian/patches applied), the version in the 24.04-2.x rootfs
  Patches  mir/0001-0006  upstream canonical/mir commits 645248d997,
                          44faae8bc0, 8a9ed5d4db, 2a534ee5f9, e8b38c771c,
                          1a8601a6a4: thread safety of the input device hub
                          (unplugging a dock crashed the session). They were
                          never backported to the 1.8 branch.
           mir/0007       evdev platform: track device fds by fd rather than by
                          path, so a device re-added under the same path cannot
                          close or reuse another device's fd
  Apply in order with patch -p1.

MIR-ANDROID2-PLATFORM  (LGPL-3.0)
  Binary   mir1/server-platform/graphics-android2.so.16
  Base     https://gitlab.com/ubports/development/core/hybris-support/mir-android2-platform
           commit 72f96d2f69adcd1856295c36ee55ac03ad2860c5
  Patch    mir-android2-platform/0001-apply-initial-display-configuration-policy.patch
           Apply the initial display configuration policy when the display is
           created. With a monitor attached at boot the shell failed to start
           and the desktop was shifted left.

QTMIR  (LGPL-3.0 / GPL-3.0)
  Binary   libqt5mir1server.so.1
  Base     UBports qtmir 0.7.2+0~20260902145802.6+ubports24.04.2~1.gbp418ba7,
           the version in the 24.04-2.x rootfs
  Patch    qtmir/0001-qtmir-instantnoodlep.patch   (patch -p1)
           DisplayPort fixes: transient-scale drop, availableDesktopArea
           fallback, null render-target guards, and EXTERNAL_GRID_UNIT_PX, a
           configurable UI scale for the external monitor
  Built with -DNO_TESTS=ON (cross build only, no code change).

QTDECLARATIVE / Qt Quick  (LGPL-3.0)
  Binary   libQt5Quick.so.5.15.13
  Base     Ubuntu qtdeclarative-opensource-src-gles 5.15.13+dfsg-2
  Patch    qtdeclarative/null-check-sciReply.patch, appended to debian/patches/series
           Null check in QQuickBorderImage::sciRequestFinished(); the shell
           crashed when a monitor was plugged in.

MEDIA-HUB  (LGPL-3.0)
  Binary   /usr/lib/halium/media-hub-server
  Base     https://gitlab.com/ubports/development/core/media-hub
           commit 3b6947149b6454af10847d50adc8dc13e113b213
  Patch    media-hub/0001-power-fix-repowerd-lock-leak-race.patch   (git apply)
           Closing a video while it played leaked a keep-awake lock, after which
           the phone never deep-slept until a reboot.
