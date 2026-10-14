# PyInstaller spec — build with:  .venv/bin/pyinstaller packaging/FITSView.spec --noconfirm
from pathlib import Path

from PyInstaller.utils.hooks import collect_data_files

ROOT = Path(SPECPATH).parent
# Nothing on macOS declares a type for FITS, so FITSView exports one; the Quick Look
# extensions (quicklook/) register for these identifiers.
FITS_UTI = "gov.nasa.gsfc.fits"
OGIP_UTI = "io.github.fitsview.ogip"

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
    version="0.2.2",
    info_plist={
        "CFBundleDisplayName": "FITSView",
        "NSHighResolutionCapable": True,
        # the bundled (Homebrew) Python is built for macOS 26; say so instead of crashing on older systems
        "LSMinimumSystemVersion": "26.0",
        "CFBundleDocumentTypes": [{
            "CFBundleTypeName": "FITS file",
            "CFBundleTypeRole": "Viewer",
            "LSHandlerRank": "Alternate",
            "LSItemContentTypes": [FITS_UTI, OGIP_UTI],
        }],
        "UTExportedTypeDeclarations": [
            {
                "UTTypeIdentifier": FITS_UTI,
                "UTTypeDescription": "FITS file",
                "UTTypeConformsTo": ["public.data", "public.content"],
                "UTTypeReferenceURL": "https://fits.gsfc.nasa.gov/",
                "UTTypeTagSpecification": {
                    "public.filename-extension": ["fits", "fit", "fts", "fz"],
                    "public.mime-type": ["image/fits", "application/fits"],
                },
            },
            {
                # X-ray (OGIP) products that are FITS under other extensions
                "UTTypeIdentifier": OGIP_UTI,
                "UTTypeDescription": "FITS file (OGIP)",
                "UTTypeConformsTo": [FITS_UTI],
                "UTTypeTagSpecification": {"public.filename-extension": ["evt", "pha", "pi", "arf", "rsp", "lc"]},
            },
        ],
    },
)
