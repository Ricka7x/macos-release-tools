#!/bin/bash
#
# release.sh - Add a new app release
#
# Usage:
#   ./scripts/release.sh Snapback-1.0.0.zip [options]
#
# Options:
#   --release-notes path/to/file.html   HTML or TXT file with release notes
#   --ed-key-file path/to/key          EdDSA private key file (optional)
#

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( dirname "$SCRIPT_DIR" )"
RELEASES_DIR="$PROJECT_DIR/releases"

if [ $# -lt 1 ]; then
  echo "Usage: $0 Snapback-X.Y.Z.[zip|dmg] [options]"
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
if ! [[ "$FILENAME" =~ ^Snapback-[0-9]+\.[0-9]+\.[0-9]+\.(zip|dmg)$ ]]; then
  echo "❌ Invalid filename format. Expected: Snapback-X.Y.Z.zip or Snapback-X.Y.Z.dmg"
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
  VERSION="${FILENAME#Snapback-}"
  VERSION="${VERSION%.zip}"
  VERSION="${VERSION%.dmg}"
  RELEASE_NOTES_EXT="${RELEASE_NOTES##*.}"
  
  RELEASE_NOTES_DEST="$RELEASES_DIR/Snapback-$VERSION.$RELEASE_NOTES_EXT"
  cp "$RELEASE_NOTES" "$RELEASE_NOTES_DEST"
  echo "✅ Copied release notes to releases/Snapback-$VERSION.$RELEASE_NOTES_EXT"
fi

# Generate appcast
echo ""
if [ -n "$ED_KEY_FILE" ]; then
  "$SCRIPT_DIR/generate-appcast.sh" --ed-key-file "$ED_KEY_FILE"
else
  "$SCRIPT_DIR/generate-appcast.sh"
fi

echo ""
VERSION="${FILENAME#Snapback-}"
VERSION="${VERSION%.zip}"
VERSION="${VERSION%.dmg}"
echo "🎉 Release complete!"
echo "   Version: $VERSION"
echo "   URL: https://snapbackapp.com/releases/$FILENAME"
