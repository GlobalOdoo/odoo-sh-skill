"""Patch the installed odouche so `osh auth login` works with any Chromium-family browser.

Two changes to odouche/_upstream/browser.py, both marked "odoo-sh skill patch":

1. Pick the browser: $OSH_BROWSER, then the path in ~/.config/odouche/browser, then the usual
   names on PATH (skipping /snap/bin launchers, which never answer odouche), then browsers that
   live inside a snap (Brave, Chromium). Upstream only looks for a fixed list of names.
2. Wait for the window: upstream asks the browser for its window once, right at launch. Brave
   and Chrome for Testing answer "none yet" and open it a second later, so the login failed with
   "The browser did not open a window to log in from." Now it asks again for up to 15 s.

Run with the Python of the odouche tool (setup.sh does this). Safe to run twice. Exits 1 if
upstream changed the code this patch expects — then check whether upstream fixed it.
"""

import os
import sys
from pathlib import Path

import odouche._upstream.browser as browser_module

MARK = "# odoo-sh skill patch"

FIND_OLD = '''def find(environ: Mapping[str, str] = os.environ) -> str | None:
    """Return a Chromium-family browser that can open a window here, or nothing."""
    if sys.platform == "win32":
        return None
    if sys.platform == "darwin":
        return next((path for path in _APPLICATIONS if os.access(path, os.X_OK)), None)
    if not (environ.get("DISPLAY") or environ.get("WAYLAND_DISPLAY")):
        return None
    return next((path for path in map(shutil.which, _NAMES) if path), None)
'''

FIND_NEW = '''# odoo-sh skill patch: more browsers, and a browser the user picks.
_MORE_NAMES = ("brave-browser-stable", "brave", "vivaldi-stable", "vivaldi", "opera")
_MORE_APPLICATIONS = (
    "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi",
    "/Applications/Opera.app/Contents/MacOS/Opera",
    "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
)
# The browser itself inside a snap: the /snap/bin launcher never answers on the debugging pipe.
_SNAP_BROWSERS = {
    "brave": "/snap/brave/current/opt/brave.com/brave/brave",
    "chromium": "/snap/chromium/current/usr/lib/chromium-browser/chrome",
}
_INSIDE_SNAPS = tuple(_SNAP_BROWSERS.values())
_CONFIG = os.path.join(os.path.expanduser("~"), ".config", "odouche", "browser")


def _configured(environ: Mapping[str, str]) -> str | None:
    """Return the browser named by $OSH_BROWSER or by the first line of ~/.config/odouche/browser."""
    chosen = environ.get("OSH_BROWSER", "").strip()
    if not chosen:
        with suppress(OSError):
            with open(_CONFIG, encoding="utf-8") as file:
                chosen = file.readline().strip()
    if not chosen:
        return None
    path = chosen if os.path.isabs(chosen) else shutil.which(chosen)
    if path and os.path.realpath(path) == "/usr/bin/snap":
        path = _SNAP_BROWSERS.get(os.path.basename(path))
    return path if path and os.access(path, os.X_OK) else None


def find(environ: Mapping[str, str] = os.environ) -> str | None:
    """Return a Chromium-family browser that can open a window here, or nothing."""
    if sys.platform == "win32":
        return None
    if sys.platform == "darwin":
        chosen = _configured(environ)
        if chosen:
            return chosen
        paths = (*_APPLICATIONS, *_MORE_APPLICATIONS)
        return next((path for path in paths if os.access(path, os.X_OK)), None)
    if not (environ.get("DISPLAY") or environ.get("WAYLAND_DISPLAY")):
        return None
    chosen = _configured(environ)
    if chosen:
        return chosen
    for path in map(shutil.which, (*_NAMES, *_MORE_NAMES)):
        if path and not os.path.realpath(path).startswith(("/snap/bin/", "/usr/bin/snap")):
            return path
    return next((path for path in _INSIDE_SNAPS if os.access(path, os.X_OK)), None)
'''

ATTACH_OLD = '''    def _attach(self) -> None:
        targets = (self._ask("Target.getTargets") or {}).get("targetInfos")
        for target in cast("list[object]", targets) if isinstance(targets, list) else ():
            fields = cast("dict[str, object]", target) if isinstance(target, dict) else {}
            if fields.get("type") != "page":
                continue
            attached = self._ask("Target.attachToTarget", {"targetId": fields.get("targetId"), "flatten": True})
            page = (attached or {}).get("sessionId")
            if isinstance(page, str):
                self._page = page
                break
        else:
            raise LoginError("The browser did not open a window to log in from.")
'''

ATTACH_NEW = '''    def _attach(self) -> None:
        # odoo-sh skill patch: a browser can answer before its first window exists, so ask again for a while.
        deadline = time.monotonic() + 15.0
        while self._page is None:
            targets = (self._ask("Target.getTargets") or {}).get("targetInfos")
            for target in cast("list[object]", targets) if isinstance(targets, list) else ():
                fields = cast("dict[str, object]", target) if isinstance(target, dict) else {}
                if fields.get("type") != "page":
                    continue
                attached = self._ask("Target.attachToTarget", {"targetId": fields.get("targetId"), "flatten": True})
                page = (attached or {}).get("sessionId")
                if isinstance(page, str):
                    self._page = page
                    break
            if self._page is None:
                if time.monotonic() > deadline:
                    raise LoginError("The browser did not open a window to log in from.")
                time.sleep(0.5)
'''


def main() -> int:
    path = Path(browser_module.__file__)
    text = path.read_text(encoding="utf-8")
    if MARK in text:
        print(f"already patched: {path}")
        return 0
    if text.count(FIND_OLD) != 1 or text.count(ATTACH_OLD) != 1:
        print(
            f"cannot patch {path}: upstream changed the code this patch expects.\n"
            "Try `osh auth login`; if the browser opens and the login completes, no patch is needed.",
            file=sys.stderr,
        )
        return 1
    backup = path.with_suffix(".py.orig")
    if not backup.exists():
        backup.write_text(text, encoding="utf-8")
    # A new file swapped in, never a write in place: uv hard-links installed files to its cache,
    # and writing through the link would patch the cache, and every later install, too.
    fresh = path.with_suffix(".py.new")
    fresh.write_text(text.replace(FIND_OLD, FIND_NEW).replace(ATTACH_OLD, ATTACH_NEW), encoding="utf-8")
    os.replace(fresh, path)
    print(f"patched: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
