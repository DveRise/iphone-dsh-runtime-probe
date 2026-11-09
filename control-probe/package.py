"""Package exactly one ad hoc signed rootless tweak and its SpringBoard filter."""
import gzip
import hashlib
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tarfile

NAME = 'iPhoneHarnessReadScreen'
PACKAGE = 'local.iphoneharness.readscreen'
VERSION = '0.1.0'
LIBRARY = './var/jb/Library/MobileSubstrate/DynamicLibraries/'


def tar(entries):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w', format=tarfile.USTAR_FORMAT) as archive:
        for name, data, mode in entries:
            item = tarfile.TarInfo(name)
            item.size = len(data)
            item.mode = mode
            archive.addfile(item, io.BytesIO(data))
    return gzip.compress(output.getvalue(), mtime=0)


def ar_member(name, body):
    header = f'{name:<16}{0:<12}{0:<6}{0:<6}{0o100644:<8o}{len(body):<10}`\n'
    return header.encode('ascii') + body + (b'\n' if len(body) % 2 else b'')


def main(binary, output):
    archs = subprocess.check_output(['xcrun', 'lipo', '-archs', str(binary)], text=True).split()
    if sorted(archs) != ['arm64', 'arm64e']:
        raise ValueError('The package needs arm64 and arm64e slices')
    subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
    dylib = binary.read_bytes()
    control = f'''Package: {PACKAGE}
Name: iPhone Harness Read Screen Probe
Version: {VERSION}
Architecture: iphoneos-arm64
Depends: ellekit, firmware (>= 15.0)
Section: Tweaks
Maintainer: iPhone Harness Project
Description: Local, read-only portrait Settings screenshot and OCR probe.
'''
    plist = plistlib.dumps({'Filter': {'Bundles': ['com.apple.springboard']}})
    files = [LIBRARY + NAME + '.dylib', LIBRARY + NAME + '.plist']
    archive = b'!<arch>\n' + ar_member('debian-binary', b'2.0\n')
    archive += ar_member('control.tar.gz', tar([('./control', control.encode('utf-8'), 0o644)]))
    archive += ar_member('data.tar.gz', tar([(files[0], dylib, 0o755), (files[1], plist, 0o644)]))
    output.mkdir(parents=True, exist_ok=True)
    package = output / f'{PACKAGE}_{VERSION}_iphoneos-arm64.deb'
    with package.open('xb') as stream:
        stream.write(archive)
    (output / 'report.json').write_text(json.dumps({
        'package': package.name, 'sha256': hashlib.sha256(archive).hexdigest(),
        'dylib_sha256': hashlib.sha256(dylib).hexdigest(), 'architectures': archs,
        'payload': files, 'maintainer_scripts': [], 'device_tested': False,
        'listener': '127.0.0.1:46030',
    }, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main(Path(sys.argv[1]), Path(sys.argv[2]))
