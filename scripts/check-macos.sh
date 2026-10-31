#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
    echo 'This check needs macOS with full Xcode selected by xcode-select.' >&2
    exit 1
fi
swift test --package-path Shared
./scripts/generate-project.sh
xcodebuild -project iKey.xcodeproj -scheme iKeyMac -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iKey.xcodeproj -scheme iKeyPad -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
