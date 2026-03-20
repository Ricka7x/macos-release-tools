#!/bin/bash
#
# config.sh - Centralized configuration for Snapback release automation
#
# This file contains all configurable settings for the build and release pipeline.
# Update these values to match your project setup.
#
# SECURITY NOTE:
# - Public URLs (https://snapbackapp.com) are safe to commit
# - API keys, private keys, and credentials should use environment variables
# - See .env.local (in .gitignore) for sensitive overrides
#

# ============================================================================
# PROJECT SETTINGS
# ============================================================================

# Project paths
PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
XCODE_PROJECT_PATH="/Users/ricka7x/XcodeProjects/Snapback"
XCODE_SCHEME="Snapback"
XCODE_CONFIG="Release"

# Info.plist location (relative to XCODE_PROJECT_PATH)
INFO_PLIST="Snapback/Info.plist"

# Build output paths
BUILD_DIR="/tmp/snapback-build"
ARCHIVE_PATH="$BUILD_DIR/Snapback.xcarchive"
EXPORT_PATH="$BUILD_DIR/Export"

# Release configuration
RELEASES_DIR="$PROJECT_ROOT/releases"
WEBSITE_URL="https://snapbackapp.com"
DOWNLOAD_URL_PREFIX="$WEBSITE_URL/releases"

# ============================================================================
# SPARKLE SETTINGS
# ============================================================================

# Sparkle binary is auto-detected by sparkle.env
# See sparkle.env for detection strategy and custom configuration
#
# For custom Sparkle locations, use environment variable:
#   export SPARKLE_TOOLS_PATH="/path/to/sparkle/bin"
#   ./scripts/build-and-release.sh

# Sparkle configuration file (optional EdDSA key)
SPARKLE_ED_KEY_FILE="${SPARKLE_ED_KEY_FILE:-}"

# ============================================================================
# BUILD SETTINGS
# ============================================================================

# Code signing identity (leave empty for automatic)
CODE_SIGN_IDENTITY="Developer ID Application: Ricardo Ramirez (6WA4QS23C4)"

# Export options plist (created dynamically if not present)
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"


#=============================================================================
# NOTARIZATION SETTINGS
#=============================================================================
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# ============================================================================
# LOGGING AND DEBUGGING
# ============================================================================

# Enable verbose output
VERBOSE="${VERBOSE:-false}"

# Log file
LOG_FILE="$PROJECT_ROOT/build.log"

# ============================================================================
# VALIDATION SETTINGS
# ============================================================================

# Minimum macOS deployment target
MIN_MACOS_VERSION="12.4"

# Required files that must exist after build
REQUIRED_FILES=(
  "$EXPORT_PATH/Snapback.app"
)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Print colored output
log_info() {
  echo "ℹ️  $1"
  echo "[INFO] $1" >> "$LOG_FILE"
}

log_success() {
  echo "✅ $1"
  echo "[SUCCESS] $1" >> "$LOG_FILE"
}

log_warn() {
  echo "⚠️  $1"
  echo "[WARN] $1" >> "$LOG_FILE"
}

log_error() {
  echo "❌ $1"
  echo "[ERROR] $1" >> "$LOG_FILE"
}

log_debug() {
  if [ "$VERBOSE" = "true" ]; then
    echo "🔍 $1"
  fi
  echo "[DEBUG] $1" >> "$LOG_FILE"
}

# Check if command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check if file exists
file_exists() {
  [ -f "$1" ]
}

# Check if directory exists
dir_exists() {
  [ -d "$1" ]
}

# Validate configuration
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
  
  if [ $errors -gt 0 ]; then
    return 1
  fi
  
  return 0
}

# Export path for use in other scripts
export PROJECT_ROOT
export XCODE_PROJECT_PATH
export RELEASES_DIR
export BUILD_DIR
export LOG_FILE
# ============================================================================
# ENVIRONMENT VARIABLE OVERRIDES (optional for sensitive values)
# ============================================================================
#
# For sensitive configuration (API keys, private URLs, etc.), use environment
# variables instead of committing to version control:
#
# Example: Setting a private EdDSA key
#   export SPARKLE_ED_KEY_FILE="$HOME/.sparkle/private.key"
#   ./build-and-release.sh
#
# Example: Using a private CDN URL for releases
#   export DOWNLOAD_URL_PREFIX="https://private.example.com/releases"
#   ./build-and-release.sh
#
# These environment variables override the defaults above if set.
# They are NOT stored in git, protecting sensitive data.
#