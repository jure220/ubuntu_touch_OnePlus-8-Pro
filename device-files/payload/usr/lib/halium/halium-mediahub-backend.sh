#!/bin/sh
# Repair media-hub's video backend once per boot, if it is missing.
#
# THE PROBLEM
# On every boot media-hub logs:
#     media-hub: No video backend selected. Video functionality won't work.
#     media-hub: No video backend selected. Video recording functionality won't work.
# and then never registers android.media.IMediaRecorderObserver, so video
# RECORDING blocks for 50 s and fails, and local video PLAYBACK has no backend.
#
# WHY
# media-hub's AVBackend::get_backend_type() probes the GStreamer registry for
# libgsthybris.so. At boot that plugin blocks in getService() waiting for
# android.hardware.media.c2::IComponentStore/software, which is served by
# mediaswcodec -- started by halium-swcodec.service, at roughly the same moment.
# media-hub loses the race, GStreamer blacklists the plugin, and the blacklist is
# written into ~/.cache/gstreamer-1.0/registry.aarch64.bin, which then persists.
# A plain "systemctl restart media-hub" does NOT fix it: the stale registry is
# reused. The registry file has to be deleted first.
#
# WHAT THIS DOES
# Waits for the codec2 software store to actually be up, then checks the direct
# symptom -- is the recorder observer registered? -- and only if it is missing
# deletes the registry and restarts media-hub. The rescan costs ~2 minutes of
# CPU, so it is deliberately NOT done unconditionally on every boot.
#
# SAFETY NET since 2026-09-24: media-hub is now ordered after the codec2 store
# (media-hub.service.d/10-halium-wait-codec2.conf), so this should only ever act
# on a registry poisoned by an older install.
#
# WORKAROUND, LABELLED AS ONE. The proper fix is to order media-hub after the
# codec2 store so it never loses the race. That ordering is awkward here because
# media-hub is a per-user unit and halium-swcodec.service is a system unit, so
# this repairs the symptom instead. If media-hub ever gains a native "retry the
# backend probe" option, prefer that.
#
# Kill switch: touch /userdata/.no-mediahub-fix

LOG=/userdata/mediahub-backend.log
U=32011
[ -f /userdata/.no-mediahub-fix ] && exit 0

log() { echo "$(date +%H:%M:%S) $*" >> "$LOG"; }

as_phablet() {
    sudo -u phablet XDG_RUNTIME_DIR=/run/user/$U \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$U/bus "$@"
}

# 1. wait for the codec2 software store (absolute paths after lxc-attach --)
i=0
while [ $i -lt 60 ]; do
    i=$((i+1)); sleep 5
    N=$(lxc-attach -n android -- /system/bin/lshal 2>/dev/null | grep -c "media.c2.*software")
    [ "${N:-0}" -ge 1 ] && break
done
if [ "${N:-0}" -lt 1 ]; then
    log "codec2 store never came up after $i attempts; leaving media-hub alone"
    exit 0
fi
log "codec2 store up after $i attempts"

# 2. is the backend actually missing? the observer is the direct symptom
sleep 10
OBS=$(lxc-attach -n android -- /system/bin/service list 2>/dev/null | grep -c MediaRecorderObserver)
if [ "${OBS:-0}" -ge 1 ]; then
    log "recorder observer already registered; nothing to do"
    exit 0
fi

# 3. repair: the registry must be DELETED, a plain restart reuses it
log "no video backend; deleting gstreamer registry and restarting media-hub"
rm -f /home/phablet/.cache/gstreamer-1.0/registry.aarch64.bin
as_phablet systemctl --user restart media-hub >/dev/null 2>&1
# a full registry rescan takes up to ~2 minutes; poll instead of guessing
i=0
while [ $i -lt 36 ]; do
    i=$((i+1)); sleep 5
    OBS=$(lxc-attach -n android -- /system/bin/service list 2>/dev/null | grep -c MediaRecorderObserver)
    [ "${OBS:-0}" -ge 1 ] && break
done
if [ "${OBS:-0}" -ge 1 ]; then
    log "repaired: observer registered, video backend up"
else
    log "repair FAILED: observer still missing"
fi
exit 0
