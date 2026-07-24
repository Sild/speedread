#!/bin/zsh

set -euo pipefail

tool_root=${TOOLS_DIR:-"${0:A:h:h}/.build/tools"}
download_dir="$tool_root/downloads"
version_dir="$tool_root/versions"
bin_dir="$tool_root/bin"

source "${0:A:h}/versions.env"
source "${0:A:h}/tool_checksums.env"

mkdir -p "$download_dir" "$version_dir" "$bin_dir"

download_verified() {
    local name=$1
    local version=$2
    local url=$3
    local checksum=$4
    local archive="$download_dir/$name-$version.zip"

    if [[ ! -f "$archive" ]] || ! print -r -- "$checksum  $archive" | shasum -a 256 --check --status; then
        print -- "Downloading $name $version"
        curl --fail --location --silent --show-error --retry 3 \
            --output "$archive" \
            "$url"
    fi

    print -r -- "$checksum  $archive" | shasum -a 256 --check
    REPLY=$archive
}

install_xcodegen() {
    local install_dir="$version_dir/xcodegen-$XCODEGEN_VERSION"
    local executable="$install_dir/xcodegen/bin/xcodegen"

    download_verified \
        XcodeGen \
        "$XCODEGEN_VERSION" \
        "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" \
        "$XCODEGEN_SHA256"
    local archive=$REPLY

    if [[ ! -x "$executable" ]]; then
        mkdir -p "$install_dir"
        unzip -q -o "$archive" -d "$install_dir"
    fi

    if [[ -L "$bin_dir/xcodegen" ]]; then
        unlink "$bin_dir/xcodegen"
    fi
    cp "$executable" "$bin_dir/xcodegen"
    cp -R "$install_dir/xcodegen/share/." "$tool_root/share"
}

install_standalone_binary() {
    local name=$1
    local version=$2
    local url=$3
    local checksum=$4
    local archive_binary=$5
    local install_dir="$version_dir/$name-$version"
    local executable="$install_dir/$archive_binary"

    download_verified "$name" "$version" "$url" "$checksum"
    local archive=$REPLY

    if [[ ! -x "$executable" ]]; then
        mkdir -p "$install_dir"
        unzip -q -o "$archive" -d "$install_dir"
        chmod +x "$executable"
    fi

    ln -sfn "../versions/$name-$version/$archive_binary" "$bin_dir/$name"
}

install_xcodegen
install_standalone_binary \
    swiftformat \
    "$SWIFTFORMAT_VERSION" \
    "https://github.com/nicklockwood/SwiftFormat/releases/download/$SWIFTFORMAT_VERSION/swiftformat.zip" \
    "$SWIFTFORMAT_SHA256" \
    swiftformat
install_standalone_binary \
    swiftlint \
    "$SWIFTLINT_VERSION" \
    "https://github.com/realm/SwiftLint/releases/download/$SWIFTLINT_VERSION/portable_swiftlint.zip" \
    "$SWIFTLINT_SHA256" \
    swiftlint

PATH="$bin_dir:$PATH" "${0:A:h}/check_versions.sh"
print -- "Pinned tools are available in $bin_dir"
