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

  # Optional: immediately purge Cloudflare's cache for the files just synced.
  # Without this, a release that reuses an existing filename (e.g. only the build
  # number bumped, not the marketing version, so the DMG's name repeats a prior
  # release's) can keep serving the OLD cached bytes at that unchanged path until
  # the cache's own TTL expires on its own, which fails Sparkle's signature check
  # for anyone who updates in that window, since the appcast's signature was
  # computed against the new file (seen first-hand on Peggo: build 4 reused
  # Peggo-0.1.2.dmg's name, and Cloudflare kept serving build 3's bytes under it
  # for over 25 minutes until manually purged). Opt in by setting CF_ZONE_ID in
  # config.sh to the zone DOWNLOAD_URL_PREFIX's domain belongs to, and exporting
  # CLOUDFLARE_API_TOKEN in your shell, scoped to Zone > Cache Purge > Purge for
  # that zone. Neither is required: without CF_ZONE_ID this step is skipped
  # entirely, same as R2_BUCKET itself.
  if [ -n "${CF_ZONE_ID:-}" ]; then
    if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
      echo "⚠️  CF_ZONE_ID is set but CLOUDFLARE_API_TOKEN is not exported, skipping cache purge"
    elif ! command -v jq >/dev/null 2>&1; then
      echo "⚠️  CF_ZONE_ID is set but jq is not installed, skipping cache purge. Run: brew install jq"
    else
      echo "🧹 Purging Cloudflare cache for synced files..."
      PURGE_FAILED=false
      PURGE_URLS=()
      while IFS= read -r -d '' f; do
        PURGE_URLS+=("$DOWNLOAD_URL_PREFIX/${f#"$RELEASES_DIR"/}")
      done < <(find "$RELEASES_DIR" -type f -print0)
      # Cloudflare's purge-by-URL endpoint caps at 30 URLs per request.
      for ((i = 0; i < ${#PURGE_URLS[@]}; i += 30)); do
        BATCH=("${PURGE_URLS[@]:i:30}")
        PURGE_BODY=$(printf '%s\n' "${BATCH[@]}" | jq -R . | jq -s '{files: .}')
        PURGE_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/purge_cache" \
          -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
          -H "Content-Type: application/json" \
          --data "$PURGE_BODY")
        if ! echo "$PURGE_RESPONSE" | jq -e '.success == true' >/dev/null 2>&1; then
          PURGE_FAILED=true
          echo "⚠️  Cloudflare cache purge batch failed: $(echo "$PURGE_RESPONSE" | jq -c '.errors')"
        fi
      done
      if [ "$PURGE_FAILED" = false ]; then
        echo "✅ Cloudflare cache purged"
      else
        echo "⚠️  Release still succeeded, but some cached files may be stale until their TTL expires"
      fi
    fi
  fi
fi

VERSION="${FILENAME#${APP_NAME}-}"
VERSION="${VERSION%.zip}"
VERSION="${VERSION%.dmg}"
echo "🎉 Release complete!"
echo "   Version: $VERSION"
echo "   URL: $DOWNLOAD_URL_PREFIX/$FILENAME"
