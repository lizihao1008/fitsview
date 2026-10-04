"""Local Flask server exposing FITS structure / data as a JSON API."""

import os
import tempfile
import traceback
from pathlib import Path

from flask import Flask, Response, jsonify, request, send_from_directory

from . import ds9, fitsinfo, render

STATIC = Path(__file__).parent / "static"
FITS_SUFFIXES = (
    ".fits", ".fit", ".fts", ".fz", ".fits.gz", ".fit.gz", ".fts.gz",
    ".pha", ".pi", ".rmf", ".arf", ".rsp", ".evt", ".lc", ".img", ".mos",
)
UPLOAD_DIR = Path(tempfile.gettempdir()) / "fitsview-uploads"

app = Flask(__name__, static_folder=None)
app.config["INITIAL_FILES"] = []
app.config["START_DIR"] = os.getcwd()


def _path():
    p = request.args.get("path") or (request.get_json(silent=True) or {}).get("path")
    if not p:
        raise ValueError("missing 'path'")
    p = os.path.abspath(os.path.expanduser(p))
    if not os.path.isfile(p):
        raise FileNotFoundError(p)
    return p


def _int(name, default=0):
    v = request.args.get(name)
    return default if v in (None, "") else int(v)


@app.errorhandler(Exception)
def _err(e):
    traceback.print_exc()
    return jsonify({"error": f"{type(e).__name__}: {e}"}), 400


@app.get("/")
def index():
    return send_from_directory(STATIC, "index.html")


@app.get("/static/<path:name>")
def static_file(name):
    return send_from_directory(STATIC, name)


@app.get("/api/initial")
def initial():
    return jsonify({
        "files": app.config["INITIAL_FILES"],
        "start_dir": app.config["START_DIR"],
        "ds9": ds9.ds9_executable(),
    })


@app.get("/api/ls")
def ls():
    d = os.path.abspath(os.path.expanduser(request.args.get("dir") or app.config["START_DIR"]))
    show_all = request.args.get("all") == "1"
    dirs, files = [], []
    with os.scandir(d) as it:
        for e in it:
            if e.name.startswith("."):
                continue
            try:
                if e.is_dir():
                    dirs.append(e.name)
                elif show_all or e.name.lower().endswith(FITS_SUFFIXES):
                    files.append({"name": e.name, "size": e.stat().st_size})
            except OSError:
                continue
    dirs.sort(key=str.lower)
    files.sort(key=lambda f: f["name"].lower())
    return jsonify({"dir": d, "parent": os.path.dirname(d), "dirs": dirs, "files": files})


@app.get("/api/open")
def open_file():
    p = _path()
    return jsonify({
        "path": p,
        "name": os.path.basename(p),
        "size": os.path.getsize(p),
        "hdus": fitsinfo.hdu_summary(p),
    })


@app.get("/api/header")
def header():
    return jsonify(fitsinfo.header_cards(_path(), _int("hdu")))


@app.get("/api/table/info")
def table_info():
    return jsonify(fitsinfo.table_info(_path(), _int("hdu")))


@app.get("/api/table/rows")
def table_rows():
    count = min(_int("count", 100), 1000)
    return jsonify(fitsinfo.table_rows(_path(), _int("hdu"), _int("start"), count))


@app.get("/api/table/plot")
def table_plot():
    row = request.args.get("row")
    return jsonify(fitsinfo.table_plot(
        _path(), _int("hdu"),
        request.args.get("x"), request.args.get("y"), request.args.get("err"),
        None if row in (None, "") else int(row),
    ))


@app.get("/api/image/stats")
def image_stats():
    return jsonify(fitsinfo.image_stats(_path(), _int("hdu"), _int("slice")))


@app.get("/api/image/profile")
def image_profile():
    return jsonify(fitsinfo.image_profile(_path(), _int("hdu"), _int("row")))


@app.get("/api/image/png")
def image_png():
    p, idx = _path(), _int("hdu")
    with fitsinfo.open_fits(p) as hdul:
        data = fitsinfo.image_data(hdul[idx], _int("slice"))
        png = render.render_png(
            data,
            stretch=request.args.get("stretch", "zscale"),
            scale=request.args.get("scale", "linear"),
            cmap=request.args.get("cmap", "gray"),
            max_size=min(_int("max", 1024), 4096),
        )
    return Response(png, mimetype="image/png", headers={"Cache-Control": "no-store"})


@app.post("/api/ds9")
def to_ds9():
    # JSON-only (forces a CORS preflight, so other web pages can't trigger this)
    if not request.is_json:
        return jsonify({"error": "expected JSON"}), 415
    body = request.get_json()
    msg = ds9.open_in_ds9(_path(), int(body.get("hdu", 0)), bool(body.get("new_frame", True)))
    return jsonify({"ok": True, "message": msg})


@app.post("/api/upload")
def upload():
    f = request.files.get("file")
    if f is None or not f.filename:
        raise ValueError("no file uploaded")
    UPLOAD_DIR.mkdir(exist_ok=True)
    dest = UPLOAD_DIR / os.path.basename(f.filename)
    f.save(dest)
    return jsonify({"path": str(dest)})
