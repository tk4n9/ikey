#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
    echo 'This check needs macOS with full Xcode selected by xcode-select.' >&2
    exit 1
fi
if ! xcrun --find xctest >/dev/null 2>&1; then
    echo 'Select full Xcode: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer' >&2
    exit 1
fi
# Generated products contain absolute paths and must not travel through Dropbox.
build_root=${IKEY_BUILD_ROOT:-"$HOME/Library/Caches/iKey"}
mkdir -p "$build_root"
xcrun swift test --package-path Shared --scratch-path "$build_root/swift"
./scripts/generate-project.sh
xcodebuild -project iKey.xcodeproj -scheme iKeyMac -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$build_root/DerivedData" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iKey.xcodeproj -scheme iKeyPad -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$build_root/DerivedData" CODE_SIGNING_ALLOWED=NO build
