#!/usr/bin/env python3
"""Optional, one-shot iPhone/iPad empty-state launch screenshots on a Mac."""
from pathlib import Path
import argparse
import json
import platform
import subprocess
import time


def command(*args, capture=False):
    return subprocess.run(args, check=True, text=True, capture_output=capture).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("build/simulator-evidence"))
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("Requires macOS, Xcode and available iOS simulator runtimes.")
    if not args.app.is_dir():
        raise SystemExit(f"Built simulator app is missing: {args.app}")
    args.output.mkdir(parents=True, exist_ok=True)
    inventory = json.loads(command("xcrun", "simctl", "list", "devices", "available", "--json", capture=True))
    devices = [device for runtime, group in inventory["devices"].items() if ".iOS-" in runtime for device in group]
    report = {"scope": "Simulator empty-state launch only; no capture, AirPods, real-device, recovery or cloud verification.",
              "xcode": command("xcodebuild", "-version", capture=True), "captures": []}
    for family in ["iPhone", "iPad"]:
        choices = [device for device in devices if device["name"].startswith(family)]
        if not choices:
            raise SystemExit(f"No available {family} simulator. Install an iOS runtime.")
        if family == "iPad":
            # Prefer a wide iPad to expose the multicolumn shell in the evidence.
            device = max(choices, key=lambda item: ("13-inch" in item["name"] or "12.9-inch" in item["name"], "Pro" in item["name"], item["name"]))
        else:
            device = choices[-1]
        device_id = device["udid"]
        was_booted = device["state"] == "Booted"
        try:
            if not was_booted:
                command("xcrun", "simctl", "boot", device_id)
            command("xcrun", "simctl", "bootstatus", device_id, "-b")
            command("xcrun", "simctl", "install", device_id, str(args.app.resolve()))
            for appearance, content_size in [("light", "large"), ("dark", "accessibility-extra-extra-extra-large")]:
                command("xcrun", "simctl", "ui", device_id, "appearance", appearance)
                command("xcrun", "simctl", "ui", device_id, "content_size", content_size)
                command("xcrun", "simctl", "launch", "--terminate-running-process", device_id, "studio.mycover.app")
                time.sleep(3)
                image = args.output / f"{family}-{appearance}-{content_size}.png"
                command("xcrun", "simctl", "io", device_id, "screenshot", str(image))
                report["captures"].append({"device": device["name"], "udid": device_id, "appearance": appearance,
                                           "contentSize": content_size, "image": image.name})
        finally:
            if not was_booted:
                command("xcrun", "simctl", "shutdown", device_id)
    (args.output / "scope.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
