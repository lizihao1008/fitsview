# fitsview

A lightweight, modern take on HEASARC's `fv`: browse the HDU structure of FITS files,
read headers, page through tables, and plot spectra in your browser. Images and cubes
are handed off to SAOImage DS9.

## Run

```bash
python3 -m venv .venv && .venv/bin/pip install -e .
.venv/bin/fitsview path/to/file.fits          # or just `fitsview` to start with the file browser
```

Options for the browser version: `--port 8765`, `--dir <start directory>`, `--no-browser`.
Sample files: `.venv/bin/python examples/make_examples.py` writes 8 synthetic files to `examples/`.

## Install (macOS 26+, Apple Silicon)

1. Download `FITSView-<version>.dmg`, open it, and drag **FITSView** onto **Applications**.
2. The app is not notarized by Apple, so the first launch is blocked ("Apple could not verify…").
   Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click
   **Open Anyway** next to the FITSView message. Or, in Terminal:
   `xattr -dr com.apple.quarantine /Applications/FITSView.app`
3. Open FITSView once. That also enables the Finder thumbnails and space-bar previews.

## Desktop app (macOS)

```bash
packaging/build_mac.sh            # -> dist/FITSView.app (~70 MB, self-contained)
packaging/make_dmg.sh             # -> dist/FITSView-<version>.dmg (drag-to-Applications installer)
```

The build only supports what it's built on: Apple Silicon and macOS 26+, because the bundled
Homebrew Python targets macOS 26 (`LSMinimumSystemVersion` is set accordingly).

Drag `dist/FITSView.app` into `/Applications`. Then: right-click a `.fits` file → Open With → FITSView,
or drop files onto the window or the Dock icon. **File → Open…** / **Browse…** use the native dialog.
During development, `.venv/bin/fitsview-desktop file.fits` runs the same window without building.

The app is ad-hoc signed, not signed with an Apple Developer ID, so downloaded copies need the
"Open Anyway" step above. Signing with a Developer ID certificate and notarizing would remove it.

### Quick Look: Finder thumbnails and space-bar preview

FITSView.app embeds two Quick Look extensions (native Swift, in `quicklook/`):

- **Thumbnails** in Finder icon/gallery view: the image (zscale; middle plane for cubes),
  a spectrum plot, or an X-ray event list binned on X/Y.
- **Space-bar preview**: the same image/spectrum large, the HDU list, image statistics,
  the first rows of every table, and each HDU's header (click to expand).

They work once macOS knows the app: put `FITSView.app` in `/Applications` and open it once.
If previews don't appear, check *System Settings → General → Login Items & Extensions → Quick Look*,
and run `qlmanage -r && qlmanage -r cache`. The app declares the type `gov.nasa.gsfc.fits`
(`.fits .fit .fts .fz`) and `io.github.fitsview.ogip` (`.evt .pha .pi .arf .rsp .lc`).

Not previewed yet: tile-compressed (`.fz`) pixels and gzipped files; those show headers/tables only
or the generic icon. To test the rendering code without Quick Look:

```bash
quicklook/build.sh && build/quicklook/qlrender /tmp/ql examples/*.fits   # writes HTML + thumb.png per file
```

## What it does

| HDU content | Detected as | Default view |
|---|---|---|
| no data | header only | Header (filterable cards, raw 80-col view, copy) |
| 2-D image | image | quick-look PNG (zscale / percentiles, linear/sqrt/log/asinh, colormaps) + stats + **DS9** |
| 3-D cube | cube | as image, with a slice slider + **DS9** |
| NAXIS=1 image | 1-D spectrum | plot with wavelength axis from `CRVAL1/CDELT1/CRPIX1` (log-linear via `DC-FLAG`) |
| few long rows (e.g. old SDSS spSpec) | spectra (rows) | plot one row at a time |
| table with wave/flux-like columns | spectrum table | X/Y/error plot, `loglam` → 10^x, `ivar` → 1/√ivar |
| table with array columns (one spectrum per row) | spectrum table | click an array cell to plot that row |
| table with X, Y, TIME/PI | event list | X–Y scatter; **DS9** bins it into an image |
| any other table | table | paged grid (100 rows/page), column info (TFORM/TUNIT/TDIM/TNULL), click a header to plot |

Also: tile-compressed images, ASCII tables, variable-length arrays, drag-and-drop
(the file is copied to a temp dir), ↑/↓ to move between HDUs, light/dark theme.

## DS9 hand-off

If a DS9 is already running, the HDU is sent to it via XPA in a new frame; otherwise DS9 is
launched with `file.fits[N]`. The executable is found via `$FITSVIEW_DS9`, `PATH`, or
`/Applications/SAOImageDS9.app`. Note: the macOS DS9 8.x bundle registers its XPA access
point as user `root`, so the XPA calls use `-u '*'`.

## Layout

```
fitsview/
  fitsinfo.py   FITS → JSON: HDU classification, headers, table pages, plot data
  render.py     2-D array → PNG (pure numpy + zlib)
  ds9.py        XPA / launch bridge
  server.py     Flask JSON API (localhost only)
  desktop.py    native window (pywebview) around the same server
  static/       single-page UI (vanilla JS + vendored Plotly)
packaging/      PyInstaller spec, icon generator, build_mac.sh
quicklook/      Quick Look extensions: Shared/ (FITS reader, zscale, HTML/SVG), Preview/, Thumbnail/
```

The server binds to 127.0.0.1 and can read any file your user can, so don't expose it on a network.
