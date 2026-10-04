# PyInstaller spec — build with:  .venv/bin/pyinstaller packaging/FITSView.spec --noconfirm
from pathlib import Path

from PyInstaller.utils.hooks import collect_data_files

ROOT = Path(SPECPATH).parent
FITS_EXTS = ["fits", "fit", "fts", "fz", "pha", "pi", "rmf", "arf", "rsp", "evt", "lc"]

a = Analysis(
    [str(ROOT / "packaging" / "launcher.py")],
    pathex=[str(ROOT)],
    datas=[(str(ROOT / "fitsview" / "static"), "fitsview/static")] + collect_data_files("astropy"),
    hiddenimports=["astropy.visualization", "webview.platforms.cocoa"],
    excludes=["tkinter", "matplotlib", "IPython", "pytest", "scipy", "pandas", "PIL"],
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz, a.scripts, [],
    exclude_binaries=True,
    name="FITSView",
    console=False,
    argv_emulation=True,  # Finder "Open With" / dropping onto the icon at launch -> sys.argv
)
coll = COLLECT(exe, a.binaries, a.datas, name="FITSView")
app = BUNDLE(
    coll,
    name="FITSView.app",
    icon=str(ROOT / "packaging" / "FITSView.icns"),
    bundle_identifier="io.github.fitsview",
    version="0.1.0",
    info_plist={
        "CFBundleDisplayName": "FITSView",
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "11.0",
        "CFBundleDocumentTypes": [{
            "CFBundleTypeName": "FITS file",
            "CFBundleTypeRole": "Viewer",
            "LSHandlerRank": "Alternate",
            "CFBundleTypeExtensions": FITS_EXTS,
        }],
    },
)
