#!/bin/sh
# Start Android's software Codec2 service (mediaswcodec) -- the video decoder.
#
# WHY NOT FROM ANDROID INIT
# The natural place is an init .rc, and that was tried. init CAN see the binary
# and CAN see the seccomp policy (verified through /proc/<init>/root/apex/...),
# but the process it forks still dies with:
#     mediaswcodec: Could not read base policy file
#         '/apex/com.android.media.swcodec/etc/seccomp_policy/mediaswcodec.policy'
#     libc: Fatal signal 6 (SIGABRT) ... in SetUpMinijail
# even with the file present, world-readable, and SELinux permissive. Android
# init keeps bootstrap and default mount namespaces and the service ends up
# resolving /apex in one where the APEX payload is not mounted; the path is
# baked into the binary (kSystemSeccompPolicyPath) so it cannot be redirected
# without rebuilding the APEX.
#
# Launching it from inside the container's own (default) mount namespace -- which
# is what lxc-attach enters -- works first try and registers all three
# IComponentStore interfaces. That is what this script does. Same mechanism as
# halium-agps.sh.
#
# WHY IT MATTERS
#     media.swcodec dead
#       -> android.hardware.media.c2@1.0::IComponentStore/software never registers
#       -> libgsthybris.so blocks forever in getService() during the plugin scan
#       -> GStreamer blacklists it -> media-hub: "No video backend selected."
# With it running, media-hub logs "Found hybris backend" instead.
#
# Disable with: touch /userdata/.no-swcodec
#
# /run/halium-codec2-ready is written on EVERY exit (up, gave up, or disabled):
# media-hub's ExecStartPre (media-hub.service.d/10-halium-wait-codec2.conf)
# waits for it so its GStreamer plugin scan never races the codec2 store.  It
# means "done trying", so media-hub is never held back longer than this script.
trap 'touch /run/halium-codec2-ready' EXIT
[ -e /userdata/.no-swcodec ] && exit 0

LOG=/userdata/swcodec.log
log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }
[ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null)" -gt 300 ] && tail -100 "$LOG" > "$LOG.t" && mv "$LOG.t" "$LOG"

# Wait (bounded) for the container.
i=0
while [ $i -lt 90 ]; do
    [ "$(lxc-info -n android -s 2>/dev/null | awk '{print $2}')" = "RUNNING" ] && break
    i=$((i+1)); sleep 1
done
[ "$(lxc-info -n android -s 2>/dev/null | awk '{print $2}')" = "RUNNING" ] || { log "container never came up"; exit 0; }

# apexd needs a moment after the container starts before /apex is populated.
sleep 20

# Retry: apex activation and hwservicemanager both settle at their own pace.
n=0
while [ $n -lt 20 ]; do
    n=$((n+1))
    OUT=$(lxc-attach -n android -- /system/bin/sh -c '
        export PATH=/system/bin:/system/xbin:/vendor/bin
        if lshal 2>/dev/null | grep -q "media.c2@1.0::IComponentStore/software"; then
            echo ALREADY; exit 0
        fi
        # Prefer the APEX copy (what the binary expects); fall back to the copy
        # staged under /odm by halium-dynparts.sh.
        BIN=/apex/com.android.media.swcodec/bin/mediaswcodec
        LIBS=/apex/com.android.media.swcodec/lib64
        if [ ! -x "$BIN" ]; then
            BIN=/odm/swcodec/bin/mediaswcodec
            LIBS=/odm/swcodec/lib64
        fi
        [ -x "$BIN" ] || { echo "NOBIN"; exit 1; }
        setsid env LD_LIBRARY_PATH=$LIBS "$BIN" >/dev/null 2>&1 < /dev/null &
        sleep 6
        if lshal 2>/dev/null | grep -q "media.c2@1.0::IComponentStore/software"; then
            echo "STARTED $BIN"
        else
            echo "FAILED $BIN"
        fi' 2>&1)
    log "attempt $n: $OUT"
    case "$OUT" in
        *ALREADY*|*STARTED*) log "codec2 software store is up"; exit 0 ;;
    esac
    sleep 15
done
log "gave up after $n attempts"
exit 0
