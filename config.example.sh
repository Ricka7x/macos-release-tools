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

# App name — used for DMG/zip naming and release notes filenames
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
# SPARKLE SETTINGS
# ============================================================================

# Sparkle binary path must be set via environment variable
# Set in your .env.local or shell profile:
#   export SPARKLE_BIN="$HOME/Library/Developer/Xcode/DerivedData/[YourApp]/SourcePackages/artifacts/sparkle/Sparkle/bin"

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
# HELPER FUNCTIONS — do not edit below this line
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
