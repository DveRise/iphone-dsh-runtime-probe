# iPhone DeepSeek Harness startup probe

Foreground test app for iPhone 12 / iOS 16.6.1 (20G81). The previous Node runtime-only test passed on the target phone. This second stage bundles official @deepseek-ai/dsh 0.2.1-rc.5 with two documented mobile loader adaptations, using the same SHA-256-pinned NodeMobile runtime.

The app checks official profile startup in a Worker, loopback-only access protection, the launch-token/cookie exchange, authenticated frontend HTML, and context cleanup. It does not call a model, accept model credentials, read other apps, inject touches, or install jailbreak components. It does not yet display an interactive WebView.

The Worker uses --expose-internals and --no-addons. patch_runtime.py replaces two specific native-helper imports with Node's exposed internal module interface and writes before/after source hashes. Desktop native assets and terminal helper executables are omitted from the mobile bundle and listed in build-report.json. Terminal and shell execution are not supported by this probe. The upstream MIT code and dependency license files are preserved in the payload.

The adapted startup checks passed on Windows Node 24.16.0 after a locked, lifecycle-script-free install without optional packages and with native addons disabled. This does not prove iOS compatibility; the app is intended to collect that evidence. The inherited lock has known upstream audit advisories; this startup-only package is not a production release. Dependencies must be reviewed before adding model credentials and real tasks.

## Build

The Actions workflow is manual-only, has read-only repository permissions, and uses one macOS job with a 25-minute limit. It runs npm ci --ignore-scripts --omit=optional, applies the explicit loader adaptations, and builds an ad-hoc-signed IPA. No Apple signing secrets or model credentials are used. The artifact contains MobileRuntimeProbe.ipa and build-report.json.

Bundle ID remains local.iphoneharness.runtimeprobe, version 0.2.0/build 2, display name DSH启动检查. The IPA needs user-authorized signing and installation. Installation and runtime execution remain separate verification steps.

On the phone, open DSH启动检查, tap 开始检查, keep it foreground, and export runtime-report.json and runtime.log. Scripts return naturally to node_start; they do not use process.exit in the native host. Restart the app before another test.
