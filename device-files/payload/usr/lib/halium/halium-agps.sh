#!/bin/sh
# Start Qualcomm's XTRA (A-GPS) downloader.
#
# WHY THIS EXISTS: without assistance data the GNSS receiver has to decode
# orbital data straight off the satellites, which takes 12.5 minutes of
# unbroken reception PER SATELLITE. Measured on this device: the receiver
# tracks fine (SNR ~34 dB-Hz) but reports has_ephimeris=0 for every SV, so it
# can see satellites and still never produce a fix.
#
# xtra-daemon is normally launched by loc_launcher, which reads
# /vendor/etc/izat.conf (where xtra-daemon is already PROCESS_STATE=ENABLED).
# But loc_launcher exits 255 on this port: first because
# /data/vendor/location/gps.prop did not exist (created, mode 660, owner
# gps:gps -- that specific error went away), and then still 255 for a reason
# not yet identified. xtra-daemon itself runs perfectly standalone and creates
# its database at /data/vendor/location/xtra/xtra.sqlite, so skip the launcher.
#
# NOTE: this makes outbound connections to Qualcomm's XTRA servers to fetch
# assistance data -- the same thing stock Android does. Disable with:
#   touch /userdata/.no-agps
#
# Gates NOTHING (project rule 3): runs detached, ignores every failure.
[ -e /userdata/.no-agps ] && exit 0

n=0
while [ $n -lt 90 ]; do
    [ "$(lxc-info -n android -s 2>/dev/null | awk '{print $2}')" = "RUNNING" ] && break
    n=$((n+1)); sleep 1
done
[ "$(lxc-info -n android -s 2>/dev/null | awk '{print $2}')" = "RUNNING" ] || exit 0

# loc_launcher's missing prop file, recreated here because /data is wiped
# less predictably than we would like and this costs nothing.
if [ ! -f /android/data/vendor/location/gps.prop ]; then
    touch /android/data/vendor/location/gps.prop 2>/dev/null
    chown 1021:1021 /android/data/vendor/location/gps.prop 2>/dev/null
    chmod 660 /android/data/vendor/location/gps.prop 2>/dev/null
fi

# Give the location stack a moment to settle, then start the daemon.
#
# RETRY, do not fire once: measured on a real boot, a single attempt ~20 s in
# silently does nothing -- lxc-attach can fail even after the container reports
# RUNNING, and every error here is deliberately discarded, so a one-shot start
# looks identical to success. Keep trying until pgrep actually confirms it.
#
# setsid INSIDE the container is load-bearing: with a plain 'nohup ... &' the
# daemon is killed as soon as lxc-attach's session ends, so it appears to start
# and then vanishes. Measured both ways.
#
# Bracketed pgrep pattern per project rule 9 so it cannot match this script's
# own command line.
sleep 20
n=0
while [ $n -lt 20 ]; do
    if lxc-attach -n android -- /system/bin/sh -c \
         'export PATH=/system/bin:/system/xbin:/vendor/bin; pgrep -f "xtra-daemo[n]" >/dev/null' 2>/dev/null; then
        exit 0                      # already up, nothing to do
    fi
    timeout 30 lxc-attach -n android -- /system/bin/sh -c \
        'export PATH=/system/bin:/system/xbin:/vendor/bin; setsid /vendor/bin/xtra-daemon >/dev/null 2>&1 < /dev/null &' \
        >/dev/null 2>&1
    sleep 15
    n=$((n+1))
done
exit 0
