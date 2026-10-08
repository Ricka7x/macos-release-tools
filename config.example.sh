#!/bin/bash
#
# config.sh - Project-specific configuration for the release pipeline
#
# HOW TO USE:
#   1. Copy this file to the ROOT of your release repo (NOT inside scripts/):
#        cp scripts/config.example.sh config.sh
#   2. Fill in your project-specific values below
#   3. config.sh should be committed to your release repo
#
# SECURITY NOTE:
#   - Public URLs and paths are safe to commit
#   - API keys, passwords, and private keys must use environment variables
#   - See .env.local (gitignored) for sensitive overrides
#

# ============================================================================
# PROJECT SETTINGS
# ============================================================================

# App name: used for DMG/zip naming and release notes filenames
# e.g. "MyApp" produces MyApp-1.0.0.dmg, MyApp-1.0.0.html
APP_NAME="MyApp"

# Absolute path to the Xcode project directory
XCODE_PROJECT_PATH="/path/to/YourApp"

# Xcode scheme and build configuration
XCODE_SCHEME="MyApp"
XCODE_CONFIG="Release"

# Info.plist location (relative to XCODE_PROJECT_PATH)
INFO_PLIST="MyApp/Info.plist"

# Build output paths (temporary, not committed)
BUILD_DIR="/tmp/myapp-build"
ARCHIVE_PATH="$BUILD_DIR/MyApp.xcarchive"
EXPORT_PATH="$BUILD_DIR/Export"

# Project root is the directory containing this config.sh
PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Release files directory (where DMGs, appcast.xml, and HTML notes are stored)
RELEASES_DIR="$PROJECT_ROOT/releases"

# Public website and download URLs
WEBSITE_URL="https://yourapp.com"
DOWNLOAD_URL_PREFIX="$WEBSITE_URL/releases"

# ============================================================================
# SHARED R2 RELEASE HOSTING (optional)
# ============================================================================

# If set, release.sh syncs releases/ to this Cloudflare R2 bucket via rclone
# after generating the appcast, instead of (or in addition to) committing
# DMGs/appcast.xml to this git repo. Leave unset to keep the git-hosted flow.
#
# Requires: brew install rclone, and an rclone remote (default name "r2")
# configured in ~/.config/rclone/rclone.conf pointing at your R2 S3 API
# credentials (Access Key ID, Secret Access Key, S3 endpoint from the
# Cloudflare dashboard's R2 API token page). Never commit those credentials,
# keep them in rclone.conf or Keychain only.
#
# If DOWNLOAD_URL_PREFIX above points at this same R2 bucket's custom domain
# (e.g. "https://dl.66labs.dev/$APP_NAME"), release URLs stay correct without
# further changes.
R2_BUCKET="${R2_BUCKET:-}"
R2_REMOTE="${R2_REMOTE:-r2}"
R2_PREFIX="${R2_PREFIX:-$APP_NAME}"

# Optional: immediately purge Cloudflare's cache for the files just synced to
# R2, instead of waiting for Cloudflare's own TTL to expire. Without this, a
# release that reuses an existing filename (the marketing version didn't bump,
# only the build number did, so the DMG's name repeats a prior release's) can
# have Cloudflare keep serving the OLD cached bytes at that path, which fails
# Sparkle's signature check for anyone who updates before the cache naturally
# refreshes.
#
# Set to the Cloudflare zone ID that DOWNLOAD_URL_PREFIX's domain belongs to
# (dashboard > that domain > Overview > Zone ID in the right sidebar). Also
# requires CLOUDFLARE_API_TOKEN exported in your shell (never put it in this
# file), scoped to Zone > Cache Purge > Purge for that zone, and `brew install
# jq`. Leave CF_ZONE_ID unset to skip this step entirely.
CF_ZONE_ID="${CF_ZONE_ID:-}"

# ============================================================================
# TEST GATE (optional)
# ============================================================================

# Shell command run before anything else touches a file (version bump,
# archive, etc.). A non-zero exit aborts the whole release with the repo
# completely untouched. Runs with its working directory set to
# XCODE_PROJECT_PATH. Leave unset to skip the gate (not recommended once a
# test suite exists).
#
# Examples:
#   TEST_COMMAND="xcodebuild test -scheme MyApp -destination 'platform=macOS'"
#   TEST_COMMAND="cd MyAppKit && swift test"
TEST_COMMAND="${TEST_COMMAND:-}"

# ============================================================================
# EXTERNAL SITE SYNC (optional)
# ============================================================================

# Path to another repo whose own releases/ folder should also receive a copy
# of this release's DMG, release notes, and appcast.xml, for an app with a
# dedicated marketing site that has its own independent deploy workflow
# reading from its own local releases/ folder. Every copy is checksum-
# verified against its source before anything commits it, and this step
# never touches that repo's code, only its releases/ data. Leave unset for
# an app with no dedicated site.
EXTERNAL_SITE_REPO="${EXTERNAL_SITE_REPO:-}"

