#!/usr/bin/env bash
# Download and extract Debian NSIS (makensis + data files) locally, so the
# installer can be built without root access.
#
# Usage:  tools/setup_nsis.sh
# Output: .local/nsis/usr/bin/makensis, .local/nsis/usr/share/nsis/...

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT_DIR/.local/nsis"
CACHE="$ROOT_DIR/.local/cache"
MAKENSIS="$DEST/usr/bin/makensis"
NSIS_DATA="$DEST/usr/share/nsis"
NSIS_STUBS="$NSIS_DATA/Stubs"

if [ -x "$MAKENSIS" ] && [ -d "$NSIS_STUBS" ]; then
    echo "NSIS already set up at $DEST"
    exit 0
fi

mkdir -p "$CACHE"

BASE="http://deb.debian.org/debian/pool/main/n/nsis"
DEBS=(
    "nsis-common_3.11-1_all.deb"
    "nsis_3.11-1_amd64.deb"
)

for deb in "${DEBS[@]}"; do
    if [ ! -f "$CACHE/$deb" ]; then
        echo "Downloading $deb ..."
        curl -fsSL "$BASE/$deb" -o "$CACHE/$deb"
    fi
done

rm -rf "$DEST"
mkdir -p "$DEST"
for deb in "${DEBS[@]}"; do
    dpkg-deb -x "$CACHE/$deb" "$DEST"
done

echo "OK. To build the installer:"
echo "  NSISDIR=$NSIS_DATA $DEST/usr/bin/makensis installer.nsi"
echo "(build_package.sh will pick it up automatically too)"