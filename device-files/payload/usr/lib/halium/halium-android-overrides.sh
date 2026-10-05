#!/bin/sh
# Bind locally built replacements over files inside the read-only Android image.
#
# WHY THIS EXISTS
# /android is a loop mount of /userdata/android-rootfs.img, read-only and 630 MB.
# Some Android-side libraries need fixes that are built from halium/android in
# this project, and reflashing 630 MB to replace a 370 KB library is not a sane
# update path. Anything placed under /usr/lib/halium/android-overrides is
# bind-mounted over the file at the same relative path under /android, so the
# fix rides in the boot image along with the rest of the port.
#
# A file that is already byte-identical is skipped, so once a fix lands in a
# rebuilt android-rootfs.img this turns into a no-op on its own -- there is
# nothing to remember to undo.
#
# SAFETY
# Called as ExecStartPost=- from mount-android-partitions.service, i.e. after
# /android is mounted and before anything that uses it. Every failure mode is
# logged and skipped and the script always exits 0: the worst case is that an
# override does not apply, never a boot that stops.

SRC=/usr/lib/halium/android-overrides

log() { echo "halium-android-overrides: $*"; }

[ -d "$SRC" ] || exit 0

# Kill switch, same convention as /userdata/.no-120hz. These overrides sit in
# the graphics path, so there has to be a way to get back to the stock Android
# libraries from recovery if one of them ever stops the shell from starting:
#     touch /userdata/.no-android-overrides
if [ -e /userdata/.no-android-overrides ]; then
    log "disabled by /userdata/.no-android-overrides"
    exit 0
fi

# Sanity check rather than `mountpoint`: build.prop only exists once the image
# is actually mounted, and this needs no tool beyond the shell.
if [ ! -f /android/system/build.prop ]; then
    log "/android does not look mounted, nothing to override"
    exit 0
fi

find "$SRC" -type f | while read -r src; do
    rel=${src#"$SRC"/}
    dst=/android/$rel

    if [ ! -f "$dst" ]; then
        log "skip $rel: no such file under /android"
        continue
    fi
    if cmp -s "$src" "$dst"; then
        log "skip $rel: already identical"
        continue
    fi
    if mount --bind "$src" "$dst"; then
        log "bound $rel"
    else
        log "FAILED to bind $rel, leaving the original in place"
    fi
done

exit 0
