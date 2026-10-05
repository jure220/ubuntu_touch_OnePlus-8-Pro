#!/bin/sh
# Generate lxc.mount.entry lines that neutralise chosen vendor HAL rc files.
#
# /vendor is read-only (erofs), so their .rc files cannot be edited. But the
# container is built from lxc.mount.entry lines, and binding an EMPTY regular
# file over an .rc makes Android init parse nothing -- the services it defined
# are simply never declared. Non-destructive and instantly reversible: drop the
# bind and the stock file is back.
#
# Usage:  halium-disable-hals.sh qseecomd soter qteeconnector
# Prints the -s "lxc.mount.entry=..." lines to paste into the wrapper, and
# lists which rc files matched so nothing is disabled blindly.
set -u

EMPTY=/usr/lib/halium/bin/empty.rc
[ -f "$EMPTY" ] || : > "$EMPTY"

VENDOR_INIT=/android/vendor/etc/init
[ -d "$VENDOR_INIT" ] || { echo "ERROR: $VENDOR_INIT not present (is /vendor mounted?)" >&2; exit 1; }

for pat in "$@"; do
    found=0
    for f in "$VENDOR_INIT"/*"$pat"*.rc; do
        [ -e "$f" ] || continue
        found=1
        rel=${f#/android/}
        echo "    -s \"lxc.mount.entry=$EMPTY $rel none bind,ro 0 0\" \\"
        echo "      # disables: $(grep -hoE '^service +[a-zA-Z0-9_.@-]+' "$f" | awk '{print $2}' | tr '\n' ' ')" >&2
    done
    [ "$found" = "0" ] && echo "  (no rc matched '$pat')" >&2
done
