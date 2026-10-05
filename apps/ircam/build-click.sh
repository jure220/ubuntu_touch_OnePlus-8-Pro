#!/bin/bash
# Build the IR Camera click package: ./build-click.sh  ->  dist/ircam.z3phyr_<version>_arm64.click
#
# Everything happens in containers; nothing is installed on the host.
#   * ircam-build:24.04  cross-compiles the command-line tool
#   * ircam-qt:24.04     is an arm64 image run under emulation (needs qemu-user
#                        binfmt), used for the QML plugin so it links against
#                        exactly the Qt 5.15.13 the phone has
#   * ircam-click:24.04  UBports' click tool, which packs the tree
# The images are built from docker/ on first use.
set -e
cd "$(dirname "$0")"
HERE=$PWD
UID_GID="$(id -u):$(id -g)"
OUT=click/build

img() {  # tag dockerfile [platform]
    docker image inspect "$1" >/dev/null 2>&1 && return
    echo "== building image $1 =="
    docker build ${3:+--platform $3} -t "$1" -f "docker/$2" docker
}
img ircam-build:24.04 Dockerfile.build
img ircam-qt:24.04 Dockerfile.qt linux/arm64
img ircam-click:24.04 Dockerfile.click

echo "== command-line tool (cross-compiled) =="
docker run --rm -u "$UID_GID" -v "$HERE:/work" -w /work ircam-build:24.04 make

echo "== QML plugin (native arm64 under emulation) =="
docker run --rm --platform linux/arm64 -u "$UID_GID" -v "$HERE:/work" -w /work ircam-qt:24.04 \
    bash -c 'cmake -S . -B build-qt -DCMAKE_BUILD_TYPE=Release >/dev/null && cmake --build build-qt -j"$(nproc)"'

echo "== assembling $OUT =="
rm -rf "$OUT"
mkdir -p "$OUT/lib/IRCam" "$OUT/qml" "$OUT/bin"
cp click/manifest.json click/ircam.apparmor click/ircam.desktop click/ircam.svg click/run.sh "$OUT/"
cp click/qml/Main.qml "$OUT/qml/"
cp build-qt/libircamplugin.so "$OUT/lib/IRCam/"
cp plugin/qmldir "$OUT/lib/IRCam/"
cp build/ircam-shot "$OUT/bin/"
docker run --rm -u "$UID_GID" -v "$HERE:/work" -w /work ircam-build:24.04 \
    aarch64-linux-gnu-strip --strip-unneeded "$OUT/lib/IRCam/libircamplugin.so" "$OUT/bin/ircam-shot"
chmod -R u=rwX,go=rX "$OUT"
chmod 755 "$OUT/run.sh" "$OUT/bin/ircam-shot"

echo "== packing the click =="
mkdir -p dist
rm -f dist/*.click
docker run --rm -u "$UID_GID" -v "$HERE:/work" -w /work/dist ircam-click:24.04 \
    click build --no-validate "../$OUT" 2>&1 | tail -2
ls -l dist/*.click

echo "== recovery-flashable zip =="
CLICK=$(ls dist/*.click)
VER=$(basename "$CLICK" | cut -d_ -f2)
ZIP=dist/ircam-z3phyr-$VER-flashable.zip
python3 - "$ZIP" "$CLICK" <<'PY'
import sys, zipfile, os
out, click = sys.argv[1:]
with zipfile.ZipFile(out + ".tmp", "w", zipfile.ZIP_DEFLATED) as z:
    def add(src, name, mode):
        zi = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
        zi.external_attr = (0o100000 | mode) << 16
        zi.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(zi, open(src, "rb").read())
    add("flashable/META-INF/com/google/android/update-binary", "META-INF/com/google/android/update-binary", 0o755)
    add("flashable/META-INF/com/google/android/updater-script", "META-INF/com/google/android/updater-script", 0o644)
    add("flashable/ircam-install.service", "ircam-install.service", 0o644)
    add(click, os.path.basename(click), 0o644)
os.replace(out + ".tmp", out)
PY
sha256sum dist/*.click dist/*.zip | sed 's#dist/##' > dist/SHA256SUMS
cat dist/SHA256SUMS
