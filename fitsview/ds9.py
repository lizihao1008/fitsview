"""Send an HDU to SAOImage DS9: via XPA if ds9 is running, else launch it."""

import os
import shutil
import subprocess

_MAC_DS9 = "/Applications/SAOImageDS9.app/Contents/MacOS/ds9"
# The macOS DS9 8.x bundle registers its XPA access point under user "root",
# which the default (current-user-only) template never matches.
_XPA_USERS = ["-u", "*"]
# GUI-launched processes often lack these on PATH
_EXTRA_BIN = ["/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin", os.path.expanduser("~/bin")]


def _tool(name):
    found = shutil.which(name)
    if found:
        return found
    for d in _EXTRA_BIN:
        cand = os.path.join(d, name)
        if os.access(cand, os.X_OK):
            return cand
    return None


def ds9_executable():
    for cand in (os.environ.get("FITSVIEW_DS9"), _tool("ds9"), _MAC_DS9):
        if cand and os.path.exists(cand):
            return cand
    return None


def _xpa(tool, *args):
    out = subprocess.run([_tool(tool), *_XPA_USERS, *args], capture_output=True, text=True, timeout=15)
    # xpaaccess reports via stdout and exits non-zero even on success
    failed = out.returncode != 0 and tool != "xpaaccess"
    if failed or "XPA$ERROR" in out.stdout + out.stderr:
        raise RuntimeError((out.stderr or out.stdout).strip() or f"{tool} failed")
    return out.stdout.strip()


def _running():
    if not (_tool("xpaaccess") and _tool("xpaset")):
        return False
    try:
        return _xpa("xpaaccess", "-n", "ds9") not in ("", "0")
    except (OSError, RuntimeError, subprocess.TimeoutExpired):
        return False


def open_in_ds9(path, index, new_frame=True):
    path = os.path.abspath(path)
    target = f"{path}[{index}]"
    if _running():
        if new_frame:
            _xpa("xpaset", "-p", "ds9", "frame", "new")
        # braces protect paths containing spaces in ds9's Tcl parser
        _xpa("xpaset", "-p", "ds9", "fits", "{" + target + "}" if " " in target else target)
        _xpa("xpaset", "-p", "ds9", "scale", "mode", "zscale")
        _xpa("xpaset", "-p", "ds9", "zoom", "to", "fit")
        return "sent to running ds9 (new frame)" if new_frame else "sent to running ds9"
    exe = ds9_executable()
    if exe is None:
        raise RuntimeError("ds9 not found — set FITSVIEW_DS9 to the ds9 executable")
    subprocess.Popen(
        [exe, target, "-scale", "mode", "zscale", "-zoom", "to", "fit"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return "launched ds9"
