#!/bin/sh
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nowplaying-reader-tests.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM
xcrun swiftc \
    "$ROOT_DIR/Shared/NowPlayingShared.swift" \
    "$ROOT_DIR/Shared/PlaybackCommand.swift" \
    "$ROOT_DIR/Shared/NowPlayingCLI.swift" \
    "$ROOT_DIR/App/HighResArtworkResolver.swift" \
    "$ROOT_DIR/App/LyricResolver.swift" \
    "$ROOT_DIR/App/NowPlayingReader.swift" \
    "$ROOT_DIR/App/WidgetSyncPipeline.swift" \
    "$ROOT_DIR/Tests/NowPlayingReaderTests.swift" \
    "$ROOT_DIR/Tests/WidgetSyncPipelineTests.swift" \
    -o "$WORK_DIR/reader-tests"
"$WORK_DIR/reader-tests"
