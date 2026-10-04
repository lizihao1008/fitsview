"""Draw the app icon (1024² RGBA PNG) with numpy, then build FITSView.icns via iconutil."""

import shutil
import struct
import subprocess
import zlib
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
N, SS = 1024, 2  # output size, supersampling factor


def png_rgba(arr):
    h, w, _ = arr.shape
    raw = b"".join(b"\x00" + arr[y].tobytes() for y in range(h))
    chunk = lambda t, p: struct.pack(">I", len(p)) + t + p + struct.pack(">I", zlib.crc32(t + p) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def draw():
    n = N * SS
    y, x = (np.mgrid[:n, :n] + 0.5) / n  # 0..1
    img = np.zeros((n, n, 4))

    # rounded-square plate (macOS icon grid: ~10% margin, ~22% corner radius)
    m, r = 0.098, 0.18
    dx = np.maximum(np.abs(x - 0.5) - (0.5 - m - r), 0)
    dy = np.maximum(np.abs(y - 0.5) - (0.5 - m - r), 0)
    plate = np.hypot(dx, dy) <= r
    top, bottom = np.array([0.10, 0.13, 0.22]), np.array([0.03, 0.04, 0.09])
    bg = top + (bottom - top) * y[..., None]
    img[..., :3] = bg
    img[..., 3] = plate

    # galaxy: tilted elliptical glow with a bright core
    cx, cy, ang = 0.5, 0.43, np.deg2rad(-28)
    u = (x - cx) * np.cos(ang) + (y - cy) * np.sin(ang)
    v = -(x - cx) * np.sin(ang) + (y - cy) * np.cos(ang)
    rr = np.hypot(u / 0.27, v / 0.10)
    glow = np.exp(-rr ** 2 * 2.2) * 0.85 + np.exp(-(np.hypot(u, v) / 0.035) ** 2)
    ring = np.exp(-((rr - 1.0) / 0.035) ** 2) * 0.55
    col_glow = np.array([0.42, 0.61, 1.0])
    col_core = np.array([1.0, 0.95, 0.85])
    core = np.exp(-(np.hypot(u, v) / 0.05) ** 2)[..., None]
    light = (glow + ring)[..., None] * (col_glow * (1 - core) + col_core * core)
    img[..., :3] = 1 - (1 - img[..., :3]) * (1 - np.clip(light, 0, 1))  # screen blend

    # a few stars
    rng = np.random.default_rng(3)
    for sx, sy, s in zip(rng.uniform(0.18, 0.82, 14), rng.uniform(0.17, 0.62, 14), rng.uniform(0.004, 0.009, 14)):
        star = np.exp(-(np.hypot(x - sx, y - sy) / s) ** 2)[..., None]
        img[..., :3] = 1 - (1 - img[..., :3]) * (1 - star * 0.9)

    # spectrum trace across the lower third
    xs = np.linspace(0.17, 0.83, 4000)
    t = (xs - 0.17) / 0.66
    ys = 0.78 - 0.04 * t - 0.16 * np.exp(-((t - 0.38) / 0.012) ** 2) - 0.09 * np.exp(-((t - 0.70) / 0.015) ** 2) \
        - 0.05 * np.exp(-((t - 0.25) / 0.01) ** 2)
    # stamp anti-aliased discs along the path (true distance to the polyline)
    rad = 0.0085 * n
    dist = np.full((n, n), np.inf)
    win = int(rad) + 3
    for px, py in zip(xs * n, ys * n):
        i0, j0 = int(py) - win, int(px) - win
        yy, xx = np.mgrid[i0:i0 + 2 * win, j0:j0 + 2 * win] + 0.5
        d = np.hypot(xx - px, yy - py)
        sl = dist[i0:i0 + 2 * win, j0:j0 + 2 * win]
        np.minimum(sl, d, out=sl)
    line = np.clip(rad - dist + 0.5, 0, 1)
    green = np.array([0.33, 0.85, 0.62])
    img[..., :3] = img[..., :3] * (1 - line[..., None]) + green * line[..., None]

    img[..., :3] *= img[..., 3:4]  # keep transparent area clean
    out = img.reshape(N, SS, N, SS, 4).mean(axis=(1, 3))
    rgb = out[..., :3] / np.maximum(out[..., 3:4], 1e-6)
    return (np.dstack([rgb, out[..., 3:4]]).clip(0, 1) * 255).round().astype(np.uint8)


def main():
    master = HERE / "icon_1024.png"
    master.write_bytes(png_rgba(np.ascontiguousarray(draw())))
    iconset = HERE / "FITSView.iconset"
    shutil.rmtree(iconset, ignore_errors=True)
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            subprocess.run(["sips", "-z", str(px), str(px), str(master), "--out", str(iconset / name)],
                           check=True, capture_output=True)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(HERE / "FITSView.icns")], check=True)
    shutil.rmtree(iconset)
    print("wrote", HERE / "FITSView.icns")


if __name__ == "__main__":
    main()
