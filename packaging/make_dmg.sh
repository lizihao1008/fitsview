#!/bin/zsh
# Package dist/FITSView.app into dist/FITSView-<version>.dmg (drag-to-Applications installer).
#   packaging/make_dmg.sh          (run packaging/build_mac.sh first)
set -e
cd "${0:A:h}/.."
APP=dist/FITSView.app
[[ -d $APP ]] || { echo "missing $APP — run packaging/build_mac.sh first"; exit 1; }
VERSION=$(plutil -extract CFBundleShortVersionString raw $APP/Contents/Info.plist)
NAME="FITSView $VERSION"
DMG=dist/FITSView-$VERSION.dmg
STAGE=build/dmg-stage
RW=build/FITSView-rw.dmg
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Temporary copies get noticed by LaunchServices; when they vanish, macOS can drop the
# Quick Look extensions of *every* FITSView copy. Unregister them before deleting.
forget() { $LSREG -u "$1" >/dev/null 2>&1 || true; }

rm -rf $STAGE $RW $DMG
mkdir -p $STAGE
ditto $APP $STAGE/FITSView.app          # ditto keeps signatures/xattrs intact
ln -s /Applications $STAGE/Applications
cp packaging/FITSView.icns $STAGE/.VolumeIcon.icns

# read-write image first so the volume can get a custom icon, then compress
hdiutil create -quiet -volname "$NAME" -srcfolder $STAGE -fs APFS -format UDRW $RW
MNT=$(hdiutil attach -nobrowse -noautoopen $RW | awk -F'\t' '/\/Volumes\//{print $NF}')
xcrun SetFile -a C "$MNT"
forget "$MNT/FITSView.app"
hdiutil detach -quiet "$MNT"
hdiutil convert -quiet $RW -format ULFO -o $DMG   # LZFSE, macOS 10.11+
forget "$PWD/$STAGE/FITSView.app"
rm -rf $STAGE $RW
hdiutil verify -quiet $DMG
echo "built: $PWD/$DMG ($(du -h $DMG | cut -f1))"
