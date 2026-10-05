#!/bin/sh
# Add adb to the USB gadget WITHOUT losing the RNDIS network.
#
# Ubuntu Touch already ships the whole adb stack (/usr/bin/adbd from UBports,
# adbd.service, adbd.socket, adbd-prepare.service). It is not active here only
# because the gadget usb-moded builds for developer_mode links rndis.usb0 alone.
#
# WHY NOT usb-moded's own rndis_adb mode
# There IS an rndis_adb mode and it does give both -- but its .ini sets
# "network = 0 # Will be dealt by NetworkManager" and dhcp_server = 0, so
# NetworkManager takes usb0 and assigns its shared-connection address
# 10.42.0.1/24 instead of the 10.15.19.82/24 that developer_mode's udhcpd sets
# up. The host side is statically 10.15.19.100/24, so the subnets stop matching
# and the USB SSH path -- which deploy-system.sh depends on -- dies. Staying in
# developer_mode and adding the adb function alongside keeps both.
#
# WHY adbd's OWN auth works here but Android's does not
# Android 14's adbd (in /apex/com.android.adbd) delegates key checks to the
# framework over /dev/socket/adbd and fails with "Failed to get adbd socket"
# because there is no system_server; it then prompts forever and every host
# stays "unauthorized". UT's adbd.socket PROVIDES /dev/socket/adbd, and its
# adbd honours /data/misc/adb/adb_keys. Use UT's, never the APEX one.
#
# ORDERING TRAP: the functionfs filesystem type is registered LAZILY, when the
# first ffs instance is created (f_fs.c: _ffs_alloc_dev -> functionfs_init ->
# register_filesystem). Mounting before "mkdir functions/ffs.adb" fails with
# ENODEV and looks exactly like a kernel with no functionfs support.
#
# Kill switch: touch /userdata/.no-adb

G=/sys/kernel/config/usb_gadget/g1
UDC=a600000.dwc3
LOG=/userdata/adb-compose.log

[ -f /userdata/.no-adb ] && exit 0
log() { echo "$(date +%H:%M:%S) $*" >> "$LOG"; }

# wait for usb-moded to have finished building the gadget
i=0
while [ $i -lt 30 ]; do
    i=$((i+1)); sleep 5
    [ -d "$G/configs/c.1" ] && [ -n "$(cat $G/UDC 2>/dev/null)" ] && break
done
if [ ! -d "$G/configs/c.1" ]; then log "no gadget after $i tries; giving up"; exit 0; fi

# already composed?
if [ -L "$G/configs/c.1/ffs.adb" ]; then log "ffs.adb already linked"; exit 0; fi

log "composing rndis+adb (was: $(find $G/configs/c.1 -maxdepth 1 -type l -printf '%f ' 2>/dev/null))"
mkdir -p $G/functions/ffs.adb 2>/dev/null      # registers functionfs
systemctl start adbd.socket >/dev/null 2>&1     # provides /dev/socket/adbd
systemctl start adbd.service >/dev/null 2>&1    # runs adbd-prepare (mounts ffs)

echo "" > $G/UDC 2>/dev/null                    # unbind; USB drops here
ln -sfn $G/functions/ffs.adb $G/configs/c.1/ffs.adb 2>/dev/null
systemctl restart adbd.service >/dev/null 2>&1  # adbd must claim ep0 before bind
sleep 4

j=0
while [ $j -lt 4 ]; do
    j=$((j+1))
    echo "$UDC" > $G/UDC 2>/dev/null
    sleep 2
    [ -n "$(cat $G/UDC 2>/dev/null)" ] && break
    sleep 3
done

if [ -z "$(cat $G/UDC 2>/dev/null)" ]; then
    log "REBIND FAILED after $j tries; restoring rndis-only so USB comes back"
    rm -f $G/configs/c.1/ffs.adb
    echo "$UDC" > $G/UDC 2>/dev/null
    log "restored, UDC=$(cat $G/UDC 2>/dev/null)"
    exit 0
fi
log "ok: UDC=$(cat $G/UDC) links=$(find $G/configs/c.1 -maxdepth 1 -type l -printf '%f ' 2>/dev/null)"
exit 0
