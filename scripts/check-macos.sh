#!/bin/sh
# macOS check (also the macos CI job): runs the Shared tests with the Xcode
# toolchain (so canImport(Network)/Security code compiles), regenerates the
# project and builds both apps unsigned (CODE_SIGNING_ALLOWED=NO).
#
#   IKEY_BUILD_ROOT  local, unsynced build directory (default ~/Library/Caches/iKey);
#                    Xcode logs land in $IKEY_BUILD_ROOT/DerivedData/Logs.
#
# Signing for your own runs comes from Config/Local.xcconfig (not in Git), e.g.
# DEVELOPMENT_TEAM = ABCDE12345; see Config/Base.xcconfig. It is ignored here.
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
# The simulator destination needs Xcode's iOS platform. If xcodebuild reports it
# is not installed, run `xcodebuild -downloadPlatform iOS` once and retry.
if ! xcodebuild -project iKey.xcodeproj -scheme iKeyPad -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$build_root/DerivedData" CODE_SIGNING_ALLOWED=NO build; then
    echo 'iKeyPad build failed. If the iOS platform is missing, run: xcodebuild -downloadPlatform iOS' >&2
    exit 1
fi
