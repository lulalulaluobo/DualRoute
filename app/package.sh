#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STAGE="$ROOT/.build/dmg"
test -d "$ROOT/dist/双径.app"
mkdir -p "$STAGE"
/usr/bin/ditto "$ROOT/dist/双径.app" "$STAGE/双径.app"
if ! test -L "$STAGE/Applications"; then ln -s /Applications "$STAGE/Applications"; fi
/usr/bin/install -m 644 "$ROOT/docs/usage.md" "$STAGE/使用说明.md"
/usr/bin/hdiutil create -volname '双径 DualRoute' -srcfolder "$STAGE" -ov -format UDZO "$ROOT/dist/DualRoute-1.1.0.dmg"
/usr/bin/hdiutil verify "$ROOT/dist/DualRoute-1.1.0.dmg"
