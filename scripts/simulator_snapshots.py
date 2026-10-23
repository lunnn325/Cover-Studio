#!/usr/bin/env python3
"""One-shot simulator screenshots and a small synthetic media pipeline check."""
from pathlib import Path
import argparse
import json
import platform
import shutil
import subprocess
import time


def command(*args, capture=False, timeout=180):
    print("Running: " + " ".join(args), flush=True)
    return subprocess.run(args, check=True, text=True, capture_output=capture, timeout=timeout).stdout


def media_smoke(device_id, output):
    container = Path(command("xcrun", "simctl", "get_app_container", device_id, "studio.mycover.app", "data", capture=True).strip())
    source = container / "Documents/MediaSmokeReport.json"
    launched_at = time.time()
    command("xcrun", "simctl", "launch", "--terminate-running-process", device_id, "studio.mycover.app", "--media-smoke")
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            # Never accept a report left by an earlier simulator launch.
            if source.exists() and source.stat().st_mtime >= launched_at - 1:
                result = json.loads(source.read_text(encoding="utf-8"))
                # Keep in-progress diagnostics, but only judge a finalized report.
                shutil.copy2(source, output / "MediaSmokeReport.json")
                if result.get("finishedAt"):
                    if result.get("passed") is not True:
                        raise RuntimeError("Synthetic media smoke failed: " + json.dumps(result.get("errors", []), ensure_ascii=False)[:2000])
                    print("Synthetic media smoke passed; this does not validate camera capture or real-device audio.")
                    return
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(2)
    raise RuntimeError("No fresh MediaSmokeReport.json within 120 seconds; media pipeline smoke is unverified.")


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
    report = {"scope": "Simulator empty-state launch plus synthetic 2-second media pipeline only; no capture, AirPods, real-device recovery or cloud verification.",
              "xcode": command("xcodebuild", "-version", capture=True), "captures": []}
    smoke_error = None
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
            command("xcrun", "simctl", "bootstatus", device_id, "-b", timeout=300)
            command("xcrun", "simctl", "install", device_id, str(args.app.resolve()))
            for appearance, content_size in [("light", "large"), ("dark", "accessibility-extra-extra-extra-large")]:
                command("xcrun", "simctl", "ui", device_id, "appearance", appearance)
                command("xcrun", "simctl", "ui", device_id, "content_size", content_size)
                command("xcrun", "simctl", "launch", "--terminate-running-process", device_id, "studio.mycover.app")
                # The first cold launch can still display the launch surface after
                # simctl returns (observed on the milestone runner). Allow it to render.
                time.sleep(20 if appearance == "light" else 5)
                image = args.output / f"{family}-{appearance}-{content_size}.png"
                command("xcrun", "simctl", "io", device_id, "screenshot", str(image))
                report["captures"].append({"device": device["name"], "udid": device_id, "appearance": appearance,
                                           "contentSize": content_size, "image": image.name})
            if family == "iPhone":
                try:
                    media_smoke(device_id, args.output)
                    report["mediaSmoke"] = {"passed": True, "report": "MediaSmokeReport.json"}
                except (RuntimeError, subprocess.SubprocessError) as error:
                    # Still collect iPad layout evidence before failing the chosen check.
                    smoke_error = str(error)
                    report["mediaSmoke"] = {"passed": False, "error": smoke_error}
        finally:
            (args.output / "scope.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
            if not was_booted:
                command("xcrun", "simctl", "shutdown", device_id, timeout=60)
    if smoke_error:
        raise SystemExit(smoke_error)


if __name__ == "__main__":
    main()
