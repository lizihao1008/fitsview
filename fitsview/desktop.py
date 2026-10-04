"""Desktop entry point: the Flask app in a native window via pywebview."""

import json
import os
import socket
import sys
import threading

import webview
from webview.dom import DOMEventHandler
from webview.menu import Menu, MenuAction
from werkzeug.serving import make_server

from .server import app

FILE_TYPES = (
    "FITS files (*.fits;*.fit;*.fts;*.fz;*.gz;*.pha;*.pi;*.rmf;*.arf;*.rsp;*.evt;*.lc;*.img)",
    "All files (*.*)",
)


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Api:
    """Methods callable from JS as window.pywebview.api.*"""

    def __init__(self):
        self.window = None

    def open_dialog(self):
        res = self.window.create_file_dialog(
            webview.FileDialog.OPEN, allow_multiple=True, file_types=FILE_TYPES)
        return list(res or [])


def _open_in_ui(window, paths):
    for p in paths:
        window.evaluate_js(f"openFile({json.dumps(p)})")


def _on_drop(window, event):
    # pywebview fills in the real path, so no upload/temp copy is needed
    paths = [f.get("pywebviewFullPath") for f in event.get("dataTransfer", {}).get("files", [])]
    _open_in_ui(window, [p for p in paths if p])


def _install_open_files_handler(window):
    """Finder "Open With" / Dock-icon drops while the app is already running.

    (PyInstaller's argv emulation only covers files passed at launch.)"""
    if sys.platform != "darwin":
        return
    try:
        import AppKit
        import objc
    except ImportError:
        return
    delegate = AppKit.NSApplication.sharedApplication().delegate()
    if delegate is None:
        return

    def application_openFiles_(self, nsapp, filenames):
        # we're on the AppKit main thread; evaluate_js blocks waiting for it
        paths = [str(f) for f in filenames]
        threading.Thread(target=_open_in_ui, args=(window, paths), daemon=True).start()
        nsapp.replyToOpenOrPrint_(AppKit.NSApplicationDelegateReplySuccess)

    objc.classAddMethods(type(delegate), [
        objc.selector(application_openFiles_, selector=b"application:openFiles:", signature=b"v@:@@"),
    ])


def _on_ready(window):
    window.dom.document.events.drop += DOMEventHandler(lambda e: _on_drop(window, e), True, False)
    _install_open_files_handler(window)


def main():
    files = [os.path.abspath(f) for f in sys.argv[1:] if not f.startswith("-psn_") and os.path.isfile(f)]
    app.config["INITIAL_FILES"] = files
    start = os.path.dirname(files[0]) if files else os.getcwd()
    if start in ("/", "") or not os.access(start, os.R_OK):
        start = os.path.expanduser("~")  # Finder launches .app bundles with cwd=/
    app.config["START_DIR"] = start

    port = _free_port()
    server = make_server("127.0.0.1", port, app, threaded=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    api = Api()
    window = webview.create_window(
        "FITSView", f"http://127.0.0.1:{port}/", js_api=api,
        width=1320, height=880, min_size=(720, 480), text_select=True,
    )
    api.window = window
    menu = [Menu("File", [MenuAction("Open…", lambda: _open_in_ui(window, api.open_dialog()))])]
    webview.start(_on_ready, window, menu=menu, private_mode=False)
    server.shutdown()


if __name__ == "__main__":
    main()
