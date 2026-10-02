#!/bin/bash
#
# release.sh - Add a new app release
#
# Usage:
#   ./scripts/release.sh ${APP_NAME}-1.0.0.zip [options]
#
# Options:
#   --release-notes path/to/file.html   HTML or TXT file with release notes
#   --ed-key-file path/to/key          EdDSA private key file (optional)
#

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( dirname "$SCRIPT_DIR" )"

CONFIG_FILE="$PROJECT_DIR/config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "❌ config.sh not found at: $CONFIG_FILE"
  echo "   Copy scripts/config.example.sh to config.sh and fill in your values."
  exit 1
fi
source "$CONFIG_FILE"

RELEASES_DIR="${RELEASES_DIR:-$PROJECT_DIR/releases}"

if [ $# -lt 1 ]; then
  echo "Usage: $0 ${APP_NAME}-X.Y.Z.[zip|dmg] [options]"
  echo ""
  echo "Options:"
  echo "  --release-notes PATH    HTML or TXT file with release notes"
  echo "  --ed-key-file PATH      EdDSA private key file"
  exit 1
fi

RELEASE_FILE="$1"
RELEASE_NOTES=""
ED_KEY_FILE=""
shift

# Parse additional arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --release-notes)
      RELEASE_NOTES="$2"
      shift 2
      ;;
    --ed-key-file)
      ED_KEY_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Validate file exists
if [ ! -f "$RELEASE_FILE" ]; then
  echo "❌ File not found: $RELEASE_FILE"
  exit 1
fi

# Extract filename
FILENAME=$(basename "$RELEASE_FILE")

# Validate filename format
if ! [[ "$FILENAME" =~ ^${APP_NAME}-[0-9]+\.[0-9]+\.[0-9]+\.(zip|dmg)$ ]]; then
  echo "❌ Invalid filename format. Expected: ${APP_NAME}-X.Y.Z.zip or ${APP_NAME}-X.Y.Z.dmg"
  echo "   Got: $FILENAME"
  exit 1
fi

echo "📦 Adding release: $FILENAME"

# Create releases directory if needed
mkdir -p "$RELEASES_DIR"

# Copy zip file to releases directory
cp "$RELEASE_FILE" "$RELEASES_DIR/$FILENAME"
echo "✅ Copied archive to releases/"

# Copy release notes if provided
if [ -n "$RELEASE_NOTES" ] && [ -f "$RELEASE_NOTES" ]; then
  VERSION="${FILENAME#${APP_NAME}-}"
  VERSION="${VERSION%.zip}"
  VERSION="${VERSION%.dmg}"
  RELEASE_NOTES_EXT="${RELEASE_NOTES##*.}"
  
  RELEASE_NOTES_DEST="$RELEASES_DIR/${APP_NAME}-$VERSION.$RELEASE_NOTES_EXT"
  cp "$RELEASE_NOTES" "$RELEASE_NOTES_DEST"
  echo "✅ Copied release notes to releases/${APP_NAME}-$VERSION.$RELEASE_NOTES_EXT"
fi

# Generate appcast
echo ""
if [ -n "$ED_KEY_FILE" ]; then
  "$SCRIPT_DIR/generate-appcast.sh" --ed-key-file "$ED_KEY_FILE"
else
  "$SCRIPT_DIR/generate-appcast.sh"
fi

echo ""

# Optional: sync releases/ to a shared Cloudflare R2 bucket instead of (or in
# addition to) committing them to this git repo. Opt in per-app by setting
# R2_BUCKET in config.sh; apps that don't set it keep the git-hosted flow
# unchanged.
if [ -n "${R2_BUCKET:-}" ]; then
  R2_REMOTE="${R2_REMOTE:-r2}"
  R2_PREFIX="${R2_PREFIX:-$APP_NAME}"
  if ! command -v rclone >/dev/null 2>&1; then
    echo "❌ R2_BUCKET is set but rclone is not installed. Run: brew install rclone"
    exit 1
  fi
  echo "☁️  Syncing releases/ to r2://$R2_BUCKET/$R2_PREFIX ..."
  rclone sync "$RELEASES_DIR" "$R2_REMOTE:$R2_BUCKET/$R2_PREFIX" --progress
  echo "✅ Synced to R2"
fi

VERSION="${FILENAME#${APP_NAME}-}"
VERSION="${VERSION%.zip}"
VERSION="${VERSION%.dmg}"
echo "🎉 Release complete!"
echo "   Version: $VERSION"
echo "   URL: $DOWNLOAD_URL_PREFIX/$FILENAME"
