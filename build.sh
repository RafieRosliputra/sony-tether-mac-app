#!/usr/bin/env bash
# Build sonyTether.app, a self-contained macOS bundle, plus a DMG and a ZIP.
#
#   ./build.sh            # build everything into build/
#   ./build.sh app        # app bundle only
#   ./build.sh run        # build then launch the app
#
# Requires: Xcode Command Line Tools (swiftc), Homebrew libgphoto2 (build-time only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="sonyTether"
VERSION="0.12.0"
BUNDLE_ID="com.johorstudio.sonytether"
MIN_MACOS="26.0"
ARCH="arm64"

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
DIST="$ROOT/dist"
GPHOTO_PREFIX="${GPHOTO_PREFIX:-$(brew --prefix libgphoto2 2>/dev/null || echo /opt/homebrew/opt/libgphoto2)}"
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$GPHOTO_PREFIX/include/gphoto2/gphoto2.h" ] \
  || die "libgphoto2 headers not found at $GPHOTO_PREFIX (brew install libgphoto2)"

# ---------------------------------------------------------------- icon
make_icon() {
  if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    say "Generating icon"
    mkdir -p "$ROOT/Resources"
    swift "$ROOT/tools/icon.swift" "$ROOT/Resources/AppIcon.icns"
  fi
}

