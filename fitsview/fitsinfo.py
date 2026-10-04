"""Read FITS structure and data into JSON-friendly structures."""

import math
import re

import numpy as np
from astropy.io import fits

MAX_PLOT_POINTS = 200_000

WAVE_RE = re.compile(r"^(wave|wavelength|lambda|wl|wav|loglam|lam|freq|frequency|energy|e_mid|channel|vel|velocity)$", re.I)
FLUX_RE = re.compile(r"^(flux|f_lambda|flam|fnu|f_nu|flux_density|counts|rate|intensity|spec|spectrum|sci)$", re.I)
VLA_RE = re.compile(r"^\d*[PQ]([A-Z])")
ERR_RE = re.compile(r"^(err|error|flux_err|fluxerr|flux_error|sigma|stat_err|e_flux|ivar|uncertainty|noise)$", re.I)


def open_fits(path):
    return fits.open(path, memmap=True, lazy_load_hdus=True)


# ---------------------------------------------------------------- summary

def _image_dims(hdr):
    naxis = int(hdr.get("NAXIS", 0))
    return [int(hdr.get(f"NAXIS{i}", 0)) for i in range(1, naxis + 1)]


def classify(hdu):
    """Return (kind, extra) where kind is one of
    empty / image / cube / spectrum / spectra / table / events / groups."""
    hdr = hdu.header
    if isinstance(hdu, fits.GroupsHDU):
        return "groups", {}
    if isinstance(hdu, (fits.BinTableHDU, fits.TableHDU)):
        names = [n.upper() for n in hdu.columns.names]
        if "X" in names and "Y" in names and ("TIME" in names or "PI" in names or "PHA" in names):
            return "events", {}
        if guess_spectrum_columns(hdu.columns)["y"]:
            return "spectrum-table", {}
        return "table", {}
    dims = _image_dims(hdr)
    if not dims or 0 in dims:
        return "empty", {}
    real = [d for d in dims if d > 1]
    if len(real) == 1:
        return "spectrum", {}
    if len(dims) == 2 and dims[1] <= 20 and dims[0] >= 10 * dims[1]:
        # e.g. old SDSS spSpec / IRAF multispec: a few long rows
        return "spectra", {}
    if len(real) >= 3:
        return "cube", {}
    return "image", {}


def hdu_summary(path):
    out = []
    with open_fits(path) as hdul:
        for i, hdu in enumerate(hdul):
            hdr = hdu.header
            kind, _ = classify(hdu)
            item = {
                "index": i,
                "name": hdu.name or ("PRIMARY" if i == 0 else ""),
                "ver": hdu.ver if hasattr(hdu, "ver") else 1,
                "hdutype": type(hdu).__name__,
                "kind": kind,
                "ncards": len(hdr),
                "object": str(hdr.get("OBJECT", "")),
            }
            if isinstance(hdu, (fits.BinTableHDU, fits.TableHDU)):
                item["nrows"] = int(hdr.get("NAXIS2", 0))
                item["ncols"] = int(hdr.get("TFIELDS", 0))
                item["dims"] = f"{item['ncols']} cols × {item['nrows']} rows"
            else:
                dims = _image_dims(hdr)
                item["shape"] = dims
                item["bitpix"] = int(hdr.get("BITPIX", 0))
                item["dims"] = " × ".join(map(str, dims)) if dims else "—"
            out.append(item)
    return out


def header_cards(path, index):
    with open_fits(path) as hdul:
        hdr = hdul[index].header
        cards = []
        for card in hdr.cards:
            value = card.value
            if isinstance(value, bool):
                value = "T" if value else "F"
            elif not isinstance(value, (int, float, str)):
                value = str(value)
            elif isinstance(value, float) and not math.isfinite(value):
                value = str(value)
            cards.append({"key": card.keyword, "value": value, "comment": card.comment})
        return {"cards": cards, "text": hdr.tostring(sep="\n").rstrip()}


# ---------------------------------------------------------------- tables

