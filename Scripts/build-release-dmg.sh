#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PROJECT="$ROOT_DIR/NowPlayingWidget.xcodeproj"
SCHEME="NowPlayingWidget"
BUILD_ROOT="$ROOT_DIR/build/release"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
APP="$DERIVED_DATA/Build/Products/Release/NowPlayingWidget.app"
STAGING="$BUILD_ROOT/dmg"

VERSION=$(
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -derivedDataPath "$DERIVED_DATA" \
        -showBuildSettings |
        awk '/MARKETING_VERSION =/ { print $3; exit }'
)

DMG="$BUILD_ROOT/NowPlayingWidget-v$VERSION-macOS-universal.dmg"

"$ROOT_DIR/Scripts/prepare-bundled-cli.sh"

rm -rf "$DERIVED_DATA" "$STAGING" "$DMG"
mkdir -p "$STAGING"

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM="" \
    build

test -d "$APP"
test -x "$APP/Contents/Resources/nowplaying-cli/bin/nowplaying-cli"

ditto "$APP" "$STAGING/NowPlayingWidget.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Now Playing Widget" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG"

# The app under DerivedData and the copy under dmg/ are only intermediate
# inputs. Remove them so Finder and Spotlight expose a single release asset.
rm -rf "$DERIVED_DATA" "$STAGING"

echo
echo "Release DMG created:"
echo "$DMG"
