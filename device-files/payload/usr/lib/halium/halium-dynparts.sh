#!/bin/sh
# Map Android dynamic (logical) partitions out of "super" and mount /vendor
# before the Android LXC container starts.
#
# HARDENED: every step is best-effort. Nothing here may ever prevent the
# Ubuntu side from booting -- losing sshd means losing all remote access to
# the device, which has already cost hours once.
#
# instantnoodlep keeps vendor/product/odm/system_ext inside super
# (/dev/sda14). The Halium initramfs predates Android 10 and cannot map them,
# so /vendor is never mounted and Android init aborts with
#   "Failed to read /vendor/etc/selinux/plat_sepolicy_vers.txt"

exec 2>&1
set -x

# Kill switch: `touch /userdata/.no-dynparts` disables everything below.
[ -e /userdata/.no-dynparts ] && { echo "disabled by /userdata/.no-dynparts"; exit 0; }

SUPER=/dev/sda14
SLOT=$(grep -o "androidboot.slot_suffix=[a-z_]*" /proc/cmdline 2>/dev/null | cut -d= -f2)
[ -z "$SLOT" ] && SLOT="_a"

# 1. Map the logical partitions. timeout so a wedged dmsetup cannot hang boot.
if [ ! -e "/dev/mapper/dynpart-vendor${SLOT}" ]; then
    TABLE=$(timeout 30 /usr/lib/halium/bin/parse-android-dynparts "$SUPER" 2>/dev/null)

    # Drop the OnePlus my_* partitions from the table before creating anything.
    #
    # super holds ~24 logical partitions, 20 of which are OnePlus vendor bloat
    # (my_stock, my_heytap, my_bigball, my_carrier, my_manifest, my_preload...).
    # Creating a device-mapper node for each one makes udev probe it, and every
    # probe runs blkid against UFS at ~5 s a go. That is MINUTES of boot time
    # spent scanning partitions Halium never touches -- and it is what floods
    # kmsg with "ufshcd_ioctl: User buffer is NULL!".
    #
    # Worse, it delayed boot so far that usb_moded had not configured the USB
    # gadget yet, so the phone came up with no RNDIS and no way in. Filtering
    # here fixes the boot time AND the lost-access problem.
    #
    # --concise format is semicolon-separated records, each "name,uuid,...".
    if [ -n "$TABLE" ]; then
        TABLE=$(printf '%s' "$TABLE" | tr ';' '\n' \
            | grep -v '^dynpart-my_' \
            | paste -sd ';' -)
    fi

    [ -n "$TABLE" ] \
        && timeout 30 dmsetup create --concise "$TABLE" || echo "WARN: dynparts mapping failed"
fi


# binderfs must be mounted before the container starts. lxc bind-mounts
# /dev/binderfs into it; without this the container dies with
#   safe_mount: Failed to mount "/dev/binderfs" onto ".../rootfs/dev/binderfs"
# It is normally pulled in as a dependency of lxc-android-config, so it is
# missing whenever the container is started by hand.
mountpoint -q /dev/binderfs || {
    mkdir -p /dev/binderfs 2>/dev/null
    timeout 15 mount -t binder binder /dev/binderfs || echo "WARN: binderfs mount failed"
}

# 2. Android 11+ generates linker configs at runtime; /linkerconfig must be tmpfs.
mountpoint -q /android/linkerconfig \
    || timeout 15 mount -t tmpfs -o mode=755,size=8M tmpfs /android/linkerconfig \
    || echo "WARN: linkerconfig tmpfs failed"

# 3. Mount /vendor. Prefer our own Android 14 image; fall back to the stock
#    OxygenOS vendor in super (Android 12 / VNDK 30, badly skewed vs our API 34
#    system, but known to at least mount).
if ! mountpoint -q /android/vendor; then
    MOUNTED=0
    if [ -f /userdata/vendor-halium.img ]; then
        timeout 30 mount -o ro,loop /userdata/vendor-halium.img /android/vendor && MOUNTED=1 \
            || echo "WARN: halium vendor.img failed to mount, falling back to stock"
    fi
    if [ "$MOUNTED" = "0" ] && [ -e "/dev/mapper/dynpart-vendor${SLOT}" ]; then
        timeout 30 mount -o ro "/dev/mapper/dynpart-vendor${SLOT}" /android/vendor \
            || echo "WARN: stock vendor failed to mount too"
    fi
fi

