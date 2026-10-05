#!/bin/sh
# Bring the panel up at its native 1440x3168, AFTER the compositor is running.
#
# WHY THIS CANNOT BE DONE AT BOOT, BEFORE MIR STARTS
# dispcfg's SetActiveConfig changes the DISPLAY mode, but the composer only
# recomputes its own framebuffer configuration while a compositor client is
# connected -- in the working case SDM logs
#     DisplayBase::SetFrameBufferConfig: New framebuffer resolution (1440x3168)
# right after Mir creates its layer. Switch before any client exists and the
# composer keeps a 1080p framebuffer while the display scans out 1440p, and the
# screen comes up as full-screen multicolour static.
#
# This was established the hard way, twice:
#   switch at boot (Before=lightdm), no delay      -> garbled
#   switch at boot with an 8 s composer settle     -> garbled  (so NOT timing)
#   switch with Mir already running, then restart  -> clean, reproduced twice
# There is no API to force it either: the QTI DisplayConfig interface
# (config_defs.h) has SetActiveConfig, SetDSIClk, SetQsyncMode and friends, but
# nothing that sets the framebuffer resolution.
#
# So: let the session come up at 1080p, switch, and restart the compositor once.
# The cost is one shell restart a few seconds into boot. That is a real cost and
# it is deliberate -- it is the only ordering the composer actually supports.
#
# Kill switch:  touch /userdata/.no-qhd

FLAG=/run/halium-qhd-done
LOG=/userdata/display-mode.log
DISPCFG=/data/local/tmp/dispcfg
WANT=1                                   # 1440x3168 @ 120
YAML=/etc/deviceinfo/devices/halium.yaml
USC=/var/log/lightdm/unity-system-compositor.log

[ -e "$FLAG" ] && exit 0
[ -f /userdata/.no-qhd ] && exit 0

log() { echo "$(date +%H:%M:%S) qhd: $*" >> "$LOG"; }

# Wait for the compositor to actually be up and rendering a mode.
i=0
while [ $i -lt 40 ]; do
    i=$((i+1))
    sleep 3
    grep -aq "Logical size" "$USC" 2>/dev/null || continue
    pgrep -x lomiri >/dev/null 2>&1 || continue
    break
done
if [ $i -ge 40 ]; then
    log "compositor never came up; leaving the panel at its boot mode"
    touch "$FLAG"
    exit 0
fi

ACTIVE=$(lxc-attach -n android -- "$DISPCFG" list 2>&1 | head -1 | sed 's/.*active: //')
if [ "$ACTIVE" = "$WANT" ]; then
    log "already config $WANT"
    touch "$FLAG"
    exit 0
fi

# The grid unit is read once when the session starts, so it has to be right
# BEFORE we restart lightdm. 1440/28 == 1080/21 == 51.4 grid units across.
mount -o remount,rw / 2>/dev/null
sed -i 's/^  GridUnit: .*$/  GridUnit: 28/' "$YAML" 2>/dev/null
sync
mount -o remount,ro / 2>/dev/null

RES=$(lxc-attach -n android -- "$DISPCFG" set "$WANT" 2>&1)
log "$RES"
case "$RES" in
    *"active is now $WANT"*) ;;
    *)  log "switch failed; putting the grid unit back and staying at 1080p"
        mount -o remount,rw / 2>/dev/null
        sed -i 's/^  GridUnit: .*$/  GridUnit: 21/' "$YAML" 2>/dev/null
        sync; mount -o remount,ro / 2>/dev/null
        touch "$FLAG"; exit 0 ;;
esac

touch "$FLAG"
log "restarting the compositor so it picks up 1440x3168"
systemctl restart lightdm
exit 0
