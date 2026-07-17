#!/bin/zsh

set -euo pipefail

root_dir=${0:A:h:h}
derived_data=${DERIVED_DATA:-$root_dir/.build/DerivedData}
output_root=${OUTPUT_ROOT:-$root_dir/AppStore/Screenshots}
iphone_name=${IPHONE_SCREENSHOT_SIMULATOR:-iPhone 17 Pro Max}
ipad_name=${IPAD_SCREENSHOT_SIMULATOR:-iPad Pro 13-inch (M5)}
work_root="$root_dir/.build/AppStoreCapture"
staging_root="$work_root/Screenshots"
current_udid=

cleanup() {
    if [[ -n "$current_udid" ]]; then
        xcrun simctl status_bar "$current_udid" clear >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

command -v xcodebuild >/dev/null || {
    print -u2 -- "xcodebuild is unavailable. Select the pinned full Xcode installation."
    exit 2
}

rm -rf "$work_root"
mkdir -p "$staging_root"

capture_device() {
    local device_name=$1
    local destination_name=$2
    local device_id
    local result_bundle="$work_root/$destination_name.xcresult"
    local attachments="$work_root/$destination_name-attachments"

    device_id=$(xcrun simctl list devices available -j \
        | /usr/bin/python3 "$root_dir/Tools/app_store_submission.py" device-id --name "$device_name")
    current_udid=$device_id
    xcrun simctl boot "$device_id" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$device_id" -b
    xcrun simctl status_bar "$device_id" override \
        --time 9:41 \
        --dataNetwork wifi \
        --wifiMode active \
        --wifiBars 3 \
        --cellularMode active \
        --cellularBars 4 \
        --batteryState charged \
        --batteryLevel 100

    xcodebuild test -quiet \
        -project "$root_dir/FastReader.xcodeproj" \
        -scheme FastReader \
        -testPlan FastReaderFull \
        -destination "platform=iOS Simulator,id=$device_id" \
        -derivedDataPath "$derived_data" \
        -resultBundlePath "$result_bundle" \
        -parallel-testing-enabled NO \
        -only-testing:FastReaderUITests/AppStoreScreenshotUITests/testAppStoreScreenshots \
        CODE_SIGNING_ALLOWED=NO

    mkdir -p "$attachments"
    xcrun xcresulttool export attachments \
        --path "$result_bundle" \
        --output-path "$attachments" >/dev/null
    /usr/bin/python3 "$root_dir/Tools/app_store_submission.py" export \
        --manifest "$attachments/manifest.json" \
        --attachments "$attachments" \
        --output "$staging_root/$destination_name" \
        --device-set "$destination_name"
    xcrun simctl status_bar "$device_id" clear
    current_udid=
}

capture_device "$iphone_name" iPhone-6.9
capture_device "$ipad_name" iPad-13

command -v sips >/dev/null || {
    print -u2 -- "sips is unavailable; iPad screenshots cannot be normalized to landscape."
    exit 2
}
for screenshot in "$staging_root/iPad-13"/*.png; do
    rotated="${screenshot:r}-rotated.png"
    sips --rotate 270 "$screenshot" --out "$rotated" >/dev/null
    mv "$rotated" "$screenshot"
done

/usr/bin/python3 "$root_dir/Tools/app_store_submission.py" check \
    --root "$root_dir" \
    --screenshots-root "$staging_root"

mkdir -p "${output_root:h}"
rm -rf "$output_root"
mv "$staging_root" "$output_root"

/usr/bin/python3 "$root_dir/Tools/app_store_submission.py" check \
    --root "$root_dir" \
    --screenshots-root "$output_root"
print -- "App Store screenshots written to $output_root"
