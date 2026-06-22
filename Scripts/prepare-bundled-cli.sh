#!/bin/sh

set -eu

VERSION="2.1.0"
COMMIT="8c8c1fa4820681fd4bbd6a17ce0a5655e1f4ebe7"
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
DESTINATION="$ROOT_DIR/ThirdParty/nowplaying-cli"
VERSION_FILE="$DESTINATION/.source-commit"
EXECUTABLE="$DESTINATION/bin/nowplaying-cli"
DYLIB="$DESTINATION/lib/nowplaying-cli/MediaRemoteMini.dylib"

is_universal() {
    file "$1" | grep -q "universal binary" &&
        lipo -archs "$1" | grep -q "arm64" &&
        lipo -archs "$1" | grep -q "x86_64"
}

if [ -x "$EXECUTABLE" ] &&
    [ -f "$DYLIB" ] &&
    [ -f "$VERSION_FILE" ] &&
    [ "$(cat "$VERSION_FILE")" = "$COMMIT" ] &&
    is_universal "$EXECUTABLE" &&
    is_universal "$DYLIB"; then
    exit 0
fi

echo "Preparing bundled nowplaying-cli v$VERSION..."

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nowplaying-cli.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

ARCHIVE="$WORK_DIR/nowplaying-cli-$VERSION.tar.gz"
SOURCE_DIR="$WORK_DIR/source"
mkdir -p "$SOURCE_DIR"

curl --fail --location --silent --show-error \
    "https://github.com/kirtan-shah/nowplaying-cli/archive/$COMMIT.tar.gz" \
    --output "$ARCHIVE"

tar -xzf "$ARCHIVE" -C "$SOURCE_DIR" --strip-components=1

make -C "$SOURCE_DIR" clean
make -C "$SOURCE_DIR" \
    CFLAGS="-O3 -arch arm64 -arch x86_64 -mmacosx-version-min=14.0"

is_universal "$SOURCE_DIR/nowplaying-cli"
is_universal "$SOURCE_DIR/build/mediaremote-mini/MediaRemoteMini.dylib"

mkdir -p \
    "$DESTINATION/bin" \
    "$DESTINATION/lib/nowplaying-cli" \
    "$DESTINATION/share/nowplaying-cli/scripts" \
    "$DESTINATION/source"

install -m 755 "$SOURCE_DIR/nowplaying-cli" "$EXECUTABLE"
install -m 755 \
    "$SOURCE_DIR/build/mediaremote-mini/MediaRemoteMini.dylib" \
    "$DYLIB"
install -m 755 \
    "$SOURCE_DIR/scripts/mediaremote-mini.pl" \
    "$DESTINATION/share/nowplaying-cli/scripts/mediaremote-mini.pl"
install -m 644 "$SOURCE_DIR/LICENSE" "$DESTINATION/LICENSE"
install -m 644 "$ARCHIVE" \
    "$DESTINATION/source/nowplaying-cli-$VERSION-source.tar.gz"

printf '%s\n' "$COMMIT" > "$VERSION_FILE"

codesign --force --sign - "$EXECUTABLE"
codesign --force --sign - "$DYLIB"

echo "Bundled nowplaying-cli is ready."
