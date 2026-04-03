#!/bin/bash
# Install or update Ripcord from the latest GitHub release.
# Usage: curl -fsSL https://raw.githubusercontent.com/unthingable/ripcord/main/install.sh | bash

set -euo pipefail

REPO="unthingable/ripcord"
APP_NAME="Ripcord.app"
INSTALL_DIR="/Applications"
TMP_DIR=$(mktemp -d)

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "Fetching latest release..."
TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | cut -d'"' -f4)
ASSET_URL="https://github.com/$REPO/releases/download/$TAG/ripcord-$TAG.zip"
echo "Latest version: $TAG"

echo "Downloading $ASSET_URL..."
curl -fSL -o "$TMP_DIR/ripcord.zip" "$ASSET_URL"

echo "Extracting..."
unzip -qo "$TMP_DIR/ripcord.zip" -d "$TMP_DIR"

# Quit Ripcord if running
if pgrep -xq Ripcord; then
    echo "Stopping Ripcord..."
    osascript -e 'quit app "Ripcord"' 2>/dev/null || true
    sleep 1
fi

echo "Installing to $INSTALL_DIR/$APP_NAME..."
rm -rf "$INSTALL_DIR/$APP_NAME"
mv "$TMP_DIR/$APP_NAME" "$INSTALL_DIR/$APP_NAME"

echo "Removing quarantine attribute..."
xattr -dr com.apple.quarantine "$INSTALL_DIR/$APP_NAME" 2>/dev/null || true

echo "Ripcord $TAG installed to $INSTALL_DIR/$APP_NAME"
echo "Run: open /Applications/Ripcord.app"
