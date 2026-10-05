#!/bin/sh
# Stop the Android container services that can never work on this port, so they
# stop crash-looping.
#
# WHY THIS EXISTS
# ~15 vendor/system services abort on startup (missing VNDK symbols, libraries
# that are present but off the linker path, etc). Android init restarts a
# `class main` service every time it dies, forever. Each abort also spawns
# crash_dump32 to write a tombstone. The result is a slow-motion fork bomb:
# this device reached 29557 threads and 7.0/7.5 GB used, with 23 MB free and no
# swap. Consequences observed:
#   - the OOM killer took NetworkManager -> WiFi silently stopped working
#   - fork() started failing, so `reboot` itself could not run
#   - sshd took minutes to answer
# Stopping them recovered 5.5 GB and took threads from 29557 to ~1557.
#
# `ctl.stop` is the right lever: Android init does NOT auto-restart a service
# that was explicitly stopped, unlike one that merely crashed.
#
# WHAT IS DELIBERATELY LEFT RUNNING
#   vendor.camera-provider-2-4   camera partly works; owner wants it
#   vendor.qcrild / qcrild2      cellular works
#   vendor.power                 works, repowerd uses it
#   vendor.usb-hal-1-2           NEVER touch USB: it owns the gadget that
#                                carries SSH (project rule 7)
# Kill switch: touch /userdata/.no-quiet-android
[ -e /userdata/.no-quiet-android ] && exit 0

# vendor.bluetooth-1-0-qti was REMOVED from this list on 2026-09-02. It was
# only ever here because it crash-looped, and it crash-looped for a fixable
# reason: a missing android.hardware.bluetooth@1.0.so (see halium-dynparts.sh).
# With that library installed it reaches state=running and stays there, and
# bluebinder needs it alive to create the HCI device. Sweeping it was stopping
# the very HAL Bluetooth depends on. Verified: state=running, IBluetoothHci
# registered, no restart loop.
# media.swcodec: REMOVED, then PUT BACK the same day, for a different reason.
#
# It was originally swept because it crash-looped. Removing it proved the point
# (see below) but exposed a second fact: init's OWN instance can never work,
# because the binary aborts on a seccomp policy path it resolves in the wrong
# mount namespace. So init retries it forever.
#
# The working instance is started OUTSIDE init, from the container's default
# namespace, by halium-swcodec.service. `setprop ctl.stop media.swcodec` only
# stops the init-managed service, so sweeping here suppresses init's doomed
# retry loop WITHOUT touching the instance that actually serves
# IComponentStore/software. Verified: c2 ifaces stays 3 with this in the list.
#
# The original note, kept because the reasoning still matters:
# it was sweeping every 10 s:
#     init: Control message: Processed ctl.stop for 'media.swcodec' ... (x N)
# It was originally added because it really was crash-looping:
#     init: cannot execv('/apex/com.android.media.swcodec/bin/mediaswcodec'):
#           No such file or directory        -> exited with status 127
# i.e. the APEX payload was not activated. That is no longer true: inside the
# CONTAINER's mount namespace /apex/com.android.media.swcodec now has bin/ and
# lib64/ populated (apex mounts are per-namespace -- the HOST view of
# /android/apex still looks empty, which is what made this look unfixed).
# So the sweeper was the only thing still stopping it, and media.swcodec is what
# serves android.hardware.media.c2@1.0::IComponentStore/software, which
# libgsthybris blocks on, which is why media-hub reports no video backend.
# vendor.dataqti (= /system/vendor/bin/qti) added 2026-09-20.
#
# This one can NEVER work on this port, so unlike most entries here it is not a
# workaround for something still to be fixed. Its job is to bridge QMI messages
# over the ANDROID USB gadget's rmnet function, for USB tethering. Halium gives
# USB to usb_moded instead, so that gadget function does not exist and the node
# it wants is simply absent:
#
#     qti_rmnet_ph_init(): Open peripheral file to receive QMI messages
#     qti_file_open(): Could not open device file. Errno 2  (ten attempts)
#     qti_rmnet_ph_init(): Failed to open USB peripheral device file ... Abort.
#     main(): Failed to initialize QTI peripheral interface
#
# It is not `oneshot`, so init restarts it on every abort forever. Measured
# before sweeping it: 138 restarts in one boot, and 55 of every 103 logcat lines
# (53%) were its failure messages. `ctl.stop` is sticky for it -- verified
# stopped and still stopped 60 s later, with QTI log lines dropping to 0 and
# total logcat volume from 103 to 13 lines per 30 s.
#
# Do NOT remove this entry expecting the underlying problem to be fixable: it
# would require giving Android back the USB gadget, which is exactly what this
# port does not do.
SERVICES="vendor.audio-hal vendor.cas-hal-1-2
neuralnetworks_hal_service vendor.light-qti statsd gpu update_engine dpmd
mediaextractor mediametrics media.swcodec loc_launcher vendor.wifi_hal_legacy
vendor.dataqti"

