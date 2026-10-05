#!/bin/sh
# Launcher for the IR Camera click app.
#
# Two things have to be set up before the QML loads:
#
#  * HYBRIS_LD_LIBRARY_PATH tells libhybris where Android's libraries live.
#    /apex/com.android.i18n/lib64 is not optional: libcamera2ndk pulls in
#    libandroid_runtime, whose dependency closure needs libicu.so, and apex
#    directories are not on bionic's default search path.
#  * QML2_IMPORT_PATH points at our own IRCam plugin.
set -e
APP="$(cd "$(dirname "$0")" && pwd)"

export HYBRIS_LD_LIBRARY_PATH=/system/lib64:/vendor/lib64:/odm/lib64:/apex/com.android.i18n/lib64
export QML2_IMPORT_PATH="$APP/lib${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
export LD_LIBRARY_PATH="$APP/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

exec qmlscene -qwindowgeometry 100x100 "$APP/qml/Main.qml" "$@"
