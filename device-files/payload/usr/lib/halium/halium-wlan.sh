#!/bin/sh
# Load the QCA6390 WLAN driver on the OnePlus 8 Pro (instantnoodlep).
#
# The stock vendor wlan.ko cannot be used: its vermagic is 4.19.157-perf+ and
# the kernel enforces CONFIG_MODULE_SIG_FORCE.  We build qcacld-3.0 in-tree
# (CONFIG_QCA_CLD_WLAN=m) so the module matches vermagic and is signed with
# the kernel's own key.
#
# Never fail hard: a WLAN problem must not hold up boot.
MOD=/usr/lib/halium/modules/wlan.ko
# The firmware comes from this phone's own partitions, never from the port
# (added 2026-10-05; until then the boot image carried copies taken from the
# development phone):
#   qca6390/   the modem partition's image/qca6390 (amss20.bin, m3.bin,
#              Data.msc and the bdwlan.* board files), mounted by
#              halium-dynparts.sh step 4
#   wlan/qca_cld/WCNSS_qcom_cfg.ini and tfa98xx.cnt
#              odm-blobs, extracted from the odm partition by halium-dynparts.sh
#              step 6b (see odm-blobs.list)
MODEMFW=/android/vendor/firmware_mnt/image/qca6390
ODMBLOBS=/userdata/odm-blobs

[ -f "$MOD" ] || exit 0

# Wait (bounded) for the Android container.  If a firmware file is not found on
# the direct path, the kernel falls back to the container's ueventd helper; with
# the container absent that fallback can stall for a very long time inside the
# insmod/ON write.  This used to happen while the unit still gated
# network-pre.target, which wedged an entire boot.  The unit no longer gates
# anything, but waiting here also just makes WiFi come up more reliably.
i=0
while [ $i -lt 60 ]; do
    state=$(lxc-info -n android -s 2>/dev/null | awk '{print $2}')
    [ "$state" = "RUNNING" ] && break
    i=$((i+1)); sleep 1
done

# Point the kernel firmware loader at a staged copy of the QCA6390 blobs.
# Without this the driver needs the Android container's ueventd, and the
# qcacld config INI is not where ueventd looks anyway: stock keeps it as
# /odm/vendor/etc/wifi/WCNSS_qcom_cfg.ini but the driver asks for
# wlan/qca_cld/WCNSS_qcom_cfg.ini, so we stage it under that name.
#
# The loader path is a RUNTIME copy in /run so that wlan_mac.bin can be written
# per phone.  Until 2026-09-23 the payload shipped a wlan_mac.bin holding the
# development phone's MAC, i.e. every phone installing the release would have
# come up with the SAME wifi MAC.  Now, in order of preference:
#   1. the factory MAC the phone was provisioned with, on persist.  On this
#      model it is qca6390/wlan_mac.bin (the top-level wlan_mac.bin is an empty
#      placeholder -- which is why earlier work wrongly concluded the
#      development phone had never been provisioned; its qca6390 copy holds
#      OnePlus's 5C:17:CF address, dated 2022).
#   2. otherwise, a stable MAC derived from this phone's own serials:
#      sha256("instantnoodlep:<androidboot.serialno>:<soc0 serial>"), first
#      three bytes after the Qualcomm OUI 00:03:7f, low two bits cleared so the
#      four interfaces get consecutive addresses.  (The development phone ran
#      on 00:03:7f:f2:a7:98 from this recipe before its factory MAC was found.)
RUNFW=/run/halium-firmware
# The container is normally up long after both sources exist, but never stage
# a half-populated directory: wait (bounded) for them.
i=0
while [ $i -lt 30 ] && { [ ! -f "$MODEMFW/amss20.bin" ] \
        || [ ! -f "$ODMBLOBS/wlan/WCNSS_qcom_cfg.ini" ]; }; do
    i=$((i+1)); sleep 1
done
[ -f "$MODEMFW/amss20.bin" ] || echo "halium-wlan: no $MODEMFW/amss20.bin (modem partition not mounted?)" > /dev/kmsg
[ -f "$ODMBLOBS/wlan/WCNSS_qcom_cfg.ini" ] || echo "halium-wlan: no WCNSS_qcom_cfg.ini in $ODMBLOBS" > /dev/kmsg
if [ -d "$MODEMFW" ] && [ -w /sys/module/firmware_class/parameters/path ]; then
    rm -rf "$RUNFW"; mkdir -p "$RUNFW/qca6390" "$RUNFW/wlan/qca_cld"
    cp "$MODEMFW"/* "$RUNFW/qca6390/" 2>/dev/null
    cp "$ODMBLOBS/wlan/WCNSS_qcom_cfg.ini" "$RUNFW/wlan/qca_cld/" 2>/dev/null
    # tfa98xx.cnt (speaker amps): ueventd serves it from /odm/firmware, but a
    # request made after the path below is set looks here first.
    cp "$ODMBLOBS/firmware/tfa98xx.cnt" "$RUNFW/" 2>/dev/null
    MACF=$RUNFW/wlan/qca_cld/wlan_mac.bin
    rm -f "$MACF"; mkdir -p "${MACF%/*}"
    for p in /run/halium-persist/qca6390/wlan_mac.bin /run/halium-persist/wlan_mac.bin; do
        if [ -s "$p" ] && grep -q '^Intf0MacAddress=[0-9A-Fa-f]\{12\}' "$p"; then
            cp "$p" "$MACF"; break
        fi
    done
    if [ ! -s "$MACF" ]; then
        SN=$(grep -o 'androidboot.serialno=[^ ]*' /proc/cmdline | cut -d= -f2)
        SOC=$(cat /sys/devices/soc0/serial_number 2>/dev/null)
        H=$(printf 'instantnoodlep:%s:%s' "$SN" "$SOC" | sha256sum | cut -c1-6)
        B=$(( 0x${H#????} & 0xfc ))
        {
            for i in 0 1 2 3; do
                printf 'Intf%dMacAddress=00037F%s%02X\n' $i "$(echo "${H%??}" | tr a-f A-F)" $((B + i))
            done
            echo END
        } > "$MACF"
    fi
    printf '%s' "$RUNFW" > /sys/module/firmware_class/parameters/path 2>/dev/null
fi

lsmod 2>/dev/null | grep -q '^wlan ' || insmod "$MOD" 2>/dev/null || exit 0

# qcacld-3.0 defers creating wlan0 until userspace writes "ON" to /dev/wlan
# (wlan_hdd_state_ctrl_param_write -> hdd_driver_load).  Loading the module
# alone only registers the char device.
i=0
while [ $i -lt 20 ] && [ ! -c /dev/wlan ]; do i=$((i+1)); sleep 1; done
if [ ! -c /dev/wlan ]; then
    major=$(awk '$2=="wlan"{print $1}' /proc/devices 2>/dev/null)
    [ -n "$major" ] && mknod /dev/wlan c "$major" 0 2>/dev/null && chmod 600 /dev/wlan
fi
[ -c /dev/wlan ] && printf 'ON' > /dev/wlan 2>/dev/null
exit 0
