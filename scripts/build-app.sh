#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
configuration="${1:-release}"
if [[ "$#" -gt 1 || ( "$configuration" != debug && "$configuration" != release ) ]]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 1
fi
build_arguments=(--configuration "$configuration")
if [[ -n "${BUILD_ARCHS:-}" ]]; then
    read -r -a architectures <<< "$BUILD_ARCHS"
    for architecture in "${architectures[@]}"; do
        case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
        build_arguments+=(--arch "$architecture")
    done
fi
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
minimum_version="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
# SwiftPM's object-only link can stamp the deployment target as the SDK version.
# AppKit then uses legacy control metrics instead of those of the actual SDK.
swift build "${build_arguments[@]}" \
    -Xlinker -platform_version -Xlinker macos \
    -Xlinker "$minimum_version" -Xlinker "$sdk_version"
binary_directory="$(swift build "${build_arguments[@]}" --show-bin-path)"
app_directory="$project_root/build/Siniulator.app"
sparkle_framework="$binary_directory/Sparkle.framework"
if [[ ! -d "$sparkle_framework" ]]; then
    sparkle_framework="$project_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi
if [[ ! -d "$sparkle_framework" ]]; then
    echo "Sparkle.framework was not found in the SwiftPM build or artifacts." >&2
    exit 1
fi
# Start from a clean bundle so removed resources cannot survive into a release.
rm -rf "$app_directory"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources" "$app_directory/Contents/Frameworks"
cp "$binary_directory/Siniulator" "$app_directory/Contents/MacOS/Siniulator"
cp Resources/Info.plist "$app_directory/Contents/Info.plist"
# Compile the Icon Composer source, including an ICNS fallback for older macOS.
xcrun actool Resources/Siniulator.icon \
    --compile "$app_directory/Contents/Resources" \
    --output-format human-readable-text --notices --warnings \
    --output-partial-info-plist build/icon-info.plist \
    --app-icon Siniulator --include-all-app-icons \
    --target-device mac --minimum-deployment-target "$minimum_version" --platform macosx
/usr/libexec/PlistBuddy -c 'Merge build/icon-info.plist' "$app_directory/Contents/Info.plist"
if [[ -n "${RELEASE_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$app_directory/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$app_directory/Contents/Info.plist"
fi
if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
    /usr/libexec/PlistBuddy -c 'Delete :SUPublicEDKey' "$app_directory/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$app_directory/Contents/Info.plist"
fi
ditto "$sparkle_framework" "$app_directory/Contents/Frameworks/Sparkle.framework"
cp LICENSE "$app_directory/Contents/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.md "$app_directory/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp Resources/Sparkle-LICENSE "$app_directory/Contents/Resources/Sparkle-LICENSE"
"$project_root/scripts/sign-app.sh" "$app_directory"
printf '%s\n' "$app_directory"
