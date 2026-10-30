#!/bin/sh
set -eu
SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR="$SOURCE_DIR/../dist/双径.app"
if ! test -f "$SOURCE_DIR/AppIcon.icns"; then
    printf '%s\n' '缺少 AppIcon.icns，请先生成应用图标。' >&2
    exit 1
fi
mkdir -p "$OUTPUT_DIR/Contents/MacOS" "$OUTPUT_DIR/Contents/Resources"
/usr/bin/swiftc -swift-version 5 -target arm64-apple-macos13.0 -O -framework AppKit -framework ServiceManagement "$SOURCE_DIR/main.swift" -o "$OUTPUT_DIR/Contents/MacOS/TailscaleSplit"
/usr/bin/install -m 644 "$SOURCE_DIR/Info.plist" "$OUTPUT_DIR/Contents/Info.plist"
/usr/bin/install -m 644 "$SOURCE_DIR/AppIcon.icns" "$OUTPUT_DIR/Contents/Resources/AppIcon.icns"
/usr/bin/install -m 644 "$SOURCE_DIR/../docs/usage.md" "$OUTPUT_DIR/Contents/Resources/使用说明.md"
/usr/bin/plutil -lint "$OUTPUT_DIR/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$OUTPUT_DIR"
/usr/bin/codesign --verify --deep --strict "$OUTPUT_DIR"
printf '%s\n' "$OUTPUT_DIR"
