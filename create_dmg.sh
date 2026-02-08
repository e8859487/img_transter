#!/bin/bash

# Script to create a DMG file for the macOS app

set -e

# Configuration
APP_NAME="iphone_img_transfer"
APP_PATH="build/macos/Build/Products/Release/${APP_NAME}.app"
DMG_NAME="${APP_NAME}_$(date +%Y%m%d_%H%M%S).dmg"
VOLUME_NAME="${APP_NAME}"
TEMP_DMG="temp_${DMG_NAME}"

# Check if app exists
if [ ! -d "$APP_PATH" ]; then
    echo "Error: App not found at $APP_PATH"
    echo "Please run 'flutter build macos --release' first"
    exit 1
fi

echo "Creating DMG for ${APP_NAME}..."

# Create temporary directory
TEMP_DIR=$(mktemp -d)
echo "Using temporary directory: $TEMP_DIR"

# Copy app to temp directory
cp -R "$APP_PATH" "$TEMP_DIR/"

# Create DMG
echo "Creating disk image..."
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$TEMP_DIR" -ov -format UDZO "$DMG_NAME"

# Clean up
rm -rf "$TEMP_DIR"

echo "✅ DMG created successfully: $DMG_NAME"
echo "Size: $(du -h "$DMG_NAME" | cut -f1)"
