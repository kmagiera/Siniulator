#!/bin/bash
set -euo pipefail
if [[ "$#" != 0 ]]; then
    echo "Usage: $0" >&2
    exit 1
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_directory="$project_root/build/InteractionQA.app"
mkdir -p "$fixture_directory"
sdk_directory="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -parse-as-library -target "$(uname -m)-apple-ios17.0-simulator" -sdk "$sdk_directory" \
    "$project_root/scripts/fixtures/InteractionApp.swift" -o "$fixture_directory/InteractionQA"
cat > "$fixture_directory/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.siniulator.interaction-qa</string>
<key>CFBundleExecutable</key><string>InteractionQA</string>
<key>CFBundleName</key><string>Interaction QA</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict>
<key>UIApplicationSupportsMultipleScenes</key><false/>
<key>UISceneConfigurations</key><dict/></dict>
<key>UISupportedInterfaceOrientations</key><array>
<string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationPortraitUpsideDown</string>
<string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string>
</array>
</dict></plist>
PLIST
codesign --force --sign - "$fixture_directory"
printf '%s\n' "$fixture_directory"
