#!/usr/bin/env python3
"""Print a GITHUB_ENV assignment for the latest installed stable Xcode 26."""
from pathlib import Path
import plistlib
import re
import sys


def main():
    candidates = []
    seen = set()
    for candidate in Path("/Applications").glob("Xcode*.app"):
        app = candidate.resolve()
        if app in seen or "beta" in app.name.lower():
            continue
        seen.add(app)
        try:
            with (app / "Contents/Info.plist").open("rb") as stream:
                version = str(plistlib.load(stream)["CFBundleShortVersionString"])
        except (OSError, KeyError, plistlib.InvalidFileException):
            continue
        if re.fullmatch(r"26(?:\.[0-9]+)*", version):
            candidates.append((tuple(int(part) for part in version.split(".")), app))
    if not candidates:
        raise SystemExit("Stable Xcode 26 is not installed. Use the macos-26 runner or install Xcode 26 locally.")
    version, app = max(candidates)
    print(f"Selected Xcode {'.'.join(str(part) for part in version)}: {app}", file=sys.stderr)
    print(f"DEVELOPER_DIR={app / 'Contents/Developer'}")


if __name__ == "__main__":
    main()