# ============================================================================
# CATALOG DOWNLOAD LINK (optional)
# ============================================================================

# Path to a catalog data file (e.g. 66-studio's src/lib/apps.ts) and the
# app's slug within it. If both are set, update-catalog-link.py updates that
# app's `download:` field to this release's DMG URL, scoped so it can never
# touch another app's entry. Both are required together; leave both unset if
# the app has no catalog entry yet.
CATALOG_FILE="${CATALOG_FILE:-}"
CATALOG_APP_SLUG="${CATALOG_APP_SLUG:-}"

# ============================================================================
# SPARKLE SETTINGS
# ============================================================================

# Sparkle tools are auto-detected by scripts/generate-appcast.sh.
# It checks SPARKLE_BIN/SPARKLE_TOOLS_PATH first, then common install paths,
# then the newest DerivedData Sparkle artifact directory.
#
# Optional explicit override in your .env.local or shell profile:
#   export SPARKLE_BIN="$HOME/Library/Developer/Xcode/DerivedData/[YourApp]/SourcePackages/artifacts/sparkle/Sparkle/bin"

# The app's public EdDSA key (from Sparkle's generate_keys tool), injected into
# Info.plist's SUPublicEDKey during the build. REQUIRED, the build refuses to
# run without it, never borrow another app's key here.
SPARKLE_ED_PUBLIC_KEY="${SPARKLE_ED_PUBLIC_KEY:-}"

# Keychain account name under which this app's Sparkle EdDSA private key is
# stored (generate_keys / sign_update --account <name>). Each app should use
# its own account name (e.g. the app's lowercase name) so multiple apps'
# signing keys on the same Mac never collide. Defaults to "ed25519" (Sparkle's
# own default account name) for backward compatibility with apps that never
# set this explicitly.
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-ed25519}"

# Optional EdDSA private key file for signing releases
# Use environment variable to avoid committing private key path
SPARKLE_ED_KEY_FILE="${SPARKLE_ED_KEY_FILE:-}"

# ============================================================================
# BUILD SETTINGS
# ============================================================================

# Code signing identity (from Keychain)
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"

# Export options plist (generated dynamically during build)
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"

# ============================================================================
# NOTARIZATION SETTINGS
# ============================================================================

# Keychain profile name (set up with: xcrun notarytool store-credentials)
# Recommended over APPLE_ID/TEAM_ID/APP_PASSWORD
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# Alternative: use environment variables (never commit these values)
# export APPLE_ID="you@example.com"
# export TEAM_ID="XXXXXXXXXX"
# export APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"

# ============================================================================
# LOGGING
# ============================================================================

VERBOSE="${VERBOSE:-false}"
LOG_FILE="$PROJECT_ROOT/build.log"

# ============================================================================
# VALIDATION
# ============================================================================

MIN_MACOS_VERSION="12.0"

REQUIRED_FILES=(
  "$EXPORT_PATH/$APP_NAME.app"
)

# ============================================================================
# HELPER FUNCTIONS: do not edit below this line
# ============================================================================

log_info()    { echo "ℹ️  $1"; echo "[INFO] $1"    >> "$LOG_FILE"; }
log_success() { echo "✅ $1"; echo "[SUCCESS] $1" >> "$LOG_FILE"; }
log_warn()    { echo "⚠️  $1"; echo "[WARN] $1"    >> "$LOG_FILE"; }
log_error()   { echo "❌ $1"; echo "[ERROR] $1"   >> "$LOG_FILE"; }
log_debug()   { if [ "$VERBOSE" = "true" ]; then echo "🔍 $1"; fi; echo "[DEBUG] $1" >> "$LOG_FILE"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }
file_exists()    { [ -f "$1" ]; }
dir_exists()     { [ -d "$1" ]; }

validate_config() {
  local errors=0

  if ! dir_exists "$XCODE_PROJECT_PATH"; then
    log_error "Xcode project path not found: $XCODE_PROJECT_PATH"
    errors=$((errors + 1))
  fi

  if ! file_exists "$XCODE_PROJECT_PATH/$INFO_PLIST"; then
    log_error "Info.plist not found: $XCODE_PROJECT_PATH/$INFO_PLIST"
    errors=$((errors + 1))
  fi

  if ! command_exists "xcodebuild"; then
    log_error "xcodebuild not found. Please install Xcode."
    errors=$((errors + 1))
  fi

  [ $errors -gt 0 ] && return 1 || return 0
}

export PROJECT_ROOT XCODE_PROJECT_PATH RELEASES_DIR BUILD_DIR LOG_FILE APP_NAME
