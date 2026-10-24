#!/usr/bin/env python3
"""One manually selected native startup/recovery UI workflow, without media checks."""
from pathlib import Path
import argparse
import hashlib
import json
import platform
import subprocess

from simulator_snapshots import command


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=["iPhone", "iPad"], default="iPhone")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("Requires macOS, Xcode and an iOS/iPadOS simulator.")
    output = Path("build/startup-ui-evidence")
    output.mkdir(parents=True, exist_ok=True)
    bundle = Path("build/StartupUI.xcresult")
    report = {"scope": "One native " + args.family + " simulator UI workflow using isolated generated metadata/raw bytes. No playable media, hardware capture, AirPods, real-device recovery or cloud/provider validation.",
              "passed": False, "errors": []}
    inventory = json.loads(command("xcrun", "simctl", "list", "devices", "available", "--json", capture=True))
    choices = [item for runtime, group in inventory["devices"].items() if ".iOS-" in runtime
               for item in group if item["name"].startswith(args.family)]
    if not choices:
        raise SystemExit("No available " + args.family + " simulator.")
    if args.family == "iPad":
        device = max(choices, key=lambda item: ("13-inch" in item["name"] or "12.9-inch" in item["name"], "Pro" in item["name"], item["name"]))
    else:
        device = max(choices, key=lambda item: (item["name"] == "iPhone 17 Pro", "Pro" in item["name"], item["name"]))
    report["family"] = args.family
    report["device"] = device["name"]
    report["testArchitecture"] = platform.machine()
    device_id, was_booted = device["udid"], device["state"] == "Booted"
    try:
        (output / "scope.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        if not was_booted:
            command("xcrun", "simctl", "boot", device_id)
        command("xcrun", "simctl", "bootstatus", device_id, "-b", timeout=300)
        command("xcrun", "simctl", "ui", device_id, "appearance", "light")
        with (output / "xcodebuild-test.log").open("w", encoding="utf-8") as stream:
            result = subprocess.run([
                "xcodebuild", "test", "-project", "MyCoverStudio.xcodeproj", "-scheme", "MyCoverStudio",
                "-configuration", "Debug", "-sdk", "iphonesimulator", "-destination", "id=" + device_id,
                "-derivedDataPath", "build/DerivedData", "-resultBundlePath", str(bundle),
                "-only-testing:StartupUITests/StartupRecoveryUITests/testStartupAndIndexRecovery",
                "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
                "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "180",
                "ONLY_ACTIVE_ARCH=YES", "ARCHS=" + platform.machine(), "CODE_SIGNING_ALLOWED=NO"], stdout=stream, stderr=subprocess.STDOUT, timeout=600)
        if bundle.exists():
            summary = json.loads(command("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle), capture=True))
            (output / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
            command("xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle), "--output-path", str(output / "attachments"))
            report["passedTests"] = summary.get("passedTests", 0)
            report["failedTests"] = summary.get("failedTests", 0)
        if result.returncode != 0 or report.get("passedTests") != 1 or report.get("failedTests") != 0:
            raise RuntimeError("Native UI workflow did not pass exactly one selected test; inspect xcodebuild-test.log and attachments.")
        container = Path(command("xcrun", "simctl", "get_app_container", device_id, "studio.mycover.app", "data", capture=True).strip())
        fixture = json.loads((container / "Documents/StartupUIFixture.json").read_text(encoding="utf-8"))
        (output / "fixture.json").write_text(json.dumps(fixture, indent=2), encoding="utf-8")
        root = Path(fixture["fixtureRoot"]).resolve()
        if container.resolve() not in root.parents or not root.name.startswith("StartupUIFixture-") or "/tmp/" not in str(root):
            raise RuntimeError("Fixture did not stay inside this simulator app's isolated temporary directory.")
        report["originalHashesUnchanged"] = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
                                               for name, digest in fixture["originalHashes"].items())
        logs = list(root.glob(".startup-transaction-*.json"))
        report["retainedLogMatches"] = len(logs) == 1 and hashlib.sha256(logs[0].read_bytes()).hexdigest() == fixture["markerHash"]
        report["pendingMarkerCleared"] = not (root / ".restore-transaction.json").exists()
        originals = {"11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"}
        recovered = [path for path in root.iterdir() if path.is_dir() and not path.name.startswith(".") and path.name not in originals]
        report["recoveredProjectCount"] = len(recovered)
        if not all(report[key] for key in ["originalHashesUnchanged", "retainedLogMatches", "pendingMarkerCleared"]) or len(recovered) != 1:
            raise RuntimeError("Post-UI original-byte preservation or recovery state differs.")
        report["passed"] = True
    except Exception as error:
        report["errors"].append(str(error))
        # Export available failure evidence even if xcodebuild itself timed out.
        if bundle.exists() and not (output / "attachments").exists():
            try:
                command("xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle), "--output-path", str(output / "attachments"))
            except subprocess.SubprocessError as export_error:
                report["errors"].append(str(export_error))
    finally:
        (output / "scope.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        if not was_booted:
            command("xcrun", "simctl", "shutdown", device_id, timeout=60)
    if not report["passed"]:
        raise SystemExit("Native startup UI check failed: " + "; ".join(report["errors"]))


if __name__ == "__main__":
    main()