def _col_info(col, field_dtype):
    shape = list(field_dtype.shape) if field_dtype is not None else []
    fmt = str(col.format)
    m = VLA_RE.match(fmt)
    vla = m is not None
    kind = field_dtype.base.kind if field_dtype is not None else "O"
    numeric = (m.group(1) not in "AL") if vla else kind in "iuf"
    return {
        "name": col.name,
        "format": fmt,
        "unit": col.unit or "",
        "dim": col.dim or "",
        "null": None if col.null is None else str(col.null),
        "disp": col.disp or "",
        "shape": shape,
        "vla": vla,
        "numeric": bool(numeric),
        "vector": bool(shape) or bool(vla),
    }


def guess_spectrum_columns(columns):
    names = list(columns.names)
    x = next((n for n in names if WAVE_RE.match(n)), None)
    y = next((n for n in names if FLUX_RE.match(n) and n != x), None)
    err = next((n for n in names if ERR_RE.match(n) and n not in (x, y)), None)
    return {"x": x, "y": y, "err": err}


def table_info(path, index):
    with open_fits(path) as hdul:
        hdu = hdul[index]
        data = hdu.data
        cols = []
        for col in hdu.columns:
            dt = data.dtype[col.name] if data is not None else None
            cols.append(_col_info(col, dt))
        nrows = 0 if data is None else len(data)
        guess = guess_spectrum_columns(hdu.columns)
        return {"columns": cols, "nrows": nrows, "guess": guess}


def _jsonable_scalar(v):
    if isinstance(v, (bytes, np.bytes_)):
        return v.decode("ascii", "replace").rstrip()
    if isinstance(v, (np.bool_, bool)):
        return bool(v)
    if isinstance(v, (np.integer,)):
        return int(v)
    if isinstance(v, (np.floating, float)):
        f = float(v)
        return f if math.isfinite(f) else str(f)
    if isinstance(v, np.str_):
        return str(v).rstrip()
    if isinstance(v, np.ma.core.MaskedConstant):
        return None
    return v if isinstance(v, (int, str)) else str(v)


def _jsonable_cell(v):
    if isinstance(v, np.ndarray):
        if v.dtype.kind in "SU":
            if v.ndim == 0:
                return _jsonable_scalar(v[()])
            flat = [_jsonable_scalar(x) for x in v.ravel()[:8]]
            return {"array": True, "shape": list(v.shape), "head": flat}
        if v.size <= 6:
            return [_jsonable_scalar(x) for x in v.ravel()]
        return {
            "array": True,
            "shape": list(v.shape),
            "head": [_jsonable_scalar(x) for x in v.ravel()[:3]],
        }
    return _jsonable_scalar(v)


def table_rows(path, index, start, count):
    with open_fits(path) as hdul:
        hdu = hdul[index]
        data = hdu.data
        if data is None:
            return {"rows": [], "start": 0, "nrows": 0}
        n = len(data)
        start = max(0, min(start, n))
        stop = min(n, start + count)
        chunk = data[start:stop]
        names = hdu.columns.names
        fields = [chunk.field(name) for name in names]
        rows = []
        for r in range(stop - start):
            rows.append([_jsonable_cell(f[r]) for f in fields])
        return {"rows": rows, "start": start, "nrows": n}


def _to_float_list(arr):
    arr = np.asarray(arr, dtype=float).ravel()
    return [None if not math.isfinite(v) else v for v in arr.tolist()]


def _decimate(*arrays, limit=MAX_PLOT_POINTS):
    n = len(arrays[0])
    if n <= limit:
        return arrays, 1
    step = int(math.ceil(n / limit))
    return tuple(a[::step] if a is not None else None for a in arrays), step


