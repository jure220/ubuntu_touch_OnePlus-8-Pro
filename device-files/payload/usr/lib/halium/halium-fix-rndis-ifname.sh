#!/bin/sh
# Repair the generated usb-moded mode configs so developer_mode names the
# network interface the kernel ACTUALLY creates.
#
# WHY: /usr/libexec/ubports-usb-moded-configurator only autodetects when both
# RNDIS_IFNAME and RNDIS_FUNCTION are unset, and its first branch is:
#     if [ -d /sys/class/android_usb/android0 ]; then
#         export RNDIS_IFNAME="rndis0"     # hardcoded, detection skipped
# This OnePlus kernel still exposes legacy android_usb even though usb_moded
# drives configfs, so the name is pinned to "rndis0" -- which nothing creates.
# usb_moded then logs "network interface rndis0 does not exist", tears the
# working gadget down ~3 s after it appears, and falls back to mass storage.
#
# Setting the env vars in /etc/default/usb-moded.d/ does not help: that path is
# not part of Ubuntu Touch's writable-paths, so a file dropped there from
# /data never appears. Instead this runs as a LATE ExecStartPre (sorted after
# the configurator's drop-in) and rewrites what the configurator produced.
#
# The name is DETECTED, not assumed -- read from the configfs function itself.
set -u

G=/sys/kernel/config/usb_gadget
RUNTIME=/run/ubports-usb-moded-conf/dyn-modes
LOG=/userdata/rndis-ifname-fix.log

exec >>"$LOG" 2>&1
echo "=== $(date) ==="

[ -d "$RUNTIME" ] || { echo "no runtime config dir; configurator did not run"; exit 0; }

# Ask the kernel what it calls this function's netdev.
IFNAME=""
for func in rndis.usb0 ncm.usb0 ecm.usb0; do
    d="$G/g1/functions/$func"
    mkdir -p "$d" 2>/dev/null || continue
    if [ -r "$d/ifname" ]; then
        n=$(cat "$d/ifname" 2>/dev/null)
        # An unbound function may report empty or a placeholder; take a real name.
        case "$n" in
            ""|"rndis0") ;;
            *) IFNAME="$n"; FUNC="$func"; break ;;
        esac
    fi
done

# Fall back to the conventional f_rndis name if the probe told us nothing.
[ -z "$IFNAME" ] && { IFNAME=usb0; FUNC=rndis.usb0; }
echo "detected ifname=$IFNAME func=$FUNC"

for f in "$RUNTIME"/developer_mode.ini "$RUNTIME"/rndis.ini "$RUNTIME"/rndis_adb.ini; do
    [ -f "$f" ] || continue
    before=$(grep -E "^network_interface" "$f" 2>/dev/null)
    sed -i "s|^network_interface[[:space:]]*=.*|network_interface = $IFNAME|" "$f"
    after=$(grep -E "^network_interface" "$f" 2>/dev/null)
    echo "  $f: [$before] -> [$after]"
done
exit 0
