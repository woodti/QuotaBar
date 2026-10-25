#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/QuotaBar.app}"
OUT="${2:-dist/QuotaBar-macos-arm64.dmg}"
STAGE="$(mktemp -d /tmp/quotabar-dmg.XXXXXX)"
mkdir -p "$STAGE/QuotaBar"
ditto "$APP" "$STAGE/QuotaBar/QuotaBar.app"
ln -s /Applications "$STAGE/QuotaBar/Applications"
hdiutil create -volname "QuotaBar" -srcfolder "$STAGE/QuotaBar" -format UDZO -ov "$OUT"
echo "$OUT"
