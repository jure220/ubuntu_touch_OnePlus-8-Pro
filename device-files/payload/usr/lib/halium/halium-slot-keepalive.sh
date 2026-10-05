#!/bin/sh
# Stop the bootloader from bricking the phone every ~7 reboots.
#
# This is an A/B device. The bootloader decrements boot_a's tries_remaining on
# EVERY boot and only resets it when the OS marks the slot "successful".
# On Android that is update_engine's job -- and update_engine is one of the
# services stuck in a crash loop here (missing libstatssocket.so). So nothing
# ever marks the slot good, the counter walks down 7..0, and then the bootloader
# refuses to boot and shows
#   "The current image boot/recovery have been destroyed"
# requiring a PC and `fastboot --set-active=a` to recover.
#
# NOTE: `bootctl mark-boot-successful` is BROKEN on this vendor's HAL -- it sets
# the *unbootable* bit instead of the successful bit (verified: attrs went
# 0x0037 -> 0x0077, unbootable 0 -> 1). Do not use it.
# `set-active-boot-slot` behaves correctly: it restores priority and tries and
# clears unbootable, which is exactly what we need.
BC=/android/vendor/lib64/bootctl
SRC=/usr/lib/halium/bin/bootctl

[ -x "$SRC" ] || exit 0
# /android/vendor/lib64 is an overlay that halium-dynparts.sh wipes each boot,
# so re-place the binary before use. It must live somewhere the container sees.
cp -f "$SRC" "$BC" 2>/dev/null && chmod 755 "$BC" 2>/dev/null || exit 0

# Wait (bounded) for the Android container, which owns the boot_control HAL.
i=0
while [ $i -lt 60 ]; do
    [ "$(lxc-info -n android -s 2>/dev/null | awk '{print $2}')" = "RUNNING" ] && break
    i=$((i+1)); sleep 1
done

# Slot 0 == slot a. Never target b: it is marked unbootable and has no rootfs.
timeout 25 lxc-attach -n android -- /vendor/lib64/bootctl set-active-boot-slot 0 >/dev/null 2>&1
exit 0
