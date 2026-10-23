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
    console = (output / "media-smoke-console.log").open("w", encoding="utf-8")
    launcher = subprocess.Popen(["xcrun", "simctl", "launch", "--terminate-running-process", "--console", device_id,
                                 "studio.mycover.app", "--media-smoke"], stdin=subprocess.DEVNULL, stdout=console, stderr=subprocess.STDOUT)
    deadline = time.monotonic() + 120
    try:
        while time.monotonic() < deadline:
            try:
                if source.exists() and source.stat().st_mtime >= launched_at - 1:
                    result = json.loads(source.read_text(encoding="utf-8"))
                    shutil.copy2(source, output / "MediaSmokeReport.json")
                    if result.get("finishedAt"):
                        if result.get("passed") is not True:
                            raise RuntimeError("Synthetic media smoke failed: " + json.dumps(result.get("errors", []), ensure_ascii=False)[:2000])
                        print("Synthetic media smoke passed; this does not validate camera capture or real-device audio.")
                        return
                if launcher.poll() is not None:
                    raise RuntimeError(f"Media smoke launcher exited ({launcher.returncode}) before its final report; see console and diagnostic logs.")
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(2)
        raise RuntimeError("No finalized MediaSmokeReport.json within 120 seconds; inspect stage and console diagnostics.")
    finally:
        if launcher.poll() is None:
            launcher.terminate()
            try:
                launcher.wait(timeout=10)
            except subprocess.TimeoutExpired:
                launcher.kill()
        console.close()
        # Simulator crash reports may be written after the launch pipe closes.
        # Collect a short synthetic-process log as well as delayed crash reports.
        try:
            diagnostic = command("xcrun", "simctl", "spawn", device_id, "log", "show", "--last", "3m", "--style", "compact",
                                 "--predicate", 'process == "MyCoverStudio" OR eventMessage CONTAINS "studio.mycover.app"', capture=True, timeout=30)
            (output / "media-smoke-diagnostics.log").write_text(diagnostic, encoding="utf-8")
        except subprocess.SubprocessError as error:
            (output / "media-smoke-diagnostics.log").write_text(str(error), encoding="utf-8")
        # Only generated test metadata, never user-library files or media bytes.
        if source.exists():
            result = json.loads(source.read_text(encoding="utf-8"))
            fixture = Path(result.get("temporaryRoot", ""))
            if container.resolve() in fixture.resolve().parents:
                queue = fixture / "fixture/exports/queue.json"
                if queue.exists():
                    shutil.copy2(queue, output / "media-smoke-export-queue.json")
        frame_root = container / "Documents/MediaSmokeFrames"
        if frame_root.is_dir():
            shutil.copytree(frame_root, output / "media-frames", dirs_exist_ok=True)
        for crash_root in [Path.home() / "Library/Logs/DiagnosticReports", container.parents[3] / "Library/Logs/CrashReporter"]:
            for crash in crash_root.glob("MyCoverStudio*.ips"):
                if crash.stat().st_mtime >= launched_at - 1:
                    shutil.copy2(crash, output / crash.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("build/simulator-evidence"))
    parser.add_argument("--media-only", action="store_true", help="Check offline export on one simulator without repeating layout captures.")
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
    for family in (["iPhone"] if args.media_only else ["iPhone", "iPad"]):
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
            captures = [] if args.media_only else [("light", "large"), ("dark", "accessibility-extra-extra-extra-extra-large")]
            for appearance, content_size in captures:
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
