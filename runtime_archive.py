"""Inspect a pinned iOS runtime without executing its binaries."""
import hashlib
import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path

RUNTIME_URL = 'https://github.com/fogtape/nodejs-mobile/releases/download/v24.22.1-0/nodejs-mobile-ios-24.22.1-0.zip'
RUNTIME_SHA256 = '3fa1b8fb0720768b01c2e0dae3a17e788476e8c1613a1d9a54e206793b45326e'
PREFIX = 'NodeMobile.xcframework/ios-arm64/NodeMobile.framework/'


def inspect_runtime(archive):
    digest = hashlib.sha256(Path(archive).read_bytes()).hexdigest()
    if digest != RUNTIME_SHA256:
        raise ValueError('runtime SHA-256 mismatch')
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read('NodeMobile.xcframework/Info.plist'))
        device = next(row for row in info['AvailableLibraries']
                      if row['LibraryIdentifier'] == 'ios-arm64')
        if device.get('SupportedPlatformVariant') or device['SupportedPlatform'] != 'ios':
            raise ValueError('not an iOS device library')
        binary = bundle.read(PREFIX + 'NodeMobile')
    if binary[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('expected a thin little-endian 64-bit Mach-O')
    _, cpu, subtype, file_type, count, command_bytes, flags, reserved = struct.unpack_from('<8I', binary)
    if cpu != 0x0100000C or file_type != 6:
        raise ValueError('expected an arm64 dynamic library')
    offset, build = 32, None
    if offset + command_bytes > len(binary):
        raise ValueError('invalid Mach-O command region')
    for _ in range(count):
        command, size = struct.unpack_from('<II', binary, offset)
        if size < 8 or offset + size > 32 + command_bytes:
            raise ValueError('invalid Mach-O load command')
        if command == 0x32:
            platform, minimum, sdk, tools = struct.unpack_from('<4I', binary, offset + 8)
            build = (platform, minimum, sdk)
        offset += size
    if build is None or build[0] != 2:
        raise ValueError('runtime is not built for iPhoneOS devices')
    def version(value):
        return [value >> 16, (value >> 8) & 255, value & 255]
    if version(build[1]) > [16, 6, 1]:
        raise ValueError('runtime minimum OS exceeds the target iOS 16.6.1')
    return {'sha256': digest, 'arch': 'arm64', 'platform': 'iPhoneOS',
            'minimum_os': version(build[1]), 'build_sdk': version(build[2]),
            'binary_bytes': len(binary), 'executed': False}


def extract_device_framework(archive, destination):
    """Extract only regular files from the verified device framework."""
    inspect_runtime(archive)
    destination = Path(destination).resolve()
    with zipfile.ZipFile(archive) as bundle:
        for item in bundle.infolist():
            if not item.filename.startswith(PREFIX) or item.is_dir():
                continue
            relative = Path(item.filename[len(PREFIX):])
            target = (destination / relative).resolve()
            if not target.is_relative_to(destination):
                raise ValueError('archive path escapes framework directory')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(bundle.read(item))
            target.chmod(0o755 if relative.name == 'NodeMobile' else 0o644)


if __name__ == '__main__':
    print(json.dumps(inspect_runtime(sys.argv[1]), indent=2))
