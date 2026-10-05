#!/bin/bash
# Clean cross-build of libQt5Quick.so.5.15.13 (GLES) for arm64.
# Strategy: configure+build once via dpkg-buildpackage; when the build stops
# because a TARGET-arch helper tool cannot execute on the BUILD host, swap in
# the host-arch generator and continue with plain `make` (never re-run
# dpkg-buildpackage, which re-runs qmake and corrupts the configured tree).
set -u
SRC=/build/qtdeclarative-opensource-src-gles-5.15.13+dfsg

swap_tools() {
  local n=0
  for t in qmltyperegistrar qmlcachegen qmlimportscanner; do
    if [ -f "/opt/hosttools/usr/lib/qt5/bin/$t" ]; then
      if [ ! -f "$SRC/bin/$t" ] || ! file -b "$SRC/bin/$t" | grep -q x86-64; then
        cp "/opt/hosttools/usr/lib/qt5/bin/$t" "$SRC/bin/$t" 2>/dev/null && touch "$SRC/bin/$t" && { echo "  swapped $t -> host amd64"; n=$((n+1)); }
      fi
    fi
  done
  return 0
}

echo "=== clean extract $(date) ==="
rm -rf "$SRC"
cd /build && dpkg-source -x qtdeclarative-opensource-src-gles_5.15.13+dfsg-2.dsc 2>&1 | tail -2
cd "$SRC" || { echo "EXTRACT FAILED"; exit 1; }
cp /build/null-check-sciReply.patch debian/patches/
echo "null-check-sciReply.patch" >> debian/patches/series
QUILT_PATCHES=debian/patches quilt push -a >/dev/null 2>&1
echo "=== patch verification ==="
grep -A2 "Q_D(QQuickBorderImage);" src/quick/items/qquickborderimage.cpp | grep -c "sciReply" || true
sed -n '/void QQuickBorderImage::sciRequestFinished/,/redirectCount++/p' src/quick/items/qquickborderimage.cpp | head -14

export DEB_BUILD_OPTIONS="nocheck parallel=16"
echo "=== configure + first build pass $(date) ==="
dpkg-buildpackage -aarm64 -B -uc -us -d >/build/pass1.log 2>&1
echo "pass1 rc=$? (a failure here at qmltyperegistrar is expected)"

for i in 1 2 3 4 5; do
  mkdir -p "$SRC/bin"
  echo "=== swap pass $i ==="
  swap_tools
  echo "=== make -j16 (attempt $i) $(date) ==="
  cd "$SRC" && make -j16 >>/build/pass2.log 2>&1
  rc=$?
  echo "make attempt $i rc=$rc"
  if [ -f "$SRC/lib/libQt5Quick.so.5.15.13" ]; then echo "LIB PRESENT after attempt $i"; fi
  [ $rc -eq 0 ] && break
  grep -aq "Exec format error" /build/pass2.log || break
done

echo "=== RESULT ==="
ls -l "$SRC/lib/libQt5Quick.so.5.15.13" 2>/dev/null && file -b "$SRC/lib/libQt5Quick.so.5.15.13" || echo "libQt5Quick NOT produced"
echo "=== SCRIPT EXIT: $? ==="
