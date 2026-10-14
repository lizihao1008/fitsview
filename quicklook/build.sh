#!/bin/zsh
# Build the Quick Look extensions (and the qlrender test tool) with plain swiftc.
#   quicklook/build.sh [OUTDIR]   -> OUTDIR/FITSPreview.appex, FITSThumbnail.appex, qlrender
set -e
HERE=${0:A:h}
OUT=${1:-$HERE/../build/quicklook}
mkdir -p "$OUT"
OUT=${OUT:A}   # absolute, resolved against the caller's cwd
cd "$HERE"
SDK=$(xcrun --sdk macosx --show-sdk-path)
ARCH=$(uname -m)
SWIFTC=(xcrun swiftc -O -sdk "$SDK" -target "$ARCH-apple-macos12.0")

appex() {  # name source framework
  local dir="$OUT/$1.appex/Contents"
  rm -rf "$OUT/$1.appex"
  mkdir -p "$dir/MacOS"
  cp "$2/Info.plist" "$dir/Info.plist"
  $SWIFTC -module-name "$1" -application-extension -parse-as-library \
    Shared/*.swift "$2"/*.swift -framework "$3" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$dir/MacOS/$1"
  codesign --force --sign - --timestamp=none --entitlements Extension.entitlements "$OUT/$1.appex"
  echo "built $OUT/$1.appex"
}

appex FITSPreview Preview QuickLookUI
appex FITSThumbnail Thumbnail QuickLookThumbnailing
$SWIFTC -module-name qlrender Shared/*.swift Tools/main.swift -o "$OUT/qlrender"
echo "built $OUT/qlrender"
