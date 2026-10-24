#!/usr/bin/env python3
"""Check the actual IPA payload, device Mach-O, metadata and digest; no install claim."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import zipfile


def inspect(path):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, 'IPA ZIP integrity failed'
        prefix = 'Payload/MyCoverStudio.app/'
        names = archive.namelist()
        assert names and all(name.startswith('Payload/') for name in names), 'Unexpected ZIP root'
        assert all('..' not in name.split('/') and not name.startswith('/') for name in names), 'Unsafe ZIP path'
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        assert info['CFBundleIdentifier'] == 'studio.mycover.app', 'Wrong application'
        assert info['CFBundlePackageType'] == 'APPL'
        assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS'], 'Simulator app is not a device IPA'
        assert set(info['UIDeviceFamily']) == {1, 2}, 'iPhone/iPad support missing'
        assert info['NSCameraUsageDescription'] and info['NSMicrophoneUsageDescription']
        assert not any('/_CodeSignature/' in n or n.endswith('/embedded.mobileprovision') for n in names), 'Expected unsigned payload'
        executable = info['CFBundleExecutable']
        assert '/' not in executable and executable not in ('.', '..')
        binary = archive.read(prefix + executable)
        # A single arm64 device build: validate the actual platform load command,
        # since arm64 alone could also be a modern Simulator binary.
        assert binary[:4] == b'\xcf\xfa\xed\xfe', 'Expected thin little-endian Mach-O 64'
        assert struct.unpack_from('<I', binary, 4)[0] == 0x0100000C, 'Expected arm64'
        count = struct.unpack_from('<I', binary, 16)[0]
        offset, platforms = 32, []
        for _ in range(count):
            command, size = struct.unpack_from('<II', binary, offset)
            assert size >= 8 and offset + size <= len(binary), 'Invalid Mach-O command'
            if command == 0x32:  # LC_BUILD_VERSION
                assert size >= 24
                platforms.append(struct.unpack_from('<I', binary, offset + 8)[0])
            offset += size
        assert platforms == [2], f'Expected PLATFORM_IOS, got {platforms}'
    hasher = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    return {
        'file': path.name, 'bytes': path.stat().st_size, 'sha256': digest,
        'bundleID': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'], 'minimumOS': info['MinimumOSVersion'],
        'supportedPlatforms': info['CFBundleSupportedPlatforms'], 'deviceFamily': info['UIDeviceFamily'],
        'architecture': 'arm64', 'machOPlatform': 'iOS device', 'signed': False,
        'sourceCommit': os.environ.get('GITHUB_SHA'),
        'scope': 'ZIP, app metadata and device executable checks only. Needs local signing; no installation or hardware test implied.'
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('ipa', type=Path)
    args = parser.parse_args()
    report = inspect(args.ipa)
    args.ipa.with_suffix('.ipa.sha256').write_text(f"{report['sha256']}  {args.ipa.name}\n", encoding='utf-8')
    args.ipa.with_name('ipa-report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))
