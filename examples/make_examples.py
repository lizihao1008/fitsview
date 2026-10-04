"""Generate a handful of synthetic FITS files covering common layouts."""

from pathlib import Path

import numpy as np
from astropy.io import fits

OUT = Path(__file__).parent
rng = np.random.default_rng(42)


def star_field(n=512, nstars=80):
    yy, xx = np.mgrid[:n, :n]
    img = rng.normal(100, 5, (n, n))
    for _ in range(nstars):
        x0, y0 = rng.uniform(0, n, 2)
        amp = 10 ** rng.uniform(1, 4)
        img += amp * np.exp(-((xx - x0) ** 2 + (yy - y0) ** 2) / (2 * 2.0 ** 2))
    return img.astype(np.float32)


def wcs_header(n):
    h = fits.Header()
    h.update(CTYPE1="RA---TAN", CTYPE2="DEC--TAN", CRVAL1=150.1, CRVAL2=2.2,
             CRPIX1=n / 2, CRPIX2=n / 2, CD1_1=-5.5e-5, CD1_2=0.0, CD2_1=0.0, CD2_2=5.5e-5)
    return h


def gaussian_lines(wave, centers, widths, amps):
    out = np.zeros_like(wave)
    for c, w, a in zip(centers, widths, amps):
        out += a * np.exp(-0.5 * ((wave - c) / w) ** 2)
    return out


# 1. multi-extension image (like HST/JWST: SCI / ERR / DQ + catalog)
sci = star_field()
hdr = wcs_header(512)
hdr.update(BUNIT="MJy/sr", OBJECT="COSMOS-field", EXPTIME=1200.0)
prim = fits.PrimaryHDU(header=fits.Header({"TELESCOP": "SYNTH", "INSTRUME": "IMGR", "OBJECT": "COSMOS-field"}))
cat = fits.BinTableHDU.from_columns([
    fits.Column("ID", "J", array=np.arange(80)),
    fits.Column("RA", "D", unit="deg", array=150.1 + rng.normal(0, 0.01, 80)),
    fits.Column("DEC", "D", unit="deg", array=2.2 + rng.normal(0, 0.01, 80)),
    fits.Column("MAG_AUTO", "E", unit="mag", array=rng.uniform(18, 27, 80)),
    fits.Column("FLAGS", "I", array=rng.integers(0, 4, 80)),
    fits.Column("CLASS", "8A", array=rng.choice(["STAR", "GALAXY", "QSO"], 80)),
], name="CATALOG")
fits.HDUList([
    prim,
    fits.ImageHDU(sci, hdr, name="SCI"),
    fits.ImageHDU(np.sqrt(np.abs(sci)).astype(np.float32), hdr, name="ERR"),
    fits.ImageHDU((rng.random((512, 512)) > 0.995).astype(np.int16), hdr, name="DQ"),
    cat,
]).writeto(OUT / "multi_extension.fits", overwrite=True)

# 2. spectrum stored as a table with wavelength / flux / error columns
wave = np.linspace(3800, 9200, 4000)
flux = 1e-17 * (2 + 0.0002 * (wave - 3800) + gaussian_lines(wave, [4861, 5007, 6563, 6583], [3, 3, 4, 3], [4, 10, 15, 5]))
err = 1e-18 * np.ones_like(wave)
flux += rng.normal(0, 1, wave.size) * err
fits.HDUList([
    fits.PrimaryHDU(header=fits.Header({"OBJECT": "Galaxy-123", "Z": 0.0})),
    fits.BinTableHDU.from_columns([
        fits.Column("WAVELENGTH", "D", unit="Angstrom", array=wave),
        fits.Column("FLUX", "E", unit="erg/s/cm2/Angstrom", array=flux),
        fits.Column("FLUX_ERR", "E", unit="erg/s/cm2/Angstrom", array=err),
        fits.Column("MASK", "B", array=(rng.random(wave.size) > 0.99).astype(np.uint8)),
    ], name="SPECTRUM"),
]).writeto(OUT / "spectrum_table.fits", overwrite=True)

# 3. IRAF-style 1-D spectrum image with a linear wavelength solution
h = fits.Header({"CRVAL1": 3800.0, "CDELT1": 1.35, "CRPIX1": 1.0, "CTYPE1": "WAVE", "CUNIT1": "Angstrom",
                 "BUNIT": "erg/s/cm2/A", "OBJECT": "HD 12345"})
fits.PrimaryHDU(flux.astype(np.float32), h).writeto(OUT / "spectrum_1d.fits", overwrite=True)

# 4. SDSS-like spec file: coadd table with loglam / flux / ivar, plus a 1-row summary
loglam = np.log10(wave)
coadd = fits.BinTableHDU.from_columns([
    fits.Column("flux", "E", unit="1e-17 erg/s/cm2/Angstrom", array=flux * 1e17),
    fits.Column("loglam", "E", array=loglam),
    fits.Column("ivar", "E", array=np.full(wave.size, 1 / 0.1 ** 2)),
    fits.Column("and_mask", "J", array=np.zeros(wave.size, int)),
    fits.Column("model", "E", array=(flux * 1e17 - rng.normal(0, 0.1, wave.size))),
], name="COADD")
summary = fits.BinTableHDU.from_columns([
    fits.Column("PLATE", "J", array=[1234]),
    fits.Column("MJD", "J", array=[55555]),
    fits.Column("Z", "E", array=[0.0123]),
    fits.Column("CLASS", "6A", array=["GALAXY"]),
    fits.Column("SPECTROFLUX", "5E", array=rng.uniform(1, 50, (1, 5))),
], name="SPALL")
fits.HDUList([fits.PrimaryHDU(), coadd, summary]).writeto(OUT / "sdss_like_spec.fits", overwrite=True)