# ---------------------------------------------------------------- compile
compile() {
  say "Compiling $APP_NAME ($ARCH, macOS $MIN_MACOS+)"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
  swiftc \
    -O -whole-module-optimization \
    -swift-version 5 \
    -target "$ARCH-apple-macos$MIN_MACOS" \
    -I "$ROOT/Sources/GPhoto2" \
    -Xcc "-I$GPHOTO_PREFIX/include" \
    -Xcc "-I$BREW/include" \
    -L "$GPHOTO_PREFIX/lib" \
    -L "$BREW/lib" \
    -lgphoto2 -lgphoto2_port \
    -framework AppKit -framework Foundation -framework IOKit \
    "$ROOT"/Sources/*.swift \
    -o "$APP/Contents/MacOS/$APP_NAME"
}

# ---------------------------------------------------------------- bundle
bundle() {
  say "Assembling bundle"
  cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" >/dev/null
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  if [ -d "$ROOT/lightroom" ]; then
    rm -rf "$APP/Contents/Resources/lightroom"
    cp -R "$ROOT/lightroom" "$APP/Contents/Resources/lightroom"
  fi

  # Copy the resolved dependency closure of libgphoto2 into Frameworks.
  local queue=(
    "$GPHOTO_PREFIX/lib/libgphoto2.6.dylib"
    "$GPHOTO_PREFIX/lib/libgphoto2_port.12.dylib"
  )
  local -a extra=(
    "$(brew --prefix libtool)/lib/libltdl.7.dylib"
    "$(brew --prefix libexif)/lib/libexif.12.dylib"
    "$(brew --prefix gettext)/lib/libintl.8.dylib"
    "$(brew --prefix libusb)/lib/libusb-1.0.0.dylib"
    "$(brew --prefix jpeg-turbo)/lib/libjpeg.8.dylib"
  )
  for l in "${extra[@]}"; do
    if [ -f "$l" ]; then queue+=("$l"); fi
  done
  for l in "${queue[@]}"; do
    [ -f "$l" ] || die "missing library: $l"
  done

  local -a seen=()
  while [ ${#queue[@]} -gt 0 ]; do
    local src="${queue[0]}"
    queue=("${queue[@]:1}")
    local base
    base="$(basename "$src")"
    local already=0
    for s in "${seen[@]:-}"; do [ "$s" = "$base" ] && already=1; done
    [ $already -eq 1 ] && continue
    seen+=("$base")
    if [ ! -f "$APP/Contents/Frameworks/$base" ]; then
      cp -L "$src" "$APP/Contents/Frameworks/$base"
    fi
    while read -r dep; do
      [ -n "$dep" ] || continue
      case "$dep" in
        /opt/*|/usr/local/*)
          local real
          real="$(readlink -f "$dep" 2>/dev/null || echo "$dep")"
          if [ -f "$real" ]; then queue+=("$real"); else say "warning: missing dep $dep"; fi
          ;;
      esac
    done < <(otool -L "$APP/Contents/Frameworks/$base" | tail -n +2 | awk '{print $1}' | grep -v '^@')
  done

  # Camera driver (ptp2 speaks Sony PTP / PC Remote) and USB I/O plugin.
  local gphoto_libdir iolib_dir
  gphoto_libdir="$(dirname "$(find "$GPHOTO_PREFIX/lib/libgphoto2" -name ptp2.so -print -quit)")"
  iolib_dir="$(dirname "$(find "$GPHOTO_PREFIX/lib/libgphoto2_port" -name usb1.so -print -quit)")"
  [ -n "$gphoto_libdir" ] || die "ptp2.so not found"
  mkdir -p "$APP/Contents/Resources/gphoto/camlibs" "$APP/Contents/Resources/gphoto/iolibs"
  rm -f "$APP/Contents/Resources/gphoto/camlibs/ptp2.so"
  cp "$gphoto_libdir/ptp2.so" "$APP/Contents/Resources/gphoto/camlibs/"
  rm -f "$APP/Contents/Resources/gphoto/iolibs/usb1.so"
  cp "$iolib_dir/usb1.so" "$APP/Contents/Resources/gphoto/iolibs/"
  if [ -f "$iolib_dir/ptpip.so" ]; then rm -f "$APP/Contents/Resources/gphoto/iolibs/ptpip.so"; cp "$iolib_dir/ptpip.so" "$APP/Contents/Resources/gphoto/iolibs/"; fi

  say "Rewriting install names"
  local fw="@executable_path/../Frameworks"
  # Every image: point library references at the bundle.
  for f in "$APP/Contents/Frameworks/"*.dylib "$APP/Contents/Resources/gphoto/camlibs/"*.so \
           "$APP/Contents/Resources/gphoto/iolibs/"*.so "$APP/Contents/MacOS/$APP_NAME"; do
    local deps
    deps="$(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -E '^/(opt|usr/local)' || true)"
    for dep in $deps; do
      install_name_tool -change "$dep" "$fw/$(basename "$dep")" "$f" 2>/dev/null || true
    done
  done
  for f in "$APP/Contents/Frameworks/"*.dylib; do
    install_name_tool -id "$fw/$(basename "$f")" "$f"
  done
  # The main binary must be able to resolve the bundle paths.
  install_name_tool -add_rpath "$fw" "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

  say "Signing (ad-hoc)"
  for f in "$APP/Contents/Frameworks/"*.dylib \
           "$APP/Contents/Resources/gphoto/camlibs/"*.so \
           "$APP/Contents/Resources/gphoto/iolibs/"*.so; do
    codesign --force --sign - --timestamp=none "$f" >/dev/null 2>&1 || die "codesign failed: $f"
  done
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || die "codesign failed: app"
}

# ---------------------------------------------------------------- packages
package() {
  mkdir -p "$DIST"
  say "Packaging DMG + ZIP"
  local stage="$BUILD_DIR/dmg"
  rm -rf "$stage"
  mkdir -p "$stage"
  cp -R "$APP" "$stage/"
  ln -s /Applications "$stage/Applications"
  rm -f "$DIST/$APP_NAME-$VERSION.dmg"
  hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$stage" \
    -ov -format UDZO "$DIST/$APP_NAME-$VERSION.dmg"
  rm -rf "$stage"
  rm -f "$DIST/$APP_NAME-$VERSION-macOS.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$APP_NAME-$VERSION-macOS.zip"
  say "Artifacts:"
  ls -lh "$DIST" | tail -n +2
}

# ---------------------------------------------------------------- main
make_icon
compile
bundle
case "${1:-all}" in
  app) : ;;
  run) package >/dev/null; open "$APP" ;;
  *) package ;;
esac
say "Done → $APP"
