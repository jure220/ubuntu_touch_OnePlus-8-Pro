#!/bin/sh
# Carry the wall clock across reboots on a device whose RTC cannot be written.
STAMP=/userdata/.last-known-time
case "$1" in
  save)
    # MONOTONIC: never move the stamp BACKWARDS. If the clock is currently wrong
    # (e.g. still 1970 because something clobbered it during this boot), an
    # unconditional save would destroy a perfectly good saved time and the next
    # boot would come up at the epoch. Only overwrite with a LATER value.
    now_s=$(date -u '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    if [ -r "$STAMP" ]; then
        old_s=$(cat "$STAMP" 2>/dev/null)
        old_e=$(date -u -d "$old_s" +%s 2>/dev/null || echo 0)
        now_e=$(date -u -d "$now_s" +%s 2>/dev/null || echo 0)
        if [ "${now_e:-0}" -le "${old_e:-0}" ]; then
            sync
            exit 0
        fi
    fi
    printf '%s\n' "$now_s" > "$STAMP" 2>/dev/null
    # Keep systemd-timesyncd's own floor in step. Its clock file gets re-stamped
    # with the WRONG (1970) time during early boot, and timesyncd then drags the
    # clock back down again after we have restored it.
    touch /var/lib/systemd/timesync/clock 2>/dev/null
    sync
    ;;
  restore)
    [ -r "$STAMP" ] || exit 0
    saved=$(cat "$STAMP" 2>/dev/null)
    [ -n "$saved" ] || exit 0
    # Only ever move the clock FORWARD, never back.
    saved_epoch=$(date -u -d "$saved" +%s 2>/dev/null) || exit 0
    now_epoch=$(date -u +%s 2>/dev/null)
    if [ -n "$saved_epoch" ] && [ "$saved_epoch" -gt "$now_epoch" ]; then
        date -u -s "$saved" >/dev/null 2>&1
        touch /var/lib/systemd/timesync/clock 2>/dev/null
    fi
    ;;
esac
exit 0
