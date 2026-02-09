#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP=Ripcord
BUNDLE="$APP.app"
INSTALL_DIR="$HOME/Applications"
BUNDLE_ID=com.vibe.ripcord

# ── Test ──
echo "Running tests..."
make test

# ── Build & bundle ──
echo "Building..."
make bundle

# ── Install ──
killall "$APP" 2>/dev/null && sleep 1 || true
make install

# ── Launch ──
echo "Launching $APP..."
open "$INSTALL_DIR/$BUNDLE"

echo ""
echo "Done. Grant System Audio Recording permission if prompted:"
echo "  System Settings > Privacy & Security > System Audio Recording > enable $APP"
