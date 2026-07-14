#!/bin/zsh

set -euo pipefail

source "${0:A:h}/versions.env"

actual_xcode=$(xcodebuild -version | awk 'NR == 1 { print $2 }')
actual_xcodegen=$(xcodegen --version | awk '{ print $2 }')
actual_swiftformat=$(swiftformat --version)
actual_swiftlint=$(swiftlint version)

check_version() {
    local name=$1
    local expected=$2
    local actual=$3

    if [[ "$expected" != "$actual" ]]; then
        print -u2 -- "$name version mismatch: expected $expected, got $actual"
        return 1
    fi
}

check_version Xcode "$XCODE_VERSION" "$actual_xcode"
check_version XcodeGen "$XCODEGEN_VERSION" "$actual_xcodegen"
check_version SwiftFormat "$SWIFTFORMAT_VERSION" "$actual_swiftformat"
check_version SwiftLint "$SWIFTLINT_VERSION" "$actual_swiftlint"

if ! xcrun simctl list runtimes available | grep -Fq "iOS $IOS_SIMULATOR_RUNTIME"; then
    print -u2 -- "iOS $IOS_SIMULATOR_RUNTIME simulator runtime is unavailable"
    exit 1
fi

print -- "Tool versions match Tools/versions.env"