# 4. Mount the Qualcomm firmware partitions.
#
# THIS IS WHAT WAS REBOOTING THE PHONE. The sensor DSP (SLPI) firmware is split
# into a header (slpi.mdt) plus segments (slpi.b00..b13). ueventd finds the
# .mdt, but the segments live on the *modem* partition -- a vfat volume that
# Qualcomm mounts at /vendor/firmware_mnt, and which the Halium initramfs never
# mounts. Without it, subsys-pil-tz logs
#     Falling back to syfs fallback for: slpi.b02 / slpi.b03
# the SLPI bring-up fails, and the SoC resets the WHOLE DEVICE a few seconds
# after the container starts. That looked for a long time like Android init
# rebooting us; it never was.
#
# adsp/cdsp came up fine because their segments are reachable; only the sensor
# island was starved. dsp_a additionally carries the SLPI userspace libs that
# the sensor HAL dlopen()s, so mount that too.
#
# Both are read-only and best-effort, like everything else here.
# BLUETOOTH FIRMWARE (added 2026-09-02) -- THE reason Bluetooth never worked.
# The QCA6390 ("Hastings") BT controller has no firmware in ROM; the HAL must
# download a patch + NVM over UART at every power-on. Those files live on their
# own `bluetooth` partition, which Halium never mounted, so the HAL powered the
# chip, clocked the UART, sent the init sequence and got NOTHING back:
#     UART Clock On / UART Clock Off
#     Actual last TX pkt len: 0 / Actual RX pkt len before SSR: 0
#     PC address of FW crash: 0x00 / SOC build ver: 0x00
#     data_handler: Killing daemon to recover as controller init failed
# which bluebinder then saw as "Bluetooth binder service failed / Remote has
# died". The HAL looks for them at /vendor/bt_firmware/image/ (confirmed by
# pulling android.hardware.bluetooth@1.0-impl-qti.so and reading its path
# strings; it wants htbtfw20.tlv + htnv20.bin, exactly what the partition
# holds). The mountpoint already exists in the stock vendor image, so mounting
# over it needs no write access to the read-only vendor partition.
# Verified: adapter goes UP RUNNING with real feature bits and a Qualcomm
# manufacturer ID, and a scan discovers real nearby devices with RSSI.
for spec in "modem${SLOT}:/android/vendor/firmware_mnt:vfat" \
            "bluetooth${SLOT}:/android/vendor/bt_firmware:vfat" \
            "dsp${SLOT}:/android/vendor/dsp:ext4"; do
    NAME=${spec%%:*}
    REST=${spec#*:}
    MP=${REST%%:*}
    FS=${REST#*:}
    DEV=/dev/block/by-name/$NAME
    [ -e "$DEV" ] || DEV=$(readlink -f "/dev/disk/by-partlabel/$NAME" 2>/dev/null)
    [ -e "$DEV" ] || { echo "WARN: no device for $NAME"; continue; }
    mountpoint -q "$MP" && continue
    mkdir -p "$MP" 2>/dev/null
    timeout 20 mount -t "$FS" -o ro "$DEV" "$MP" \
        || echo "WARN: $NAME ($FS) failed to mount at $MP"
done

# 5. Mount the persist partition.
#
# WHY: with SLPI fixed, the container got further and then reset the phone
# during WLAN bring-up. kmsg ended on:
#     cnss: QMI WLFW service connected
#     cnss: Calibration done is 0
#     cnss: Calibration duration not valid
#     cnss: Sending iova starting 0xa0000000
# WLAN calibration data (bdwlan/board files) lives on the persist partition.
# The stock vendor fstab says:
#     /dev/block/bootdevice/by-name/persist  /mnt/vendor/persist  ext4 ... wait
# ...and Halium never mounts it, so cnss finds no calibration and the WLAN
# subsystem takes the SoC down -- the same failure shape as the SLPI one.
#
# Mounted READ-WRITE, matching the stock vendor fstab. It was read-only here
# until 2026-09-02, on the reasoning that this partition holds factory
# calibration. That reasoning was wrong, and it cost every sensor on the phone:
# the SLPI sensor DSP reaches this partition through the sscrpcd fastRPC
# listener, and its registry sensor *writes* a scratch file,
#     /mnt/vendor/persist/sensors/registry/../temp.json
# on every registry read. Read-only turned that into 2938 consecutive
#     apps_std_fopen_with_env failed with 0x1e ... (Read-only file system)
# so the registry sensor never came up, and the sensor HAL logged
#     registry_sensor unavailable even after 35.15s (repeats: 80)
#     registry sensor not ready, not trying to get sensors list
#     get_sensors_list: num_sensors=0
# ...meaning ZERO sensors: no magnetometer, no ALS, no proximity, and no
# accelerometer for autorotate. It also cost ~40 s of boot, because sensorfwd
# blocks in getService() until the HAL finally gives up and registers empty.
# errors=remount-ro so a filesystem fault degrades instead of corrupting.
# A verified image backup lives in backup/persist-sda2-20260902.img.gz.
PERSIST=$(readlink -f /dev/disk/by-partlabel/persist 2>/dev/null)
if [ -n "$PERSIST" ] && [ -e "$PERSIST" ]; then
    # NOT under /android: that is the system image loop-mounted READ-ONLY
    # (/dev/loop1 ... ext4 ro), so no mountpoint can be created there. Use a
    # writable host path and let the container wrapper bind it in.
    mkdir -p /run/halium-persist 2>/dev/null
    mountpoint -q /run/halium-persist \
        || timeout 20 mount -t ext4 -o rw,nosuid,nodev,errors=remount-ro "$PERSIST" /run/halium-persist \
        || echo "WARN: persist failed to mount"
else
    echo "WARN: no persist partition found"
fi

# 6. Mount the real odm partition.
#
# THIS IS THE VINTF ROOT CAUSE. libvintf builds the DEVICE manifest from
# /vendor AND /odm. Our system image ships /odm/etc as a symlink:
#     /odm/etc -> /vendor/odm/etc
# and the stock vendor links back, so the path is a LOOP. hwservicemanager logs:
#     getDeviceHalManifest: status from fetching VINTF information: -40
#     -40 VINTF parse error: Cannot read /odm/etc/vintf/manifest.xml:
#         Too many symbolic links encountered
# One unreadable source fails the WHOLE fetch, so the device manifest comes back
# EMPTY and every vendor HAL is refused with "must be in VINTF manifest" --
# which is what stopped gralloc registering and killed the compositor.
#
# The odm partition is mapped by the dynparts table above but was never mounted.
# Mounting it replaces the loop with the real thing (it has etc/vintf/ with
# manifest, manifest_ssss.xml, telephony_manifest_*.xml).
#
# /android is the system image loop-mounted read-only so a mountpoint cannot be
# created -- but /android/odm already exists as a directory, so mounting over it
# is fine. Mount the container rootfs path too, mirroring how vendor is handled.
# OPT-IN ONLY: mounting odm fixes the VINTF -40 error but makes Android init
# SEGFAULT right after it loads /vendor/etc/selinux/vendor_file_contexts.
# Without odm mounted init loads only plat+vendor contexts and the container
# RUNS; with odm mounted it loads plat+system_ext+product+vendor and dies.
# Shadowing odm/etc/selinux (its Android 11 precompiled policy) does NOT help,
# so something else on that partition is the trigger -- still unidentified.
# Enable with:  touch /userdata/.mount-odm
if [ -e /userdata/.mount-odm ] && [ -e "/dev/mapper/dynpart-odm${SLOT}" ]; then
    for MP in /android/odm /var/lib/lxc/android/rootfs/odm; do
        [ -d "$MP" ] || continue
        mountpoint -q "$MP" && continue
        timeout 20 mount -o ro "/dev/mapper/dynpart-odm${SLOT}" "$MP" \
            || { echo "WARN: odm failed to mount at $MP"; continue; }

        # Shadow the odm sepolicy. The partition ships Android 11 PRECOMPILED
        # policy (precompiled_sepolicy*, *_sepolicy_and_mapping.sha256) built
        # against platform sepolicy 30.0. Our system is Android 14, and init
        # SEGFAULTS trying to use it -- right after it logs
        #     selinux: Loaded file context from: ... /vendor/etc/selinux/vendor_file_contexts
        # We mount odm for its etc/vintf manifests (which fix the -40 device
        # manifest error), not for its policy, so hide the policy directory.
        if [ -d "$MP/etc/selinux" ]; then
            timeout 10 mount -t tmpfs -o ro,size=4k tmpfs "$MP/etc/selinux" \
                || echo "WARN: could not shadow $MP/etc/selinux"
        fi
    done
else
    echo "odm not mounted (set /userdata/.mount-odm to enable; see note above)"
fi

# 6b. Build /userdata/odm-blobs and /userdata/vfw-upper on the phone itself.
#
# Step 7 below copies /userdata/odm-blobs into the /odm tmpfs and step 8 overlays
# /userdata/vfw-upper onto /vendor/firmware.  Until 2026-09-23 those two
# directories existed only on the development phone, curated by hand
# (device-files/populate-odm-blobs.sh plus several one-off additions), and the
# release zip's installer tried to stand in for them with a raw copy of the
# whole odm partition.  That is not equivalent: it brings in odm/etc/selinux
# (Android 11 precompiled policy, which crashes our Android init) and ~40
# OxygenOS .rc files, and lacks the assembled telephony VINTF manifest, the
# VNDK-30 radio/power/secure_element interface libraries and the swcodec APEX
# payload.  A clean install would therefore not have matched the phone the
# port was developed on.
#
# Every file of the development phone's odm-blobs was traced to its origin
# (PERFORMANCE-FINDINGS.md section 25) and is rebuilt here from exactly that:
#   * odm-blobs.list  -- 345 files byte-identical to this phone's own odm
#                        partition, + the 9 Goodix trustlet segments for
#                        vfw-upper.  Proprietary, so extracted, never shipped.
#   * etc/vintf/manifest.xml -- stock manifest_dsds.xml + telephony_manifest_
#                        dsds.xml merged (all <hal> entries, in that order);
#                        see step 7 for why it must be at that plain path.
#   * shipped/        -- the 14 VNDK-30 interface libraries
#                        (prebuilts/vndk/v30, Apache-2.0) and the swcodec APEX
#                        payload from our own Android build.
# The result is stamped with a hash of its inputs and rebuilt only when that
# changes (or is missing: an old zip's raw copy has no stamp).  The previous
# directory is kept as *.prev.  Disable with: touch /userdata/.no-odm-blobs-build
_ob=/usr/lib/halium/odm-blobs
_odmdev=/dev/mapper/dynpart-odm${SLOT}
if [ ! -e /userdata/.no-odm-blobs-build ] && [ -f "$_ob/odm-blobs.list" ] && [ -e "$_odmdev" ]; then
    _stamp=$( { echo "builder v2"; cat "$_ob/odm-blobs.list"; cd "$_ob/shipped" && find . -type f | LC_ALL=C sort | xargs md5sum; } | md5sum | cut -c1-16)
    if [ "$(cat /userdata/odm-blobs/.halium-odm-blobs 2>/dev/null)" != "$_stamp" ]; then
        echo "odm-blobs: building (stamp $_stamp)"
        _new=/userdata/odm-blobs.new; _vnew=/userdata/vfw-upper.new; _m=/run/halium-odm-src
        rm -rf "$_new" "$_vnew"; mkdir -p "$_new" "$_vnew" "$_m"
        if timeout 30 mount -t erofs -o ro "$_odmdev" "$_m"; then
            _miss=0
            while read -r _dst _src; do
                case "$_dst" in ''|'#'*) continue ;; esac
                [ -n "$_src" ] || _src=$_dst
                case "$_dst" in vfw/*) _out=$_vnew/${_dst#vfw/} ;; *) _out=$_new/$_dst ;; esac
                mkdir -p "${_out%/*}"
                # -L: a few odm files are absolute symlinks into /vendor
                # (etc/acdbdata/adsp_avs_config.acdb); store the content, as
                # the hand-built set did, so /odm does not depend on how
                # /vendor resolves in whichever namespace reads it.
                cp -pL "$_m/$_src" "$_out" 2>/dev/null || { _miss=$((_miss+1)); echo "odm-blobs: not on this odm: $_src"; }
            done < "$_ob/odm-blobs.list"
            _sku=dsds
            grep -q 'androidboot.opt_sim_count=1' /proc/cmdline 2>/dev/null && _sku=ssss
            if [ -f "$_m/etc/vintf/manifest_$_sku.xml" ]; then
                mkdir -p "$_new/etc/vintf"
                {
                    echo "<!-- ODM device manifest, assembled at boot by halium-dynparts.sh step 6b"
                    echo "     from this phone's odm/etc/vintf/manifest_$_sku.xml +"
                    echo "     telephony_manifest_$_sku.xml (stock selects them via"
                    echo "     ro.boot.product.hardware.sku, which is empty here). -->"
                    echo '<manifest version="1.0" type="device">'
                    for _x in "manifest_$_sku.xml" "telephony_manifest_$_sku.xml"; do
                        [ -f "$_m/etc/vintf/$_x" ] && sed -n '/<manifest[ >]/,/<\/manifest>/p' "$_m/etc/vintf/$_x" \
                            | sed '1d;$d'
                    done
                    echo '</manifest>'
                } > "$_new/etc/vintf/manifest.xml"
            else
                echo "odm-blobs: no manifest_$_sku.xml on this odm, telephony HALs will not register"
            fi
            umount "$_m"
            cp -a "$_ob/shipped/." "$_new/"
            chmod -R a+rX "$_new" "$_vnew"
            chmod 755 "$_new"/bin/hw/* "$_new"/bin/*.sh "$_new"/swcodec/bin/mediaswcodec 2>/dev/null
            echo "$_stamp" > "$_new/.halium-odm-blobs"
            for _d in odm-blobs vfw-upper; do
                rm -rf "/userdata/$_d.prev"
                [ -d "/userdata/$_d" ] && mv "/userdata/$_d" "/userdata/$_d.prev"
            done
            mv "$_new" /userdata/odm-blobs
            mv "$_vnew" /userdata/vfw-upper
            echo "odm-blobs: built, $_miss file(s) missing from this odm"
        else
            echo "WARN: odm-blobs: could not mount $_odmdev, keeping the existing odm-blobs"
            rm -rf "$_new" "$_vnew"
        fi
    fi
fi

# 7. Break the /odm symlink loop (THE VINTF ROOT CAUSE).
#
# Our system image ships /odm/etc -> /vendor/odm/etc and the stock vendor links
# back, so the path is a LOOP. libvintf builds the DEVICE manifest from /vendor
# AND /odm, and one unreadable source fails the WHOLE fetch:
#     getDeviceHalManifest: status from fetching VINTF information: -40
#     -40 VINTF parse error: Cannot read /odm/etc/vintf/manifest.xml:
#         Too many symbolic links encountered
# The manifest then comes back EMPTY and every vendor HAL is refused.
#
# Shadowing /odm with an empty tmpfs removes the loop. libvintf then finds no
# odm manifest at all, which is FINE (that source is optional) -- unlike an
# unreadable one, which is fatal. This exposes none of the odm partition, so it
# avoids the init segfault that mounting the real odm causes.
#
# PROVEN and now DEFAULT-ON. With this in place hwservicemanager logs
# "getDeviceHalManifest: Successfully processed VINTF information" instead of
# the -40 parse error, and the container starts normally. Disable with
# `touch /userdata/.no-shadow-odm` if it ever needs backing out.
if [ ! -e /userdata/.no-shadow-odm ]; then
    # The shadow is now WRITABLE and POPULATED with the OEM blobs recovered from
    # the stock OxygenOS odm image (see /userdata/odm-blobs). The real odm
    # partition still must NOT be mounted -- that makes Android init segfault --
    # but the blobs it carries are exactly what audio, cameras and cellular were
    # missing all along:
    #   lib64/libaudioEngineerTest.so             -> audio.primary.kona.so links
    #   lib64/vendor.oplus.hardware.radio@1.0.so  -> qcrild links
    #   lib64/camera/com.qti.sensormodule.*.bin   -> CamX enumerates the sensors
    #   lib64/camera/com.qti.tuned.*.bin          -> per-sensor tuning data
    #   lib64/camera/com.qti_instantnoodlep.*.so  -> per-sensor drivers
    #   etc/virtual_audio_policy_configuration.xml-> the xi:include the audio
    #                                                policy references
    #   etc/vintf/manifest.xml                    -> declares the telephony HALs
    #                                                (see below)
    #
    # etc/vintf IS now included (this reversed an earlier decision -- 2026-09-01).
    # The rule is NOT "no odm manifest"; it is "no UNREADABLE odm manifest". An
    # absent manifest is fine (the source is optional) and a VALID one is fine;
    # only an unreadable one is fatal, because libvintf fails the WHOLE device
    # manifest fetch and then every HAL is refused with "must be in VINTF
    # manifest" (that is the -40 error described above).
    #
    # etc/vintf/manifest.xml is assembled from the stock OxygenOS 13 odm files
    # manifest_dsds.xml + telephony_manifest_dsds.xml. Stock picks the dsds/ssss
    # variant via ro.boot.product.hardware.sku, which is EMPTY on this device, so
    # libvintf falls through to the plain /odm/etc/vintf/manifest.xml path -- that
    # is why the content is installed under that name. Verified additive with
    # `lshal --types=v`: device manifest 100 -> 133 entries, nothing lost.
    #
    # Do NOT reproduce stock's odm/etc/vintf/manifest/telephony_manifest.xml or
    # manifest_telephony_nfc.xml: both are symlinks into /proc/oplusVersion/,
    # which does not exist here, and a dangling symlink is exactly the fatal
    # unreadable-manifest case.
    #
    # Still deliberately EXCLUDES odm/etc/selinux: the odm sepolicy is Android 11
    # precompiled policy and loading it crashes Android init.
    if ! mountpoint -q /android/odm; then
        timeout 10 mount -t tmpfs -o size=320M,mode=0755 tmpfs /android/odm \
            || echo "WARN: could not shadow /android/odm"
    fi
    if mountpoint -q /android/odm && [ -d /userdata/odm-blobs ]; then
        mkdir -p /android/odm/lib64 /android/odm/etc /android/odm/firmware
        cp -a /userdata/odm-blobs/lib64/.    /android/odm/lib64/    2>/dev/null
        cp -a /userdata/odm-blobs/etc/.      /android/odm/etc/      2>/dev/null

        # bin/ and lib/ added 2026-09-02 for NFC and FINGERPRINT.
        #
        # Both HAL service binaries live on the odm partition, which is why NFC
        # had zero adapters and fingerprint never had a HAL at all:
        #   bin/hw/vendor.nxp.hardware.nfc@1.2-service                 (NXP SN100x)
        #   bin/hw/vendor.oplus.hardware.biometrics.fingerprint@2.1-service
        # Their libraries, the libhardware modules in lib64/hw
        # (fingerprint.19811_goodix9638_G6.default.so is the one this unit
        # selects -- it matches the G_OPTICAL_19811_G6 sensor), the Goodix
        # libgf_hal_*.so, the two VINTF manifest fragments and the service .rc
        # files are all staged into /userdata/odm-blobs by
        # device-files/populate-odm-blobs.sh.
        #
        # DELIBERATELY CURATED, not the whole partition: mounting the real odm
        # makes Android init segfault (see the note above), and we also do not
        # want init parsing the ~40 unrelated OxygenOS .rc files in
        # odm/etc/init, several of which reference binaries that do not exist
        # here. Only the two services' own .rc files are staged.
        if [ -d /userdata/odm-blobs/bin ]; then
            mkdir -p /android/odm/bin/hw
            cp -a /userdata/odm-blobs/bin/. /android/odm/bin/ 2>/dev/null
        fi
        if [ -d /userdata/odm-blobs/lib ]; then
            mkdir -p /android/odm/lib
            cp -a /userdata/odm-blobs/lib/. /android/odm/lib/ 2>/dev/null
        fi
        # swcodec/ = the com.android.media.swcodec APEX payload (27 MB), staged
        # under /odm ONLY because /odm is a path Android init can exec from --
        # init cannot see the real /apex path (different mount namespace), which
        # is why video was dead. See device-files/mediaswcodec.rc.
        # Disable with: touch /userdata/.no-swcodec
        if [ ! -e /userdata/.no-swcodec ] && [ -d /userdata/odm-blobs/swcodec ]; then
            mkdir -p /android/odm/swcodec
            cp -a /userdata/odm-blobs/swcodec/. /android/odm/swcodec/ 2>/dev/null
        fi
        # firmware/ carries tfa98xx.cnt, the container file for the two tfa98xx
        # smart speaker amps. Without it the codec has no supported-rate table
        # and rejects EVERY rate ("tfa98xx: invalid sample rate 48000"), so
        # pcm_open fails and nothing reaches the speaker. Android's ueventd is
        # the firmware loader here and searches /odm/firmware.
        cp -a /userdata/odm-blobs/firmware/. /android/odm/firmware/ 2>/dev/null
        chmod -R a+rX /android/odm 2>/dev/null
        # HAL services must be executable; cp -a from ext4 preserves the mode,
        # but be explicit so a bad stage cannot silently produce a non-runnable
        # binary that init then retries forever.
        chmod 755 /android/odm/bin/hw/* /android/odm/bin/*.sh 2>/dev/null
        chmod 755 /android/odm/swcodec/bin/mediaswcodec 2>/dev/null
    fi
    # MOBILE DATA: stub android.system.net.netd@1.1::INetd (added 2026-09-23).
    #
    # Qualcomm's netmgrd will not finish starting without an INetd HIDL
    # service: its main thread waits in NetmgrNetdClient::getInstance() until
    # one registers.  Halium ships no netd at all, so netmgrd hung there
    # forever, never posted its "is complete" event, and so never created
    # /dev/socket/netmgr/netmgr_connect_socket.  The data library inside the
    # RIL (libdsi_netctrl) must reach that socket before DSI counts as
    # initialised, so every data call failed with
    #     RILQ: qcril_data_request_setup_data_call: unable to get dsi hndl
    # Found with `debuggerd -b <netmgrd pid>` inside the container.
    #
    # vendor/halium/config/halium.mk already asks for a module of exactly this
    # name, but no source for it exists in the halium-14.0 tree (the Android
    # build runs with ALLOW_MISSING_DEPENDENCIES, so the gap was silent).  Ours
    # is device-files/netd-stub/, built by device-files/build-netd-stub.sh.  It
    # is our own code, not an OEM blob, so it ships in the payload and is
    # staged here rather than via /userdata/odm-blobs.  /odm/etc/init is read by
    # Android init (like the NFC and fingerprint services above), and the
    # framework VINTF manifest already declares @1.1::INetd/default.
    #
    # Verified 2026-09-23: with the stub registered, netmgrd logs
    # "netmgr_unix_listener_init(): Listening to UNIX server socket", the RIL
    # logs "update dsi_inited to TRUE", and ofono brings up rmnet_data0 with a
    # carrier address; with wifi off, DNS, ping and HTTP all go over it.
    # (An earlier theory -- netmgr_listen_ev_proto / TIPC -- was wrong and has
    # been removed; see PERFORMANCE-FINDINGS.md section 24.)
    # Disable with: touch /userdata/.no-netd-stub
    if [ ! -e /userdata/.no-netd-stub ] && mountpoint -q /android/odm \
       && [ -f /usr/lib/halium/netd-stub/android.system.net.netd@1.1-service.stub ]; then
        mkdir -p /android/odm/bin/hw /android/odm/etc/init
        cp /usr/lib/halium/netd-stub/android.system.net.netd@1.1-service.stub \
           /android/odm/bin/hw/ 2>/dev/null
        cp /usr/lib/halium/netd-stub/android.system.net.netd@1.1-service.stub.rc \
           /android/odm/etc/init/ 2>/dev/null
        chmod 755 /android/odm/bin/hw/android.system.net.netd@1.1-service.stub 2>/dev/null
        chmod 644 /android/odm/etc/init/android.system.net.netd@1.1-service.stub.rc 2>/dev/null
    fi
    # PRODUCT IDENTITY: /odm/etc/build.prop (added 2026-10-02).
    #
    # The stock vendor partition is Qualcomm's generic kona build, so its
    # build.prop names the reference board, not the phone:
    #     ro.product.vendor.manufacturer=QUALCOMM
    #     ro.product.vendor.model=Kona for arm64
    # That name leaked into everything that reads it: Waydroid copies
    # ro.product.vendor.* into its container at `waydroid init` (Settings >
    # About phone showed "Kona for arm64"), ubports-usb-moded-configurator uses
    # them as the USB device name a PC shows, and mtp-server uses
    # ro.product.model, which Android init derives from them.
    #
    # On OxygenOS the correction comes from odm: odm/etc/build.prop imports
    # my_manifest/build.prop, which overrides ro.product.vendor.* with
    # OnePlus / IN2023. Halium mounts neither partition. Android init reads
    # /odm/etc/build.prop after /vendor/build.prop, so the same mechanism works
    # here, and nothing else is put in that file.
    #
    # Only brand, manufacturer and model change. ro.product.vendor.device stays
    # "kona": device-info picks its config by it (and repowerd through
    # device-info), and biometryd reads it too.
    # Disable with: touch /userdata/.no-odm-identity
    if [ ! -e /userdata/.no-odm-identity ] && mountpoint -q /android/odm \
       && [ -f /usr/lib/halium/odm-build.prop ]; then
        mkdir -p /android/odm/etc
        cp /usr/lib/halium/odm-build.prop /android/odm/etc/build.prop 2>/dev/null
        chmod 644 /android/odm/etc/build.prop 2>/dev/null
    fi
    # Share the SAME tmpfs with the container instead of a second copy.
    if [ -d /var/lib/lxc/android/rootfs/odm ] && ! mountpoint -q /var/lib/lxc/android/rootfs/odm; then
        timeout 10 mount --bind /android/odm /var/lib/lxc/android/rootfs/odm \
            || echo "WARN: could not bind odm into the container"
    fi
fi

# 8. Expose the two libraries libhybris cannot otherwise find.
#
# libhybris' linker searches /system/lib64, /vendor/lib64, /odm/lib64 and the
# apex dirs -- but NOT /vendor/lib64/egl, where eglSubDriverAndroid.so lives.
# And libminisf (the fake-SurfaceFlinger shim, built from vendor/halium/
# droidmedia) is not on the vendor image at all. Without them:
#     library "eglSubDriverAndroid.so" not found
#     android/server: Device does not have libminisf ... not starting fake
#         SurfaceFlinger service
# and the shell never gets a usable surface -- the compositor sits on the
# spinner forever.
#
# An overlayfs on /android/vendor/lib64 puts BOTH at the top level, where the
# linker already looks. This must be re-done every boot; it is a mount, not a
# file change.
#
# CAUTION: expose ONLY these two. Overlaying the whole egl/ directory makes the
# EGL loader pick the wrong driver and the GPU silently downgrades to
# "Adreno (TM) 4XX / ES 3.0" instead of the correct "Adreno (TM) 650 / ES 3.2".
if [ -d /android/vendor/lib64 ] && ! mountpoint -q /android/vendor/lib64; then
    rm -rf /userdata/vlib-upper /userdata/vlib-work
    mkdir -p /userdata/vlib-upper /userdata/vlib-work
    cp /android/vendor/lib64/egl/eglSubDriverAndroid.so /userdata/vlib-upper/ 2>/dev/null
    cp /usr/lib/halium/hybris-libs/libminisf.so             /userdata/vlib-upper/ 2>/dev/null

    # HIDL/AIDL interface libs the stock Android 12/13 vendor needs but our
    # Android 14 system no longer ships. Each fixes a vendor service that was
    # dying at the linker in a permanent restart storm. Interface libs only;
    # the graphics stack does not load these.
    for _l in /usr/lib/halium/hidl-libs/*.so; do
        [ -e "$_l" ] && cp "$_l" /userdata/vlib-upper/ 2>/dev/null
    done

    # CAMERA: stub replacing vendor.qti.hardware.camera.postproc@1.0-service-impl.so.
    # Without it vendor.camera-provider-2-4 aborts on every start (~every 5 s) and
    # NO camera is ever enumerated:
    #     Abort message: 'Binder threadpool cannot be shrunk after starting'
    # The provider's main() configures the binder threadpool, then Qualcomm's CHI
    # extension reconfigures it smaller; Android 14's libhidlbase made that fatal,
    # and this Android 11-era vendor blob predates the assertion. The real library
    # exports only RegisterIPostProcService() and __cfi_check, and chi.override
    # pulls it in via DT_NEEDED, so a stub exporting both satisfies the loader.
    # __cfi_check MUST stay 4096-aligned or bionic refuses to dlopen chi.override
    # and CamX silently falls back to a path that finds ZERO cameras.
    # Cost: Qualcomm's camera post-processing offload is not registered.
    # This has to be re-done every boot because this block wipes vlib-upper above.
    # Disable with: touch /userdata/.no-camera-postproc-stub
    # Original blob: /userdata/camera-backup/
    if [ ! -e /userdata/.no-camera-postproc-stub ] && [ -f /usr/lib/halium/bin/postproc-stub.so ]; then
        cp /usr/lib/halium/bin/postproc-stub.so \
           "/userdata/vlib-upper/vendor.qti.hardware.camera.postproc@1.0-service-impl.so" \
           2>/dev/null
    fi

    # Bluetooth HIDL interface library (added 2026-09-02).
    #
    # THE THIRD BLUETOOTH BLOCKER. /vendor/bin/hw/android.hardware.bluetooth@1.0-service-qti
    # is an Android-11-era vendor blob and needs android.hardware.bluetooth@1.0.so,
    # which Android 14's system image no longer ships. Result:
    #     CANNOT LINK EXECUTABLE ".../android.hardware.bluetooth@1.0-service-qti":
    #     library "android.hardware.bluetooth@1.0.so" not found
    # so the HAL died at exec, every 5 s, forever -- which is why it ended up in
    # the quiet-android sweeper in the first place.
    #
    # Our own build produces the correct VNDK-30 vendor variant of this library
    # (out/target/product/instantnoodlep/vendor/lib64/), it was just never
    # installed because the device runs the STOCK vendor partition. Dropping it
    # in makes the HAL start and register android.hardware.bluetooth@1.0::
    # IBluetoothHci/default, and bluebinder then logs "Connected to HIDL
    # bluetooth service". Safe under project rule 8: this is not a library the
    # graphics stack loads.
    # Disable with: touch /userdata/.no-bluetooth-hidl-lib
    if [ ! -e /userdata/.no-bluetooth-hidl-lib ] && \
       [ -f "/usr/lib/halium/android.hardware.bluetooth@1.0.so" ]; then
        cp "/usr/lib/halium/android.hardware.bluetooth@1.0.so" \
           "/userdata/vlib-upper/android.hardware.bluetooth@1.0.so" \
           2>/dev/null
    fi

    # USB HIDL interface libraries (added 2026-09-02). Same defect as the
    # Bluetooth one: /vendor/bin/hw/android.hardware.usb@1.2-service-qti needs
    # android.hardware.usb@1.0/1.1/1.2.so, Android 14 ships none of them, so it
    # died at exec every 5 s forever -- this was the ONE service deliberately
    # left crash-looping, and the reason was never investigated until now.
    # Our build produces all three; they were simply never installed because
    # the device runs the stock vendor partition.
    #
    # Project rule 7 says leave USB alone unless the owner is present: honoured
    # by doing the live test over WiFi with the gadget state recorded first.
    # Measured before AND after starting the HAL: UDC still bound to
    # a600000.dwc3, functions still mass_storage.usb0 + mtp.mtp + rndis.usb0,
    # usb0 kept its address, and SSH over USB kept working. The HAL manages the
    # Type-C port state machine, NOT the gadget config, so it does not fight
    # usb_moded. Registers IUsb 1.0/1.1/1.2.
    # Disable with: touch /userdata/.no-usb-hidl-libs
    if [ ! -e /userdata/.no-usb-hidl-libs ]; then
        for _u in 1.0 1.1 1.2; do
            [ -f "/usr/lib/halium/android.hardware.usb@${_u}.so" ] && \
                cp "/usr/lib/halium/android.hardware.usb@${_u}.so" \
                   "/userdata/vlib-upper/android.hardware.usb@${_u}.so" \
                   2>/dev/null
        done
    fi

    # ICU. These ARE mapped by lomiri-system-compositor, so they could in
    # principle shadow the graphics stack -- but the copies are byte-identical
    # to the device's own /android/apex/com.android.i18n/lib64, and a cold-boot
    # test with them applied kept the compositor and greeter healthy.
    # DEFAULT-ON since 2026-09-23: it was opt-in (/userdata/.enable-icu-libs),
    # but the development phone has run with it for weeks and the release has
    # to match that phone.  Disable with: touch /userdata/.no-icu-libs
    if [ ! -e /userdata/.no-icu-libs ]; then
        for _l in /usr/lib/halium/hidl-libs-icu/*.so; do
            [ -e "$_l" ] && cp "$_l" /userdata/vlib-upper/ 2>/dev/null
        done
    fi
    # NOTE: do NOT put the Android 14 HIDL interface libs here. This overlay is
    # on /android/vendor/lib64, which libhybris on the UBUNTU side also searches
    # (that is why exposing eglSubDriverAndroid.so here works at all). Dropping
    # Android 14 libs -- libandroidicu.so in particular -- into a path libhybris
    # scans broke the graphics stack and the phone stopped enumerating on USB.
    # They are injected into the CONTAINER ONLY, further below.
    timeout 20 mount -t overlay overlay \
        -o lowerdir=/android/vendor/lib64,upperdir=/userdata/vlib-upper,workdir=/userdata/vlib-work \
        /android/vendor/lib64 \
        || echo "WARN: vendor/lib64 overlay failed"
fi

# 8b. FINGERPRINT TRUSTLET: overlay /vendor/firmware (added 2026-09-02).
#
# The Goodix HAL asks QSEECom to load the secure-world trustlet for this
# sensor, and libQSEEComAPI searches exactly two directories:
#     Error::Cannot open the file /firmware/image/gfp9638.mdt errno = 2
#     Error::Cannot open the file /vendor/firmware/gfp9638.mdt errno = 2
#     Can't open fingerprint methods, error: 1002
# 1002 was the wall this port sat behind for a long time and it was read as a
# secure-world/permission problem. It was not. The trustlet simply is not on
# the vendor partition: it ships at /odm/vendor/firmware/gfp9638.{mdt,b00..b07}
# on the odm partition, which we do not mount.
#
# /android/vendor is the stock erofs vendor image (read-only), so the files are
# staged on /userdata and overlaid in, exactly like vendor/lib64 above. With
# them present the TA loads, error 1002 disappears and the HAL reaches
# "[GF_HAL][FingerprintCore] [init] set notifyFingerprintCmd callback".
# Disable with: touch /userdata/.no-fp-firmware
if [ ! -e /userdata/.no-fp-firmware ] && [ -d /userdata/vfw-upper ] \
   && [ -n "$(ls -A /userdata/vfw-upper 2>/dev/null)" ]; then
    mkdir -p /userdata/vfw-work
    if ! mountpoint -q /android/vendor/firmware; then
        timeout 20 mount -t overlay overlay-vfw \
            -o lowerdir=/android/vendor/firmware,upperdir=/userdata/vfw-upper,workdir=/userdata/vfw-work \
            /android/vendor/firmware \
            || echo "WARN: vendor/firmware overlay failed"
    fi
fi

# 9. Let the SHELL talk to the system compositor over D-Bus.
#
# /etc/dbus-1/system.d/com.lomiri.SystemCompositor.conf grants send access to
# the Display/Input/PowerButton/UserActivity interfaces ONLY to user="root".
# But lomiri-system-compositor runs as root while the SHELL runs as phablet
# (uid 32011), so every call it makes is refused:
#     dbus-daemon: Rejected send message, 1 matched rules;
#       sender (uid=32011 comm="lomiri --mode=full-greeter")
#       interface="com.lomiri.SystemCompositor.Input" member="setMouseCursorSpeed"
# Those interfaces exist so the shell can drive the compositor, so this blocks
# the shell from ever taking over the display.
#
# /etc/dbus-1/system.d is read-only, hence the overlay. NOTE the policy must use
# the NUMERIC uid: phablet lives in extrausers, not /etc/passwd, and a
# user="phablet" rule does NOT match (verified -- rejections stayed at 24/min
# with the name, dropped to 0 with 32011).
if [ -f /usr/lib/halium/com.lomiri.SystemCompositor.phablet.conf ] \
   && ! mountpoint -q /etc/dbus-1/system.d; then
    rm -rf /userdata/dbus-upper /userdata/dbus-work
    mkdir -p /userdata/dbus-upper /userdata/dbus-work
    cp /usr/lib/halium/com.lomiri.SystemCompositor.phablet.conf /userdata/dbus-upper/
    timeout 20 mount -t overlay overlay \
        -o lowerdir=/etc/dbus-1/system.d,upperdir=/userdata/dbus-upper,workdir=/userdata/dbus-work \
        /etc/dbus-1/system.d \
        || echo "WARN: dbus policy overlay failed"

    # dbus reads its policy at STARTUP, and it starts ~9 s before this script
    # runs (measured: dbus 15:04:45, dynparts 15:04:54). So the overlay lands
    # too late and the shell keeps getting rejected. Ask dbus to re-read its
    # config -- ReloadConfig does NOT restart the bus, so logind keeps its name.
    # (Restarting dbus instead makes logind lose org.freedesktop.login1 forever:
    #  "Failed to activate service 'org.freedesktop.login1': timed out", ~20 s of
    #  device unresponsiveness, and systemctl reboot stops working.)
    timeout 15 dbus-send --system --print-reply --dest=org.freedesktop.DBus \
        / org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1 \
        && echo "dbus policy reloaded" || echo "WARN: dbus ReloadConfig failed"
fi

# 10. Give the CONTAINER (only) the HIDL libs the Android 11 vendor needs.
#
# The vendor HALs link against interface libraries an Android 14 system no
# longer ships, e.g.
#   CANNOT LINK EXECUTABLE ".../android.hardware.bluetooth@1.0-service-qti":
#     library "android.hardware.bluetooth@1.0.so" not found
# ...which is why bluebinder loops forever on "Waiting for bluetooth service".
# Our build produces them; they are staged in /usr/lib/halium/hybris-libs/vendorlibs.
#
# CRITICAL: overlay the CONTAINER'S vendor path only
# (/var/lib/lxc/android/rootfs/vendor/lib64), NOT /android/vendor/lib64 --
# the latter is shared with libhybris on the Ubuntu side, and putting Android 14
# libs there breaks EGL and the whole UI.
# The previous attempt put these libs in the SHARED /android/vendor/lib64
# overlay and bricked the boot (libhybris picked them up). This container-only
# version is the corrected approach.  It was opt-in
# (/userdata/.container-hidl-libs) while being validated; the development phone
# has run with it for weeks, so since 2026-09-23 it is DEFAULT-ON to make a
# clean install match that phone.  Disable with: touch /userdata/.no-container-hidl-libs
CROOT=/var/lib/lxc/android/rootfs
if [ ! -e /userdata/.no-container-hidl-libs ] \
   && [ -d "$CROOT/vendor/lib64" ] && [ -d /usr/lib/halium/hybris-libs/vendorlibs ] \
   && ! mountpoint -q "$CROOT/vendor/lib64"; then
    rm -rf /userdata/clib-upper /userdata/clib-work
    mkdir -p /userdata/clib-upper /userdata/clib-work
    cp /usr/lib/halium/hybris-libs/vendorlibs/*.so /userdata/clib-upper/ 2>/dev/null
    # libdpmframework.so is Qualcomm's (LineageOS vendor tree). Our system
    # image already carries it in system_ext, where the vendor namespace
    # cannot load it, so it is copied from there rather than shipped twice.
    cp /android/system/system_ext/lib64/libdpmframework.so /userdata/clib-upper/ 2>/dev/null \
        || echo "WARN: libdpmframework.so not found in the system image"
    timeout 20 mount -t overlay overlay \
        -o lowerdir="$CROOT/vendor/lib64",upperdir=/userdata/clib-upper,workdir=/userdata/clib-work \
        "$CROOT/vendor/lib64" \
        || echo "WARN: container vendor/lib64 overlay failed"
fi

# 11. Point ofono at the modem over hwbinder instead of the legacy RIL socket.
#
# The stock /etc/ofono/ril_subscription.conf says:
#     [ril_0]
#     socket=/dev/socket/rild
# but this vendor's qcrild is a HIDL service: it serves
# android.hardware.radio@1.5::IRadio/slot1 over /dev/hwbinder and NEVER creates
# /dev/socket/rild.  So ofono found no transport and listed no modems, even with
# the RIL binder transport plugin loaded.  Changing that one line to
#     transport=binder
# makes ofono use rilbinderplugin.so (libgbinder-radio speaks IRadio @1.0-@1.5,
# defaults dev=/dev/hwbinder name=slot1) and the modem appears:
#     [ /ril_0 ] Online=1 Powered=1 Type=hardware  Revision=Q_V1_P14
#
# / is a read-only ext4 loop image and /etc/ofono is NOT in
# /etc/system-image/writable-paths, so the file cannot be edited in place.  A
# bind mount over the single file is the surgical fix; it leaves the rootfs
# image untouched (so OTA updates still work), unlike remounting / rw.
#
# Requires the telephony HALs to be registered, which needs
# /odm/etc/vintf/manifest.xml from step 7 -- ofono alone is not enough.
# Back out with: touch /userdata/.no-ofono-binder
if [ ! -e /userdata/.no-ofono-binder ] \
   && [ -f /usr/lib/halium/ofono/ril_subscription.conf ] \
   && [ -f /etc/ofono/ril_subscription.conf ] \
   && ! mountpoint -q /etc/ofono/ril_subscription.conf; then
    timeout 10 mount --bind /usr/lib/halium/ofono/ril_subscription.conf \
        /etc/ofono/ril_subscription.conf \
        || echo "WARN: could not bind the ofono ril_subscription.conf"
fi

# Always succeed.
exit 0
