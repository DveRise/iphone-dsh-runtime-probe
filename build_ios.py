"""Build a foreground runtime probe on macOS without Apple account secrets."""
import argparse
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path
from runtime_archive import RUNTIME_URL, RUNTIME_SHA256, inspect_runtime, extract_device_framework

ROOT = Path(__file__).resolve().parent


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True, cwd=ROOT)


def build(archive=None, harness_payload=None):
    if harness_payload is None:
        raise ValueError('The interactive app requires an explicit Harness payload')
    if sys.platform != 'darwin':
        raise RuntimeError('Compilation requires macOS/Xcode; use the prepared GitHub Actions workflow from Windows')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    output = dist / 'MobileRuntimeProbe.ipa'
    if output.exists():
        raise FileExistsError('Refusing to overwrite an existing test IPA')
    work = ROOT / 'build'
    work.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='ios-probe-', dir=work) as scratch:
        scratch = Path(scratch)
        if archive is None:
            archive = scratch / 'nodejs-mobile-ios-24.22.1-0.zip'
            with urllib.request.urlopen(RUNTIME_URL, timeout=120) as response, archive.open('wb') as target:
                shutil.copyfileobj(response, target)
        inspection = inspect_runtime(archive)
        app = scratch / 'Payload' / 'MobileRuntimeProbe.app'
        framework = app / 'Frameworks' / 'NodeMobile.framework'
        extract_device_framework(archive, framework)
        shutil.copyfile(ROOT / 'app' / 'interactive.mjs', app / 'interactive.mjs')
        shutil.copyfile(ROOT / 'app' / 'web-compat.js', app / 'web-compat.js')
        excluded_native_assets = []
        if harness_payload is not None:
            harness_payload = Path(harness_payload).resolve()
            manifest = json.loads((harness_payload / 'node_modules/@deepseek-ai/dsh/package.json').read_text(encoding='utf-8'))
            if manifest['version'] != '0.2.1-rc.5':
                raise ValueError('The mobile startup probe requires the pinned dsh version')
            def omit_desktop_assets(directory, names):
                omitted = [name for name in names if Path(name).suffix.lower() in ('.node', '.exe', '.dll', '.dylib', '.so', '.lib', '.a', '.o') or name in ('spawn-helper', 'winpty-agent')]
                excluded_native_assets.extend(str((Path(directory) / name).relative_to(harness_payload)) for name in omitted)
                return omitted
            shutil.copytree(harness_payload, app / 'dsh-runtime', ignore=omit_desktop_assets)
            shutil.copyfile(ROOT / 'app' / 'dsh-worker.mjs', app / 'dsh-worker.mjs')
        # Preserve the upstream notices in the generated application.
        license_url = 'https://raw.githubusercontent.com/fogtape/nodejs-mobile/v24.22.1-0/LICENSE'
        with urllib.request.urlopen(license_url, timeout=30) as response:
            (app / 'Node-LICENSE.txt').write_bytes(response.read())
        info = {
            'CFBundleDevelopmentRegion': 'zh_CN',
            'CFBundleDisplayName': '运行环境检查',
            'CFBundleExecutable': 'MobileRuntimeProbe',
            'CFBundleIdentifier': 'local.iphoneharness.runtimeprobe',
            'CFBundleInfoDictionaryVersion': '6.0',
            'CFBundleName': 'MobileRuntimeProbe',
            'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': '0.1.0',
            'CFBundleVersion': '1',
            'CFBundleSupportedPlatforms': ['iPhoneOS'],
            'MinimumOSVersion': '16.0',
            'LSRequiresIPhoneOS': True,
            'UIDeviceFamily': [1],
            'UIRequiredDeviceCapabilities': ['arm64'],
            'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
            'UILaunchScreen': {},
            'NSLocalNetworkUsageDescription': '验证本机运行环境的网络接口。',
        }
        if harness_payload is not None:
            info.update(CFBundleDisplayName='DeepSeek助手', CFBundleShortVersionString='0.3.3', CFBundleVersion='6',
                        NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
        with (app / 'Info.plist').open('wb') as target:
            plistlib.dump(info, target)
        run('xcrun', '--sdk', 'iphoneos', 'clang++', '-target', 'arm64-apple-ios16.0',
            '-isysroot', sdk, '-fobjc-arc', '-fmodules', '-std=c++17', '-O2',
            ROOT / 'app' / 'main.mm', '-F', app / 'Frameworks',
            '-framework', 'UIKit', '-framework', 'Foundation', '-framework', 'CoreGraphics', '-framework', 'WebKit', '-framework', 'NodeMobile',
            '-Wl,-rpath,@executable_path/Frameworks', '-o', app / 'MobileRuntimeProbe')
        run('codesign', '--force', '--sign', '-', framework)
        run('codesign', '--force', '--sign', '-', app)
        run('codesign', '--verify', '--deep', '--strict', app)
        with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as package:
            for file in sorted(app.rglob('*')):
                if file.is_file():
                    package.write(file, file.relative_to(scratch))
        report = {'runtime': inspection, 'runtime_url': RUNTIME_URL,
                  'runtime_sha256': RUNTIME_SHA256,
                  'host_app_minimum_os': '16.0', 'target_device_os': '16.6.1 (20G81)',
                  'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
                  'apple_developer_signed': False, 'device_tested': False,
                  'deepseek_harness_bundled': harness_payload is not None,
                  'interactive_webview_bundled': True,
                  'webkit_compatibility': ['AbortSignal.any when absent', 'Promise.withResolvers when absent'],
                  'ios_session_lock': 'flock(LOCK_EX | LOCK_NB) via authenticated in-process host bridge',
                  'background_execution_supported': False,
                  'native_handoff': 'nonce-authenticated-loopback-socket; no token files',
                  'excluded_desktop_native_assets': excluded_native_assets,
                  'artifact': output.name}
        (dist / 'build-report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
        print('Build complete: dist/MobileRuntimeProbe.ipa (ad-hoc signature; installation method still required)')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-archive', type=Path)
    parser.add_argument('--harness-payload', type=Path)
    args = parser.parse_args()
    build(args.runtime_archive, args.harness_payload)
