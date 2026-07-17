#!/bin/zsh

set -euo pipefail

root_dir=${0:A:h:h}
derived_data=${DERIVED_DATA:-"$root_dir/.build/DerivedData"}
configuration=${CONFIGURATION:-Debug}
device_udid=${DEVICE_UDID:-}
core_device_id=${CORE_DEVICE_ID:-}
development_team=${DEVELOPMENT_TEAM:-}

if [[ -z "$development_team" ]]; then
    team_candidates=("${(@f)$({
        /usr/bin/python3 - "$HOME/Library/Preferences/com.apple.dt.Xcode.plist" <<'PY'
import plistlib
import sys

try:
    with open(sys.argv[1], "rb") as source:
        preferences = plistlib.load(source)
except (FileNotFoundError, OSError, plistlib.InvalidFileException):
    sys.exit(0)

teams_by_account = preferences.get("IDEProvisioningTeamByIdentifier", {})
team_ids = set()
for teams in teams_by_account.values():
    for team in teams:
        team_id = team.get("teamID")
        if team_id:
            team_ids.add(team_id)

for team_id in sorted(team_ids):
    print(team_id)
PY
    })}")
    if (( ${#team_candidates} == 1 )); then
        development_team=$team_candidates[1]
    elif (( ${#team_candidates} > 1 )); then
        echo "Multiple Xcode development teams are available. Pass DEVELOPMENT_TEAM explicitly."
        exit 2
    fi
fi

if [[ -z "$development_team" ]]; then
    echo "No active Xcode development team found. Sign in through Xcode or pass DEVELOPMENT_TEAM."
    exit 2
fi

if [[ -z "$device_udid" || -z "$core_device_id" ]]; then
    device_json=$(mktemp)
    trap 'rm -f "$device_json"' EXIT
    xcrun devicectl list devices --json-output "$device_json" >/dev/null
    detected_device=$(
        /usr/bin/python3 - "$device_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    devices = json.load(source).get("result", {}).get("devices", [])

for device in devices:
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    if (
        hardware.get("deviceType") == "iPhone"
        and hardware.get("reality") == "physical"
        and connection.get("pairingState") == "paired"
    ):
        print(hardware.get("udid", ""), device.get("identifier", ""))
        break
PY
    )
    detected_udid=${detected_device%% *}
    detected_core_id=${detected_device#* }
    device_udid=${device_udid:-$detected_udid}
    core_device_id=${core_device_id:-$detected_core_id}
fi

if [[ -z "$device_udid" || -z "$core_device_id" ]]; then
    echo "No paired physical iPhone found. Connect and trust the phone, or pass device IDs."
    exit 2
fi

device_derived_data="$derived_data/Devices/$device_udid"

mkdir -p "$root_dir/.build" "$device_derived_data"
build_log="$root_dir/.build/device-deploy.log"
echo "Preparing the connected device..."
if ! xcrun devicectl device info ddiServices \
    --device "$core_device_id" \
    --auto-mount-ddis \
    --quiet \
    >/dev/null 2>&1
then
    echo "The device is locked or unavailable. Unlock it, keep it connected, and retry."
    exit 2
fi

echo "Building SpeedRead for the connected device..."
if ! xcodebuild build \
    -project "$root_dir/SpeedRead.xcodeproj" \
    -scheme SpeedRead \
    -configuration "$configuration" \
    -destination "id=$device_udid" \
    -derivedDataPath "$device_derived_data" \
    -disableAutomaticPackageResolution \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$development_team" \
    >"$build_log" 2>&1
then
    tail -80 "$build_log" \
        | sed -E 's/(DEVELOPMENT_TEAM[ =]+)[A-Z0-9]+/\1[redacted]/g'
    exit 1
fi

app_path="$device_derived_data/Build/Products/$configuration-iphoneos/SpeedRead.app"
echo "Installing SpeedRead..."
xcrun devicectl device install app --device "$core_device_id" "$app_path"
echo "Launching SpeedRead..."
xcrun devicectl device process launch \
    --device "$core_device_id" \
    --terminate-existing \
    com.sild.speedread.app
