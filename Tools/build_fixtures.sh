#!/bin/zsh

set -euo pipefail

root=${0:A:h:h}
fixtures="$root/SpeedReadTests/Fixtures"
sources="$root/Tools/FixtureSources"

build_epub() {
    local source=$1
    local destination=$2
    shift 2

    rm -f "$destination"
    (
        cd "$source"
        zip -X0 "$destination" mimetype
        zip -Xr9 "$destination" "$@"
    )
}

sips -s format png "$sources/EPUB3/EPUB/cover.svg" --out "$sources/EPUB3/EPUB/cover.png" >/dev/null
build_epub "$sources/EPUB3" "$fixtures/epub3-cyrillic.epub" META-INF EPUB -x EPUB/cover.svg

build_epub "$sources/EPUB3Fixed" "$fixtures/epub3-fixed.epub" META-INF EPUB
build_epub "$sources/EPUB2" "$fixtures/epub2.epub" META-INF OEBPS

protected_source=$(mktemp -d)
trap 'rm -rf "$protected_source"' EXIT
cp -R "$sources/EPUB3/." "$protected_source"
cp "$sources/EPUB3Protected/encryption.xml" "$protected_source/META-INF/encryption.xml"
build_epub "$protected_source" "$fixtures/protected.epub" META-INF EPUB -x EPUB/cover.svg

missing_metadata_source=$(mktemp -d)
cp -R "$sources/EPUB3/." "$missing_metadata_source"
cp "$sources/EPUB3MissingMetadata/package.opf" "$missing_metadata_source/EPUB/package.opf"
rm -f "$missing_metadata_source/EPUB/cover.png"
build_epub "$missing_metadata_source" "$fixtures/missing-metadata.epub" META-INF EPUB -x EPUB/cover.svg
rm -rf "$missing_metadata_source"

long_source=$(mktemp -d)
cp -R "$sources/EPUB3/." "$long_source"
cp "$sources/EPUB3Long/chapter.xhtml" "$long_source/EPUB/chapter.xhtml"
build_epub "$long_source" "$fixtures/long-chapter.epub" META-INF EPUB -x EPUB/cover.svg
rm -rf "$long_source"

rm -f "$sources/EPUB3/EPUB/cover.png"

xcrun swift "$root/Tools/build_pdf_fixtures.swift" "$fixtures"