def table_plot(path, index, xcol, ycol, errcol=None, row=None):
    with open_fits(path) as hdul:
        hdu = hdul[index]
        data = hdu.data
        cols = {c.name: c for c in hdu.columns}

        def get(name):
            if name is None or name == "":
                return None
            if name == "__index__":
                return None
            v = data.field(name)
            if row is not None:
                v = v[row]
            return np.asarray(v)

        y = get(ycol)
        if y is None:
            raise ValueError("Y column required")
        if row is None and y.ndim > 1:
            raise ValueError(f"'{ycol}' is an array column — pick a row to plot it")
        y = y.ravel()
        x = get(xcol)
        x = np.arange(len(y)) if x is None else x.ravel()
        xlabel = "row index" if xcol in (None, "", "__index__") else xcol
        if xcol and xcol.lower() == "loglam":
            x, xlabel = 10 ** np.asarray(x, dtype=float), "wavelength (10^loglam)"
        if len(x) != len(y):
            raise ValueError(f"length mismatch: x={len(x)} y={len(y)}")
        err = get(errcol)
        if err is not None:
            err = err.ravel()
            if (errcol or "").lower().startswith("ivar"):
                with np.errstate(divide="ignore", invalid="ignore"):
                    err = np.where(err > 0, 1 / np.sqrt(err), np.nan)
        (x, y, err), step = _decimate(x, y, err)
        unit = lambda n: (cols[n].unit or "") if n in cols else ""
        return {
            "x": _to_float_list(x),
            "y": _to_float_list(y),
            "err": _to_float_list(err) if err is not None else None,
            "xlabel": xlabel,
            "ylabel": ycol,
            "xunit": unit(xcol),
            "yunit": unit(ycol),
            "step": step,
        }


# ---------------------------------------------------------------- images

def _spectral_axis(hdr, n, axis=1):
    crval = hdr.get(f"CRVAL{axis}")
    cdelt = hdr.get(f"CDELT{axis}", hdr.get(f"CD{axis}_{axis}"))
    crpix = hdr.get(f"CRPIX{axis}", 1.0)
    if crval is None or cdelt is None:
        return np.arange(n, dtype=float), "pixel", ""
    x = crval + (np.arange(n) + 1 - crpix) * cdelt
    ctype = str(hdr.get(f"CTYPE{axis}", "")).strip()
    cunit = str(hdr.get(f"CUNIT{axis}", "")).strip()
    if hdr.get("DC-FLAG", 0) == 1 or ctype.upper().startswith("LOG"):
        x = 10 ** x
    return x, ctype or "axis 1", cunit


def image_data(hdu, slice_index=0):
    data = hdu.data
    if data is None:
        raise ValueError("HDU has no data")
    data = np.asarray(data)
    while data.ndim > 2:
        idx = min(slice_index, data.shape[0] - 1) if data.ndim == 3 else 0
        data = data[idx]
    return data


def image_profile(path, index, row=0):
    """1-D spectrum (NAXIS=1) or one row of a 2-D image, with WCS x-axis."""
    with open_fits(path) as hdul:
        hdu = hdul[index]
        hdr = hdu.header
        data = np.asarray(hdu.data)
        data = np.squeeze(data) if data.ndim > 1 and min(data.shape) == 1 else data
        if data.ndim == 1:
            y = data
        else:
            data2 = image_data(hdu)
            row = max(0, min(row, data2.shape[0] - 1))
            y = data2[row]
        x, ctype, cunit = _spectral_axis(hdr, len(y))
        (x, y), step = _decimate(x, y)
        return {
            "x": _to_float_list(x),
            "y": _to_float_list(y),
            "err": None,
            "xlabel": ctype,
            "xunit": cunit,
            "ylabel": str(hdr.get("BUNIT", "value")),
            "yunit": "",
            "step": step,
            "nrows": int(data.shape[0]) if data.ndim > 1 else 1,
        }


def image_stats(path, index, slice_index=0):
    with open_fits(path) as hdul:
        hdu = hdul[index]
        data = image_data(hdu, slice_index)
        sample = data
        if data.size > 4_000_000:
            step = int(math.ceil(math.sqrt(data.size / 4_000_000)))
            sample = data[::step, ::step]
        sample = np.asarray(sample, dtype=float)
        finite = sample[np.isfinite(sample)]
        nslices = int(hdu.data.shape[0]) if hdu.data.ndim == 3 else 1
        if finite.size == 0:
            stats = {}
        else:
            stats = {
                "min": float(finite.min()),
                "max": float(finite.max()),
                "mean": float(finite.mean()),
                "median": float(np.median(finite)),
                "std": float(finite.std()),
            }
        stats.update({
            "shape": list(hdu.data.shape[::-1]),
            "dtype": str(hdu.data.dtype),
            "nan_fraction": float(1 - finite.size / max(sample.size, 1)),
            "nslices": nslices,
            "bunit": str(hdu.header.get("BUNIT", "")),
        })
        return stats
