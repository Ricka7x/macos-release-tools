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

# Resolve Sparkle tools path. Prefer explicit env var, then fall back to common install locations.
resolve_sparkle_bin() {
  local candidate=""

  # 1) Explicit path set by user
  if [ -n "${SPARKLE_BIN:-}" ] && [ -x "$SPARKLE_BIN/generate_appcast" ] && [ -x "$SPARKLE_BIN/sign_update" ]; then
    echo "$SPARKLE_BIN"
    return 0
  fi

  # 2) Optional override alias kept for compatibility with older docs
  if [ -n "${SPARKLE_TOOLS_PATH:-}" ] && [ -x "$SPARKLE_TOOLS_PATH/generate_appcast" ] && [ -x "$SPARKLE_TOOLS_PATH/sign_update" ]; then
    echo "$SPARKLE_TOOLS_PATH"
    return 0
  fi

  # 3) If generate_appcast is on PATH, derive bin dir from it
  candidate="$(command -v generate_appcast 2>/dev/null || true)"
  if [ -n "$candidate" ]; then
    candidate="$(dirname "$candidate")"
    if [ -x "$candidate/generate_appcast" ] && [ -x "$candidate/sign_update" ]; then
      echo "$candidate"
      return 0
    fi
  fi

  # 4) Homebrew common locations
  for candidate in \
    "/opt/homebrew/opt/sparkle/bin" \
    "/usr/local/opt/sparkle/bin"; do
    if [ -x "$candidate/generate_appcast" ] && [ -x "$candidate/sign_update" ]; then
      echo "$candidate"
      return 0
    fi
  done

  # 5) Xcode Swift Package artifacts in DerivedData (pick newest)
  while IFS= read -r candidate; do
    if [ -x "$candidate/generate_appcast" ] && [ -x "$candidate/sign_update" ]; then
      echo "$candidate"
      return 0
    fi
  done < <(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null || true)

  return 1
}

if RESOLVED_SPARKLE_BIN="$(resolve_sparkle_bin)"; then
  SPARKLE_BIN="$RESOLVED_SPARKLE_BIN"
  export SPARKLE_BIN
else
  echo "❌ Error: SPARKLE_BIN is not set or invalid, and auto-detection failed."
  echo ""
  echo "Set it in your .env.local or shell profile:"
  echo "   export SPARKLE_BIN=\"\$HOME/Library/Developer/Xcode/DerivedData/[YourApp]/SourcePackages/artifacts/sparkle/Sparkle/bin\""
  echo ""
  echo "Also supported:"
  echo "   export SPARKLE_TOOLS_PATH=\"/path/to/sparkle/bin\""
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
CMD="$CMD --download-url-prefix ${DOWNLOAD_URL_PREFIX%/}/"
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
