#!/bin/sh
# Put the panel into 1440x3168 @ 120 Hz BEFORE the compositor starts.
#
# WHY THE ORDERING IS THE WHOLE TRICK
# Mir reads the display configuration from the hwcomposer exactly once, at
# startup, and never notices a later change (verified: after `dispcfg set 1` on
# a running system the compositor log shows no "New display configuration" at
# all -- Mir keeps its old framebuffer and SDM just upscales into the bigger
# panel, so you get panel resolution without rendering resolution).
#
# Booting the PANEL at QHD does not work either. With the kernel's
# preferred_timing0 forcing 1440x3168 the composer never emits its primary
# display hotplug, so Mir waits forever:
#     working 1080p boot:  hotplug_hook(0, 0, connected, primary)   <- 4.3 s in
#     QHD boot:            <that line never appears; 65 s, lightdm gives up>
# The hardware is not the problem -- SDM reconfigures its mixer to
# "Mixer WxH 1440x3168-1 for Peripheral" and the panel runs at
# "hactive=1440, vactive=3168, fps=120" quite happily when switched at runtime.
# It is the composer's first-display bring-up that fails when it is initialised
# straight into QHD.
#
# So: let the composer come up in its normal boot mode, switch it to QHD here,
# and only then let Mir start. Mir then negotiates with a composer that is
# already healthy at 1440x3168 and comes up natively at that size:
#     mirserver: . |_ Current mode 1440x3168
#     mirserver: . |_ Logical size 1440x3168
# Measured 124-128 frames/s at that resolution, i.e. the full 120 Hz.
#
# WHY THIS CANNOT LEAVE YOU WITHOUT A UI
# The unit is ordered Before=lightdm.service, so it really does delay the
# compositor -- but it is bounded (about 30 s of retries) and ALWAYS exits 0.
# If the composer never answers, we simply give up and lightdm starts against
# whatever mode the panel booted into, which is exactly today's behaviour.
#
# THE SETTLE DELAY IS LOAD-BEARING -- DO NOT REMOVE IT
# Switching the composer to QHD produces a CORRUPT framebuffer (full-screen
# multicolour/purple static) if it is done too early in boot, but is perfectly
# clean if the composer has been up for a few seconds first. Same end state,
# same dispcfg call -- only the timing differs:
#   boot path, switched the instant dispcfg answered   -> garbled
#   runtime path, composer up for minutes, then switch -> clean, verified twice
# So we wait for the composer to answer AND THEN let it settle before switching.
# If this ever comes back garbled, raise SETTLE before suspecting anything else.
#
# GRID UNIT MUST MATCH THE RESOLUTION. device-info supplies GRID_UNIT_PX and it
# is read once when the session starts. /etc/deviceinfo/devices/halium.yaml now
# sets GridUnit: 28, which is right for 1440x3168 (1440/28 == 1080/21 == 51.4
# grid units across). If you force this script back to a 1080p config, put that
# file back to 21 or the whole UI will be a third too large.
#
# Kill switch:            touch /userdata/.no-120hz
# Override the config:    echo N > /userdata/.display-mode
#   0 = 1080x2376 @ 60    1 = 1440x3168 @ 120  <- native, the good one
#   2 = 1440x3168 @ 60    3 = 1080x2376 @ 120  <- fallback (set GridUnit 21 too)

LOG=/userdata/display-mode.log
DISPCFG=/data/local/tmp/dispcfg          # path INSIDE the container
WANT=3                                    # 3 = 1080x2376 @ 120 Hz; QHD is done later

[ -f /userdata/.no-120hz ] && exit 0

# dispcfg has to be reachable from INSIDE the container, and the container's
# /data is the host's /userdata/android-data -- i.e. user data. The shipped copy
# lives in the boot payload, so stage it into the container-visible path if it
# is missing or stale. This is what keeps the port out of user data: a wiped
# android-data just gets it again on the next boot.
DISPCFG_SRC=/usr/lib/halium/bin/dispcfg
DISPCFG_HOST=/userdata/android-data/local/tmp/dispcfg
if [ -f "$DISPCFG_SRC" ]; then
    if [ ! -f "$DISPCFG_HOST" ] || ! cmp -s "$DISPCFG_SRC" "$DISPCFG_HOST"; then
        mkdir -p "$(dirname "$DISPCFG_HOST")"
        cp -f "$DISPCFG_SRC" "$DISPCFG_HOST" && chmod 0755 "$DISPCFG_HOST"
    fi
fi
[ -f /userdata/.display-mode ] && WANT=$(cat /userdata/.display-mode 2>/dev/null)

log() { echo "$(date +%H:%M:%S) $*" >> "$LOG"; }

# Wait for the composer HAL to answer, then set the config. Bounded at ~30 s
# because lightdm is waiting on us.
#
# NOTE: do not put a bare command name after lxc-attach. lxc-attach inherits the
# CALLER's PATH, and systemd's PATH has no /system/bin, so toybox's "test" is
# not found and every iteration silently takes the "continue" branch. Absolute
# paths only.
SETTLE=8                                  # seconds to let the composer settle
i=0
settled=0
while [ $i -lt 15 ]; do
    i=$((i+1))
    sleep 2
    OUT=$(lxc-attach -n android -- "$DISPCFG" list 2>&1)
    case "$OUT" in
        *"configs:"*) ;;
        *) continue ;;
    esac

    # The composer is answering. Give it SETTLE seconds before touching the
    # mode -- see the comment above; switching immediately corrupts the
    # framebuffer and the screen comes up as colour static.
    if [ $settled -eq 0 ]; then
        log "composer answered on attempt $i; settling ${SETTLE}s before switching"
        sleep $SETTLE
        settled=1
        OUT=$(lxc-attach -n android -- "$DISPCFG" list 2>&1)
    fi

    ACTIVE=$(echo "$OUT" | head -1 | sed 's/.*active: //')
    if [ "$ACTIVE" = "$WANT" ]; then
        log "attempt $i: already config $WANT, nothing to do"
        exit 0
    fi
    RES=$(lxc-attach -n android -- "$DISPCFG" set "$WANT" 2>&1)
    log "attempt $i: $RES"
    case "$RES" in
        *"active is now $WANT"*) log "compositor will start against config $WANT"; exit 0 ;;
    esac
done

log "gave up after $i attempts; lightdm starts at the panel's boot mode"
exit 0
