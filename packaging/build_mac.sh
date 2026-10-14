#!/bin/zsh
# Build dist/FITSView.app (run from anywhere).
set -e
cd "${0:A:h}/.."
[[ -x .venv/bin/python ]] || python3 -m venv .venv
.venv/bin/pip install -q -e . pywebview pyinstaller
[[ -f packaging/FITSView.icns ]] || .venv/bin/python packaging/make_icon.py
.venv/bin/pyinstaller packaging/FITSView.spec --noconfirm --distpath dist --workpath build

# Quick Look extensions (space-bar preview + Finder thumbnails), then re-seal the app
quicklook/build.sh build/quicklook
APP=dist/FITSView.app
mkdir -p $APP/Contents/PlugIns
rm -rf $APP/Contents/PlugIns/FITSPreview.appex $APP/Contents/PlugIns/FITSThumbnail.appex
cp -R build/quicklook/FITSPreview.appex build/quicklook/FITSThumbnail.appex $APP/Contents/PlugIns/
codesign --force --sign - --timestamp=none $APP
codesign --verify --strict $APP

# an already-running extension process would keep serving the old code
pkill -f "FITSView.app/Contents/PlugIns/FITS(Preview|Thumbnail).appex" || true
qlmanage -r cache >/dev/null 2>&1 || true
echo "built: $PWD/$APP"
