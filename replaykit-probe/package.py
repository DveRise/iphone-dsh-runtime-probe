"""Package the ordinary iPhone app and its ReplayKit extension for development signing."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import zipfile

APP_NAME = 'ReplayScreenProbe'
EXTENSION_NAME = 'ScreenReader'
BUNDLE_ID = 'local.iphoneharness.replayscreenprobe'


def main(output):
    app = output / f'Payload/{APP_NAME}.app'
    extension = app / f'PlugIns/{EXTENSION_NAME}.appex'
    shared = {
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleShortVersionString': '0.1.2',
        'CFBundleVersion': '3',
        'CFBundleSupportedPlatforms': ['iPhoneOS'],
        'MinimumOSVersion': '16.0',
        'UIDeviceFamily': [1],
    }
    app_info = dict(shared, CFBundleName=APP_NAME, CFBundleDisplayName='录屏读屏测试',
                    CFBundleIdentifier=BUNDLE_ID, CFBundleExecutable=APP_NAME,
                    CFBundlePackageType='APPL', UILaunchScreen={},
                    UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait'])
    extension_info = dict(shared, CFBundleName=EXTENSION_NAME, CFBundleDisplayName='录屏读屏测试',
                          CFBundleIdentifier=BUNDLE_ID + '.screenreader',
                          CFBundleExecutable=EXTENSION_NAME, CFBundlePackageType='XPC!',
                          NSExtension={
                              'NSExtensionPointIdentifier': 'com.apple.broadcast-services-upload',
                              'NSExtensionPrincipalClass': 'SampleHandler',
                              'RPBroadcastProcessMode': 'RPBroadcastProcessModeSampleBuffer',
                          })
    for bundle, info in ((extension, extension_info), (app, app_info)):
        (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(bundle)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    ipa = output / f'{APP_NAME}.ipa'
    with zipfile.ZipFile(ipa, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
        for entry in sorted(app.rglob('*')):
            if entry.is_file():
                archive.write(entry, entry.relative_to(output))
    (output / 'report.json').write_text(json.dumps({
        'ipa': ipa.name, 'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest(),
        'app_id': BUNDLE_ID, 'extension_id': extension_info['CFBundleIdentifier'],
        'device_tested': False,
    }, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main(Path(sys.argv[1]))
