#!/bin/zsh

set -euo pipefail

root_dir=${0:A:h:h}
schema="$root_dir/CloudKit/FastReader.ckdb"
container_identifier=iCloud.com.sild.fastreader
development_team=${DEVELOPMENT_TEAM:-}
action=${1:-check}
temporary_schema=

trap '[[ -z "$temporary_schema" ]] || rm -f "$temporary_schema"' EXIT

verify_local() {
    command -v xcrun >/dev/null || {
        print -u2 -- "xcrun is unavailable. Select the pinned full Xcode installation."
        exit 2
    }
    xcrun --find cktool >/dev/null || {
        print -u2 -- "cktool is unavailable in the selected Xcode installation."
        exit 2
    }
    /usr/bin/python3 "$root_dir/Tools/verify_cloudkit_schema.py" local \
        --schema "$schema" \
        --record-source "$root_dir/FastReader/Core/Sync/LibrarySyncRecord.swift" \
        --codec-source "$root_dir/FastReader/Core/Sync/CloudKitRecordCodec.swift" \
        --entitlements "$root_dir/FastReader/Resources/FastReader.entitlements" \
        --project "$root_dir/project.yml" \
        --debug-config "$root_dir/Config/Debug.xcconfig" \
        --release-config "$root_dir/Config/Release.xcconfig"
}

require_remote_access() {
    if [[ ! "$development_team" =~ '^[A-Z0-9]{10}$' ]]; then
        print -u2 -- "Pass the approved team at runtime: DEVELOPMENT_TEAM=<10-character-team-id>."
        exit 2
    fi

    local teams
    if ! teams=$(xcrun cktool get-teams 2>/dev/null); then
        print -u2 -- "CloudKit management authorization is unavailable."
        print -u2 -- "After enrollment approval, save a management token in Keychain with:"
        print -u2 -- "  xcrun cktool save-token --type management --method keychain"
        exit 2
    fi
    if ! print -r -- "$teams" | grep -Eq "(^|[^A-Z0-9])${development_team}([^A-Z0-9]|$)"; then
        print -u2 -- "The requested DEVELOPMENT_TEAM is not available to the authorized account."
        exit 2
    fi
}

validate_development() {
    xcrun cktool validate-schema \
        --team-id "$development_team" \
        --container-id "$container_identifier" \
        --environment development \
        --file "$schema"
}

verify_deployed() {
    local environment=$1
    temporary_schema=$(mktemp -t fastreader-cloudkit-schema)
    xcrun cktool export-schema \
        --team-id "$development_team" \
        --container-id "$container_identifier" \
        --environment "$environment" \
        --output-file "$temporary_schema"
    /usr/bin/python3 "$root_dir/Tools/verify_cloudkit_schema.py" export \
        --schema "$schema" \
        --exported-schema "$temporary_schema"
    rm -f "$temporary_schema"
    temporary_schema=
}

verify_local

case "$action" in
    check)
        print -- "FastReader CloudKit configuration is ready for Apple activation."
        ;;
    validate-development)
        require_remote_access
        validate_development
        ;;
    import-development)
        require_remote_access
        if [[ "${CONFIRM_CLOUDKIT_IMPORT:-}" != "$container_identifier" ]]; then
            print -u2 -- "Import changes the development container schema. Confirm the exact container with:"
            print -u2 -- "  CONFIRM_CLOUDKIT_IMPORT=$container_identifier"
            exit 2
        fi
        xcrun cktool import-schema \
            --team-id "$development_team" \
            --container-id "$container_identifier" \
            --environment development \
            --validate \
            --file "$schema"
        verify_deployed development
        ;;
    verify-development)
        require_remote_access
        verify_deployed development
        ;;
    verify-production)
        require_remote_access
        verify_deployed production
        ;;
    *)
        print -u2 -- "Usage: ${0:t} {check|validate-development|import-development|verify-development|verify-production}"
        exit 2
        ;;
esac
