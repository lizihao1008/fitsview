"""Command-line entry point:  python -m fitsview [files...]"""

import argparse
import os
import threading
import webbrowser

from .server import app


def main():
    ap = argparse.ArgumentParser(prog="fitsview", description="Browse FITS file structure in your web browser.")
    ap.add_argument("files", nargs="*", help="FITS files to open")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--dir", help="starting directory for the file browser (default: cwd)")
    ap.add_argument("--no-browser", action="store_true", help="don't open a browser window")
    args = ap.parse_args()

    app.config["INITIAL_FILES"] = [os.path.abspath(f) for f in args.files]
    app.config["START_DIR"] = os.path.abspath(
        args.dir or (os.path.dirname(app.config["INITIAL_FILES"][0]) if args.files else os.getcwd())
    )
    url = f"http://127.0.0.1:{args.port}/"
    print(f"fitsview running at {url}  (Ctrl-C to quit)")
    if not args.no_browser:
        threading.Timer(0.8, webbrowser.open, [url]).start()
    app.run(host="127.0.0.1", port=args.port, debug=False, threaded=True)


if __name__ == "__main__":
    main()
