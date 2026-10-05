#!/bin/sh
# Give Waydroid its own binder domain.
#
# WHY THIS IS NEEDED
# ------------------
# waydroid/tools/helpers/drivers.py:setupBinderNodes() takes the non-MAINLINE
# branch on a Halium device and searches BINDER_DRIVERS[:-1], i.e.
#   anbox-binder / puddlejumper / bonder      -- deliberately EXCLUDING "binder"
# and the matching vnd*/hw* lists.  The exclusion is on purpose: /dev/binder,
# /dev/hwbinder and /dev/vndbinder already belong to the Halium HAL container,
# and Waydroid's own Android userspace must not share a binder context with it.
# With no separate nodes present, init dies with
#   OSError: Binder node "binder" for waydroid not found
#
# This kernel has binderfs (CONFIG_ANDROID_BINDERFS) already mounted on
# /dev/binderfs with a binder-control node, so extra contexts can simply be
# allocated at runtime -- no module parameter and no kernel rebuild needed.
set -e
BFS=/dev/binderfs

# --- 1. xt_CHECKSUM -------------------------------------------------------
# waydroid-net.sh (start_iptables) ends with
#   iptables -t mangle -A POSTROUTING -o waydroid0 -p udp --dport 68 \
#            -j CHECKSUM --checksum-fill
# the lxc-net DHCP checksum fixup.  The stock kona-perf defconfig leaves
# CONFIG_NETFILTER_XT_TARGET_CHECKSUM unset, so that rule fails, and because
# start() runs under "set -e" with a cleanup trap the whole network setup is
# rolled back and `waydroid session start` dies with
#   RuntimeError: Command failed: % .../waydroid-net.sh start
#
# Rather than patching the rule out, the module is built from THIS kernel tree
# (CONFIG_NETFILTER_XT_TARGET_CHECKSUM=m in vendor/halium.config) and signed
# with the same key, so it loads under CONFIG_MODULE_SIG_FORCE=y.
MOD=/usr/lib/halium/modules/xt_CHECKSUM.ko
if [ -f "$MOD" ] && ! grep -q "^xt_CHECKSUM " /proc/modules; then
    insmod "$MOD" 2>&1 || echo "warning: could not load xt_CHECKSUM"
fi

# --- 2. binder domain -----------------------------------------------------

[ -e "$BFS/binder-control" ] || { echo "no binderfs binder-control; nothing to do"; exit 0; }

/usr/bin/python3 /usr/lib/halium/binderalloc.py anbox-binder anbox-vndbinder anbox-hwbinder

# waydroid probes /dev/<name>, not /dev/binderfs/<name>.
for n in anbox-binder anbox-vndbinder anbox-hwbinder; do
    [ -e "$BFS/$n" ] || continue
    ln -sf "$BFS/$n" "/dev/$n"
done
ls -l /dev/anbox-* 2>&1
