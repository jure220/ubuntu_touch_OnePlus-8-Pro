#!/bin/sh
# Suspend the device once the screen has been off for a while.
#
# WHY THIS EXISTS
# This port never entered deep sleep: /sys/power/suspend_stats/success stayed 0
# for the life of every boot. The hardware is fine -- a manual `systemctl
# suspend` with the USB cable out gives "PM: suspend entry (deep)" and a clean
# resume. The gap is that nothing ever ASKS.
#
# repowerd is meant to own this policy, but on this kernel it cannot:
#   - its LibsuspendSystemPowerControl backend fails to initialise, because
#     libsuspend wants the legacy Android early-suspend nodes
#     (/sys/power/wait_for_fb_sleep, wait_for_fb_wake) and this 4.19 kernel has
#     neither. It falls back to LogindSystemPowerControl.
#   - that fallback only ever *permits* suspend ("allow_suspend(id=Logind...)"
#     in its debug log); it defers actually initiating one to logind.
#   - logind never does: /etc/systemd/logind.conf is empty so IdleAction is
#     "ignore", sessions always report IdleHint=no, and repowerd additionally
#     holds a block inhibitor on "idle" because it believes it owns that policy.
# Net effect: everyone permits suspend and nobody starts one.
#
# WHY IT IS SAFE TO JUST CALL systemctl suspend
# We deliberately do NOT re-implement the "is it OK to sleep now?" policy.
# repowerd expresses "stay awake" by taking a logind *sleep* block inhibitor
# (in-call via OfonoVoiceCallService, display-on requests, etc), and logind
# refuses a suspend request while any block inhibitor is held. So delegating to
# `systemctl suspend` inherits the correct policy for free. Do not add
# --ignore-inhibitors here; that is exactly what would let the phone sleep
# during a call.
#
# STATUS 2026-09-19: ENABLED. Deep sleep now actually holds.
#
# It was shipped disabled for a day because the SoC woke ~0.25 s after every
# suspend. That was a kernel bug, not a problem with this script: msm_qmp.c
# registered the AOP mailbox IRQ with IRQF_NO_SUSPEND *and* called
# enable_irq_wake() on it, so routine AOP chatter counted as a wakeup
# ("Resume caused by misconfigured IRQ 401 qcom,qmp-aop"). With that
# enable_irq_wake() removed and the kernel rebuilt, measured on-device:
#
#     /proc/uptime  (boottime, counts suspend)     34344.58
#     last dmesg ts (monotonic, excludes suspend)  34311.69
#                                      difference  ~33 s actually suspended
#     "misconfigured IRQ 401" occurrences          0   (was: every suspend)
#
# SUPERSEDED WHEN THE KERNEL HAS AUTOSLEEP (2026-09-19)
#
# Everything above describes a kernel with no /sys/power/autosleep. Once
# CONFIG_PM_AUTOSLEEP=y is built in (see arch/arm64/configs/vendor/halium.config),
# repowerd's own LibsuspendSystemPowerControl initialises and repowerd owns
# suspend properly -- it holds an Android wakelock while the display is on and
# drops it when idle, and the kernel suspends and RE-suspends by itself.
#
# This script must then get out of the way, and not merely because it is
# redundant. Its `systemctl suspend` is a *logind* suspend, and every logind
# sleep/wake cycle makes repowerd run handle_system_resume(), which turns the
# display back on -- the "screen wakes up by itself" bug. It also makes
# NetworkManager re-associate wlan0 from scratch each time, which is what turned
# the wifi indicator into a gear icon. Leaving both mechanisms enabled would keep
# reintroducing exactly the bugs the kernel change removes.
#
# So: stand down if the kernel can do it properly. If autosleep is absent we are
# on an older kernel and the original behaviour below still applies, unchanged.
if [ -e /sys/power/autosleep ]; then
    echo "halium-idle-suspend: /sys/power/autosleep present, repowerd owns suspend; exiting"
    exit 0
fi

# Kill switch:  touch /userdata/.no-idle-suspend
[ -e /userdata/.no-idle-suspend ] && exit 0

DPMS=${DPMS_PATH:-/sys/class/drm/card0/card0-DSI-1/dpms}
IDLE=${IDLE_SECS:-60}        # screen-off seconds before we suspend
POLL=${POLL_SECS:-20}

[ -r "$DPMS" ] || { echo "halium-idle-suspend: $DPMS unreadable, exiting"; exit 0; }

off=0
while true; do
    sleep "$POLL"

    # A connected USB cable keeps the dwc3 controller out of low power mode and
    # the kernel then refuses to suspend at all:
    #   msm-dwc3 a600000.ssusb: Abort PM suspend!! (USB is outside LPM)
    #   PM: Device a600000.ssusb failed to suspend: error -16
    # Retrying that every minute while charging just burns cycles and fills the
    # log, so do not even try while USB is present.
    if [ "$(cat /sys/class/power_supply/usb/present 2>/dev/null)" = "1" ]; then
        off=0
        continue
    fi

    if [ "$(cat "$DPMS" 2>/dev/null)" = "Off" ]; then
        off=$((off + POLL))
        if [ "$off" -ge "$IDLE" ]; then
            systemctl suspend
            off=0
            sleep 30          # let the resume settle before counting again
        fi
    else
        off=0
    fi
done