# 5. table where every row holds a whole spectrum in array columns
nspec, npix = 6, 2000
w = np.linspace(1.0, 5.0, npix)  # micron
fluxes = np.array([1 + 0.2 * k + gaussian_lines(w, [1.875, 3.3 + 0.1 * k], [0.01, 0.02], [2, 1])
                   + rng.normal(0, 0.05, npix) for k in range(nspec)])
fits.HDUList([
    fits.PrimaryHDU(),
    fits.BinTableHDU.from_columns([
        fits.Column("OBJID", "K", array=np.arange(1000, 1000 + nspec)),
        fits.Column("Z", "E", array=rng.uniform(0, 1, nspec)),
        fits.Column("WAVE", f"{npix}E", unit="um", array=np.tile(w, (nspec, 1))),
        fits.Column("FLUX", f"{npix}E", unit="uJy", array=fluxes),
        fits.Column("ERR", f"{npix}E", unit="uJy", array=np.full((nspec, npix), 0.05)),
    ], name="SPECTRA"),
]).writeto(OUT / "vector_spectra.fits", overwrite=True)

# 6. data cube (e.g. IFU / radio): 30 channels of 128x128
yy, xx = np.mgrid[:128, :128]
chan = np.arange(30)
cube = (np.exp(-((xx - 64) ** 2 + (yy - 64) ** 2) / 300)[None] * np.exp(-0.5 * ((chan - 15) / 4) ** 2)[:, None, None]
        + rng.normal(0, 0.02, (30, 128, 128))).astype(np.float32)
ch = fits.Header({"CTYPE3": "VRAD", "CRVAL3": -150.0, "CDELT3": 10.0, "CRPIX3": 1, "CUNIT3": "km/s", "BUNIT": "Jy/beam"})
fits.PrimaryHDU(cube, ch).writeto(OUT / "cube.fits", overwrite=True)

# 7. X-ray event list + GTI + OGIP spectrum
nev = 50_000
ev_x = np.concatenate([rng.normal(4096, 30, nev // 2), rng.uniform(3500, 4700, nev // 2)])
ev_y = np.concatenate([rng.normal(4096, 30, nev // 2), rng.uniform(3500, 4700, nev // 2)])
events = fits.BinTableHDU.from_columns([
    fits.Column("TIME", "D", unit="s", array=np.sort(rng.uniform(0, 1e4, nev))),
    fits.Column("X", "E", unit="pixel", array=ev_x),
    fits.Column("Y", "E", unit="pixel", array=ev_y),
    fits.Column("PI", "J", unit="chan", array=rng.integers(30, 800, nev)),
    fits.Column("ENERGY", "E", unit="eV", array=rng.exponential(1500, nev) + 300),
], name="EVENTS")
for k, v in {"TCTYP2": "RA---TAN", "TCTYP3": "DEC--TAN", "TCRPX2": 4096.5, "TCRPX3": 4096.5,
             "TCRVL2": 83.63, "TCRVL3": 22.01, "TCDLT2": -1.37e-4, "TCDLT3": 1.37e-4,
             "TLMIN2": 0.5, "TLMAX2": 8192.5, "TLMIN3": 0.5, "TLMAX3": 8192.5}.items():
    events.header[k] = v
gti = fits.BinTableHDU.from_columns([fits.Column("START", "D", array=[0.0, 6000.0]),
                                     fits.Column("STOP", "D", array=[5000.0, 1e4])], name="GTI")
channels = np.arange(1024)
pha = fits.BinTableHDU.from_columns([
    fits.Column("CHANNEL", "J", array=channels),
    fits.Column("COUNTS", "J", array=rng.poisson(200 * np.exp(-channels / 150) + 2)),
], name="SPECTRUM")
pha.header.update(HDUCLAS1="SPECTRUM", EXPOSURE=1e4, TELESCOP="SYNTH", INSTRUME="XRT")
fits.HDUList([fits.PrimaryHDU(), events, gti, pha]).writeto(OUT / "xray_events.fits", overwrite=True)

# 8. tile-compressed image + ASCII table + variable-length array column
comp = fits.CompImageHDU(star_field(1024, 200), wcs_header(1024), name="SCI_COMP")
ascii_tab = fits.TableHDU.from_columns([
    fits.Column("NAME", "A10", array=["alpha", "beta", "gamma"]),
    fits.Column("VMAG", "F8.3", array=[1.2, 3.4, 5.6]),
], name="ASCIITAB")
vla = fits.BinTableHDU.from_columns([
    fits.Column("N", "J", array=[3, 5, 2]),
    fits.Column("SAMPLES", "PE()", array=np.array([np.arange(3.0), np.arange(5.0), np.arange(2.0)], dtype=object)),
], name="VARLEN")
fits.HDUList([fits.PrimaryHDU(), comp, ascii_tab, vla]).writeto(OUT / "compressed_misc.fits", overwrite=True)

print("wrote examples to", OUT)
