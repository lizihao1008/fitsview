"""Render a 2-D array to a PNG quick-look (no Pillow / matplotlib needed)."""

import math
import struct
import warnings
import zlib

import numpy as np
from astropy.visualization import ZScaleInterval

# anchor colours for simple colormaps, interpolated into 256-entry LUTs
_CMAP_ANCHORS = {
    "gray": [(0, 0, 0), (255, 255, 255)],
    "heat": [(0, 0, 0), (140, 20, 0), (230, 110, 0), (255, 220, 80), (255, 255, 255)],
    "viridis": [(68, 1, 84), (59, 82, 139), (33, 145, 140), (94, 201, 98), (253, 231, 37)],
    "cool": [(0, 0, 0), (20, 40, 120), (40, 140, 220), (160, 230, 255), (255, 255, 255)],
}


def _lut(name):
    anchors = np.array(_CMAP_ANCHORS.get(name, _CMAP_ANCHORS["gray"]), dtype=float)
    pos = np.linspace(0, 1, len(anchors))
    t = np.linspace(0, 1, 256)
    return np.stack([np.interp(t, pos, anchors[:, c]) for c in range(3)], axis=1).astype(np.uint8)


def _encode_png(rgb):
    h, w, _ = rgb.shape
    raw = b"".join(b"\x00" + rgb[y].tobytes() for y in range(h))

    def chunk(tag, payload):
        body = tag + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b"")
    )


def _bin_down(data, max_size):
    """Block-average so the longest side is <= max_size (NaN-aware)."""
    h, w = data.shape
    f = int(math.ceil(max(h, w) / max_size))
    if f <= 1:
        return data
    h2, w2 = h // f, w // f
    blocks = data[: h2 * f, : w2 * f].reshape(h2, f, w2, f)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        return np.nanmean(blocks, axis=(1, 3))


def render_png(data, stretch="zscale", scale="linear", cmap="gray", max_size=1024):
    data = np.asarray(data, dtype=float)
    if data.ndim == 1:
        data = data[np.newaxis, :]
    data = _bin_down(data, max_size)
    finite = np.isfinite(data)
    if not finite.any():
        norm = np.zeros_like(data)
    else:
        vals = data[finite]
        if stretch == "minmax":
            lo, hi = vals.min(), vals.max()
        elif stretch.startswith("p"):  # p99, p99.5 ...
            pct = float(stretch[1:])
            lo, hi = np.percentile(vals, [100 - pct, pct])
        else:
            lo, hi = ZScaleInterval().get_limits(vals)
        if hi <= lo:
            hi = lo + 1
        norm = np.clip((data - lo) / (hi - lo), 0, 1)
        if scale == "log":
            norm = np.log10(1 + 999 * norm) / 3
        elif scale == "sqrt":
            norm = np.sqrt(norm)
        elif scale == "asinh":
            norm = np.arcsinh(10 * norm) / np.arcsinh(10)
    idx = np.nan_to_num(norm * 255, nan=0).astype(np.uint8)
    rgb = _lut(cmap)[idx]
    rgb[~finite] = (90, 30, 90)  # NaNs in muted purple
    return _encode_png(np.ascontiguousarray(rgb[::-1]))  # FITS origin is lower-left
