#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build dist
python3 scripts/validate_configuration.py
xcodebuild -project MyCoverStudio.xcodeproj -scheme MyCoverStudio \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DeviceDerivedData ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build 2>&1 | tee build/iphoneos-release.log

# Use an isolated fresh Payload so a repeat never includes stale application files.
stage="$(mktemp -d "$PWD/build/ipa-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload"
ditto build/DeviceDerivedData/Build/Products/Release-iphoneos/MyCoverStudio.app \
  "$stage/Payload/MyCoverStudio.app"
(cd "$stage" && /usr/bin/zip -qry "$PWD/MyCoverStudio-V1-unsigned.ipa" Payload)
mv "$stage/MyCoverStudio-V1-unsigned.ipa" dist/MyCoverStudio-V1-unsigned.ipa
python3 scripts/verify_ipa.py dist/MyCoverStudio-V1-unsigned.ipa
echo "Unsigned device IPA ready; local signing is required before installation."
