#!/bin/zsh
# Build dist/FITSView.app (run from anywhere).
set -e
cd "${0:A:h}/.."
[[ -x .venv/bin/python ]] || python3 -m venv .venv
.venv/bin/pip install -q -e . pywebview pyinstaller
[[ -f packaging/FITSView.icns ]] || .venv/bin/python packaging/make_icon.py
.venv/bin/pyinstaller packaging/FITSView.spec --noconfirm --distpath dist --workpath build
echo "built: $PWD/dist/FITSView.app"
