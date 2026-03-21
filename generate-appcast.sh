#!/bin/bash
#
# generate-appcast.sh - Generate appcast.xml using Sparkle's native tool
#
# Usage:
#   ./scripts/generate-appcast.sh [options]
#
# Release files should be named: ${APP_NAME}-X.Y.Z.zip
# Release notes should be named: ${APP_NAME}-X.Y.Z.html or ${APP_NAME}-X.Y.Z.txt
#

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( dirname "$SCRIPT_DIR" )"

# Source project config if available (sets DOWNLOAD_URL_PREFIX, WEBSITE_URL, RELEASES_DIR, etc.)
CONFIG_FILE="$PROJECT_DIR/config.sh"
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
fi

RELEASES_DIR="${RELEASES_DIR:-$PROJECT_DIR/releases}"

# Check if generate_appcast exists
if [ ! -f "$SPARKLE_BIN/generate_appcast" ]; then
  echo "❌ Error: SPARKLE_BIN is not set or invalid."
  echo ""
  echo "Set it in your .env.local or shell profile:"
  echo "   export SPARKLE_BIN=\"\$HOME/Library/Developer/Xcode/DerivedData/[YourApp]/SourcePackages/artifacts/sparkle/Sparkle/bin\""
  exit 1
fi

# Create releases directory if it doesn't exist
mkdir -p "$RELEASES_DIR"

# Parse options
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-}"
LINK="${WEBSITE_URL:-}"
ED_KEY_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --download-url-prefix)
      DOWNLOAD_URL_PREFIX="$2"
      shift 2
      ;;
    --ed-key-file)
      ED_KEY_FILE="$2"
      shift 2
      ;;
    --help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --download-url-prefix URL   Download URL prefix (reads from config.sh DOWNLOAD_URL_PREFIX if not set)"
      echo "  --ed-key-file PATH          Path to EdDSA private key file"
      echo "  --help                      Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "🔨 Generating appcast using Sparkle..."

# Remove stale appcast so generate_appcast starts fresh (no merged old entries)
rm -f "$RELEASES_DIR/appcast.xml"

# Build command
CMD="$SPARKLE_BIN/generate_appcast"
CMD="$CMD --download-url-prefix $DOWNLOAD_URL_PREFIX"
CMD="$CMD --link $LINK"
CMD="$CMD --account ed25519"

if [ -n "$ED_KEY_FILE" ]; then
  CMD="$CMD --ed-key-file $ED_KEY_FILE"
fi

CMD="$CMD $RELEASES_DIR"

# Run generate_appcast
$CMD

# generate_appcast has a known issue accessing the keychain non-interactively.
# Sign each DMG individually with sign_update (which reliably reads from keychain)
# and patch the signatures into the appcast.
echo "✍️  Signing enclosures..."
for DMG in "$RELEASES_DIR"/*.dmg; do
  FILENAME=$(basename "$DMG")
  SIG_OUTPUT=$("$SPARKLE_BIN/sign_update" --account ed25519 "$DMG" 2>&1)
  EDSIG=$(echo "$SIG_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"')
  LENGTH=$(echo "$SIG_OUTPUT" | grep -o 'length="[^"]*"')
  if [ -n "$EDSIG" ]; then
    # Only add signature if not already present (generate_appcast may have signed it)
    if ! grep -q "${FILENAME}.*edSignature\|edSignature.*${FILENAME}" "$RELEASES_DIR/appcast.xml"; then
      /usr/bin/perl -i -pe "s|(<enclosure url=\"[^\"]*${FILENAME}[^\"]*\") (length=\"[^\"]*\")|\\1 ${EDSIG} ${LENGTH}|" "$RELEASES_DIR/appcast.xml"
    fi
  fi
done

echo "✅ Appcast generated and signed at: $RELEASES_DIR/appcast.xml"

# Prune DMG and delta files no longer referenced in the appcast
echo "🧹 Pruning unreferenced release files..."
PRUNED=0
for FILE in "$RELEASES_DIR"/*.dmg "$RELEASES_DIR"/*.delta; do
  [ -f "$FILE" ] || continue
  FNAME=$(basename "$FILE")
  if ! grep -q "$FNAME" "$RELEASES_DIR/appcast.xml"; then
    echo "   Removing: $FNAME"
    rm "$FILE"
    PRUNED=$((PRUNED + 1))
  fi
done
if [ "$PRUNED" -eq 0 ]; then
  echo "   Nothing to prune"
else
  echo "   Removed $PRUNED file(s)"
fi