# Wait (bounded) for the container.
i=0
while [ $i -lt 90 ]; do
    [ "$(lxc-info -n android -s 2>/dev/null | awk '{print $2}')" = "RUNNING" ] && break
    i=$((i+1)); sleep 1
done
[ "$(lxc-info -n android -s 2>/dev/null | awk '{print $2}')" = "RUNNING" ] || exit 0

# Sweep repeatedly. init declares and starts services over a long period, and
# under boot load an lxc-attach can take many seconds, so a short burst of
# sweeps misses most of them -- that was observed: the unit went active, yet 15
# services were still restarting afterwards. One manual sweep at that point took
# it to 1, so the mechanism is right and only the window was wrong.
# ONE lxc-attach per sweep, not one per service.
# Measured: `setprop ctl.stop <svc>` works reliably (statsd went restarting ->
# stopped immediately), but entering the container is the expensive part and is
# slow precisely when the device is loaded -- which is exactly when the sweep
# matters. With one lxc-attach per service, 14 services x up to 25 s meant a
# single sweep could take minutes, so services stayed "restarting" for the whole
# of phase 1. Batching all the setprops into one container entry makes a sweep
# one round trip instead of fourteen.
# Lightweight instrumentation (added 2026-09-02). This unit is the thing
# standing between the device and the fork-bomb/OOM state that once needed a
# hard power cycle, and twice now it has LOOKED like it was not sweeping while
# a hand-run sweep with the identical list worked instantly. Every failure mode
# here is silent by design (errors discarded so the sweeper can never wedge the
# boot), which is exactly what made that ambiguous. One timestamped line per
# sweep, capped, costs nothing and settles it.
SWEEPLOG=/userdata/quiet-sweep.log
# lxc-attach inherits the CALLER's PATH into the container, so under systemd
# nothing inside resolves -- not even sh, and then not setprop. Set Android's
# own PATH explicitly rather than absolute-pathing each binary.
ANDROID_PATH=/system/bin:/system/xbin:/vendor/bin
# NOTE: "/system/bin/sh", never bare "sh".
# THIS BUG MADE THE WHOLE SWEEPER INERT FROM BOOT. lxc-attach passes the
# CALLER's PATH into the container. Interactively that inherits a login PATH
# and "sh" happens to resolve, so every hand-run sweep worked and the unit
# looked healthy. Under systemd the PATH is the host's
# (/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/snap/bin) -- none of
# which exist inside the container -- so every single sweep died instantly with
#   lxc-attach: Failed to exec "sh" - No such file or directory   (rc=127)
# and, because errors here are deliberately discarded, it failed silently for
# the entire life of this unit. Found only by logging rc + stderr per sweep.
# Android's shell is /system/bin/sh; always spell it out.
sweep() {
    cmds=""
    for s in $SERVICES; do
        cmds="$cmds setprop ctl.stop $s;"
    done
    _t0=$(cut -d' ' -f1 /proc/uptime)
    _err=$(timeout 40 lxc-attach -n android -- /system/bin/sh -c \
        "export PATH=$ANDROID_PATH; $cmds" 2>&1 >/dev/null)
    _rc=$?
    _t1=$(cut -d' ' -f1 /proc/uptime)
    # Keep the log bounded: trim to the last 200 lines every so often.
    [ -f "$SWEEPLOG" ] && [ "$(wc -l < "$SWEEPLOG" 2>/dev/null || echo 0)" -gt 400 ] && \
        { tail -n 200 "$SWEEPLOG" > "$SWEEPLOG.tmp" 2>/dev/null && \
          mv "$SWEEPLOG.tmp" "$SWEEPLOG" 2>/dev/null; }
    echo "up=$_t0 dur=$(echo "$_t1 $_t0" | awk '{printf "%.1f", $1-$2}')s rc=$_rc${_err:+ err=$_err}" \
        >> "$SWEEPLOG" 2>/dev/null
}

# Phase 1 -- boot burst, tight interval while init is still bringing things up.
n=0
while [ $n -lt 30 ]; do
    sweep
    n=$((n+1))
    sleep 10
done

# Phase 2 -- STAY RESIDENT.
# `ctl.stop` is not permanent: it holds only until something re-triggers the
# service (an init `on property:` trigger, or a client asking for it). Measured
# on a healthy boot hours after the burst window ended: 15 services were
# restarting again, including the same audio/wifi/usb HALs. Memory was still OK
# at that moment, but this is exactly the state that ran away once before --
# 29557 threads, 23 MB free, OOM killer taking NetworkManager, fork() failing so
# even `reboot` could not run. A cheap periodic sweep keeps them down.
# These are all no-ops when a service is already stopped.
while true; do
    sleep 60
    sweep
done
