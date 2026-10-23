#!/usr/bin/env python3
"""Fast cross-platform checks; does not claim an Xcode build or device pass."""
from pathlib import Path
import json
import plistlib
import re
import struct
import xml.etree.ElementTree as ET

from generate_project import ROOT, generate


def main():
    for path, expected in generate().items():
        assert path.exists() and path.read_text(encoding="utf-8") == expected, f"Regenerate {path.relative_to(ROOT)}"
    project = (ROOT / "MyCoverStudio.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    declarations = re.findall(r"^\s*([A-F0-9]{24}) = \{", project, re.MULTILINE)
    assert len(declarations) == len(set(declarations)), "Duplicate Xcode object identifiers"
    identifiers = set(re.findall(r"\b[A-F0-9]{24}\b", project))
    assert identifiers == set(declarations), "Unresolved Xcode object reference"
    with (ROOT / "App/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    assert info["NSCameraUsageDescription"] and info["NSMicrophoneUsageDescription"]
    assert info["UTExportedTypeDeclarations"][0]["UTTypeIdentifier"] == "studio.mycover.project"
    assert not info.get("UIBackgroundModes"), "Background capture must not be claimed"
    with (ROOT / "App/PrivacyInfo.xcprivacy").open("rb") as stream:
        privacy = plistlib.load(stream)
    assert privacy["NSPrivacyTracking"] is False
    assert privacy["NSPrivacyCollectedDataTypes"] == []
    ET.parse(ROOT / "MyCoverStudio.xcodeproj/xcshareddata/xcschemes/MyCoverStudio.xcscheme")
    for asset_json in (ROOT / "App/Assets.xcassets").rglob("Contents.json"):
        json.loads(asset_json.read_text(encoding="utf-8"))
    icon = (ROOT / "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png").read_bytes()
    assert icon[:8] == b"\x89PNG\r\n\x1a\n", "App Icon is not PNG"
    width, height, depth, color_type, _, _, _ = struct.unpack(">IIBBBBB", icon[16:29])
    assert (width, height, depth, color_type) == (1024, 1024, 8, 2), "App Icon must be opaque RGB 1024x1024"
    assert 'swiftLanguageVersions: [.v5]' in (ROOT / "Package.swift").read_text(encoding="utf-8")
    print(f"Configuration checks passed ({len(list((ROOT / 'App').rglob('*.swift')))} app sources). No compilation or device verification performed.")


if __name__ == "__main__":
    main()
