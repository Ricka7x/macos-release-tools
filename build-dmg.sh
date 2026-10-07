#!/bin/bash
#
# build-dmg.sh - Build and package a DMG for local testing (NO release)
#
# This script runs the build pipeline up through DMG creation but stops there.
# It does NOT:
#   - Copy the DMG to releases/
#   - Generate release notes or appcast.xml
#   - Commit, tag, or push anything to git
#
# The resulting DMG is left in the build directory for you to test manually.
#
# Usage:
#   ./scripts/build-dmg.sh [options]
#
# By default, the script:
#   - Uses the current version from Info.plist (no bump)
#   - Skips notarization (right-click → Open to bypass Gatekeeper)
#
# Options:
#   --version VERSION      Override the version (e.g. 0.2.0)
#   --bump-version         Auto-detect and bump version via git-cliff
#   --notarize             Notarize the app (slower, but Gatekeeper-clean)
#   --open                 Open the DMG in Finder after building
#   --dry-run              Show what would be done without making changes
#   --verbose              Enable verbose output
#   --help                 Show this help message
#

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( dirname "$SCRIPT_DIR" )"

# Source project-specific configuration (lives in the consumer repo, not here)
CONFIG_FILE="$PROJECT_DIR/config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "❌ config.sh not found at: $CONFIG_FILE"
  echo ""
  echo "   Copy the template to get started:"
  echo "   cp scripts/config.example.sh config.sh"
  echo "   Then fill in your project-specific values."
  exit 1
fi
source "$CONFIG_FILE"

# ============================================================================
# DEFAULTS AND ARGUMENT PARSING
# ============================================================================

DRY_RUN=false
OVERRIDE_VERSION=""
VERBOSE=false
DO_NOTARIZE=false
DO_VERSION_BUMP=false
OPEN_DMG=false
BUILD_NUMBER="unknown"

show_help() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Build and package a DMG for local testing (no release, no git)."
  echo "Uses the current plist version and skips notarization by default."
  echo ""
  echo "Options:"
  echo "  --version VERSION      Override the version string"
  echo "  --bump-version         Auto-detect next version via git-cliff and bump plist"
  echo "  --notarize             Notarize the app (slower, but Gatekeeper-clean)"
  echo "  --open                 Open the DMG in Finder after building"
  echo "  --dry-run              Show what would be done without making changes"
  echo "  --verbose              Enable verbose output"
  echo "  --help                 Show this help message"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --notarize)
      DO_NOTARIZE=true
      shift
      ;;
    --bump-version)
      DO_VERSION_BUMP=true
      shift
      ;;
    --open)
      OPEN_DMG=true
      shift
      ;;
    --version)
      [ -z "${2:-}" ] && { log_error "--version requires a value"; exit 1; }
      OVERRIDE_VERSION="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

# ============================================================================
# INITIALIZATION
# ============================================================================

mkdir -p "$(dirname "$LOG_FILE")"
echo "=== $APP_NAME Test Build Started: $(date) ===" > "$LOG_FILE"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              $APP_NAME - TEST BUILD (no release)            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

log_info "Starting $APP_NAME test build pipeline..."
log_info "Project directory: $PROJECT_DIR"
log_info "Xcode project: $XCODE_PROJECT_PATH"

if ! $DO_NOTARIZE; then
  log_info "Notarization OFF (use --notarize to enable). Right-click → Open to bypass Gatekeeper."
fi
if ! $DO_VERSION_BUMP; then
  log_info "Version bump OFF: using current plist version (use --bump-version to auto-detect)"
fi

# ============================================================================
# VALIDATION PHASE
# ============================================================================

log_info "Validating configuration..."

if ! validate_config; then
  log_error "Configuration validation failed"
  exit 1
fi

log_success "Configuration validated"

# ============================================================================
# TOOL CHECK
# ============================================================================

log_info "Checking required tools..."

REQUIRED_TOOLS=(xcodebuild create-dmg xcrun ditto)
if $DO_VERSION_BUMP && [ -z "$OVERRIDE_VERSION" ]; then
  REQUIRED_TOOLS+=(git-cliff)
fi

for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_error "Required tool not found: $tool"
    exit 1
  fi
done

log_success "All required tools available"

# ============================================================================
# VERSION DETECTION
# ============================================================================

PLIST_PATH="$XCODE_PROJECT_PATH/$INFO_PLIST"
PBXPROJ="$XCODE_PROJECT_PATH/$XCODE_SCHEME.xcodeproj/project.pbxproj"

if ! file_exists "$PLIST_PATH"; then
  log_error "Info.plist not found at: $PLIST_PATH"
  exit 1
fi

if [ -n "$OVERRIDE_VERSION" ]; then
  VERSION="$OVERRIDE_VERSION"
  CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST_PATH" 2>/dev/null || echo "0")
  BUILD_NUMBER="$CURRENT_BUILD"
  log_info "Using override version: $VERSION (build $BUILD_NUMBER)"
elif $DO_VERSION_BUMP; then
  log_info "Determining next version from git history..."

  LAST_TAG=$(git -C "$XCODE_PROJECT_PATH" tag --sort=-version:refname 2>/dev/null | head -1)

  if [ -z "$LAST_TAG" ]; then
    CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST_PATH" | tr -d '[:space:]')
    IFS='.' read -r V_MAJOR V_MINOR V_PATCH <<< "$CURRENT_VERSION"
    VERSION="$V_MAJOR.$((V_MINOR + 1)).0"
    log_info "No tags found, using $CURRENT_VERSION -> $VERSION as first release"
  else
    VERSION=$(git-cliff \
                --repository "$XCODE_PROJECT_PATH" \
                --config "$SCRIPT_DIR/cliff.toml" \
                --bumped-version 2>>"$LOG_FILE" | tr -d '[:space:]')
    VERSION="${VERSION#v}"

    if [ -z "$VERSION" ]; then
      log_error "git-cliff could not determine next version."
      exit 1
    fi
  fi

  CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST_PATH" 2>/dev/null || echo "0")
  if [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    BUILD_NUMBER=$((CURRENT_BUILD + 1))
  else
    BUILD_NUMBER="$CURRENT_BUILD"
  fi
else
  # Default: use current version from Info.plist (no bump)
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST_PATH" | tr -d '[:space:]')
  BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST_PATH" 2>/dev/null || echo "0")
  log_info "Using current version: $VERSION (build $BUILD_NUMBER)"
fi

log_success "Version: $VERSION (build $BUILD_NUMBER)"

# ============================================================================
# VERSION BUMP PHASE
# ============================================================================

if $DO_VERSION_BUMP; then
  log_info "Writing version to app repo..."

  if $DRY_RUN; then
    log_warn "[DRY RUN] Would bump Info.plist and project.pbxproj to $VERSION (build $BUILD_NUMBER)"
  else
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST_PATH"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST_PATH"

    sed -i '' "s/MARKETING_VERSION = [0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/MARKETING_VERSION = $VERSION/g" "$PBXPROJ"
    sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9][0-9]*/CURRENT_PROJECT_VERSION = $BUILD_NUMBER/g" "$PBXPROJ"

    log_success "Version bumped to $VERSION (build $BUILD_NUMBER)"
  fi
fi

# ============================================================================
# BUILD PHASE
# ============================================================================

log_info "Starting Xcode build..."

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log_debug "Build directory: $BUILD_DIR"
log_info "Creating archive..."

if $DRY_RUN; then
  log_warn "[DRY RUN] Would execute xcodebuild archive"
else
  if ! xcodebuild \
    -project "$XCODE_PROJECT_PATH/$XCODE_SCHEME.xcodeproj" \
    -scheme "$XCODE_SCHEME" \
    -configuration "$XCODE_CONFIG" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    archive \
    -archivePath "$ARCHIVE_PATH" \
    >> "$LOG_FILE" 2>&1; then
    log_error "Archive failed. Check log: $LOG_FILE"
    exit 1
  fi

  log_success "Archive created successfully"
fi

# ============================================================================
# EXPORT PHASE
# ============================================================================

log_info "Exporting app bundle..."

if ! $DRY_RUN; then
  # Read signing certificate from config; fall back to a generic developer-id style
  SIGNING_CERT="${CODE_SIGN_IDENTITY:-Developer ID Application}"

  # Same as build-and-release.sh's export phase: manual-signing distribution requires
  # an explicit provisioning profile when the app has entitlements beyond plain
  # sandboxing/network (e.g. iCloud). Set BUNDLE_IDENTIFIER and PROVISIONING_PROFILE_UUID
  # in config.sh for apps that need one (Boomark does for its CloudKit container;
  # Snapback and Peggo don't and leave both unset).
  PROVISIONING_BLOCK=""
  if [ -n "${PROVISIONING_PROFILE_UUID:-}" ]; then
    if [ -z "${BUNDLE_IDENTIFIER:-}" ]; then
      log_error "PROVISIONING_PROFILE_UUID is set but BUNDLE_IDENTIFIER is not. Both are required together."
      exit 1
    fi
    PROVISIONING_BLOCK="    <key>provisioningProfiles</key>
    <dict>
        <key>$BUNDLE_IDENTIFIER</key>
        <string>$PROVISIONING_PROFILE_UUID</string>
    </dict>
"
  fi

  cat > "$EXPORT_OPTIONS_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>$SIGNING_CERT</string>
    <key>stripSwiftSymbols</key>
    <true/>
$PROVISIONING_BLOCK</dict>
</plist>
PLIST

  xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -exportPath "$EXPORT_PATH" \
    >> "$LOG_FILE" 2>&1

  log_success "App bundle exported successfully"
fi

# ============================================================================
# NOTARIZATION PHASE (optional)
# ============================================================================

if $DO_NOTARIZE; then
  log_info "Notarizing app bundle..."

  if ! $DRY_RUN; then
    APP_PATH="$EXPORT_PATH/$APP_NAME.app"

    # Inject Sparkle keys into the exported bundle before codesigning.
    # These values come from config.sh; only inject if defined.
    APP_PLIST="$APP_PATH/Contents/Info.plist"
    if [ -n "${SPARKLE_ED_PUBLIC_KEY:-}" ]; then
      /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_ED_PUBLIC_KEY" "$APP_PLIST" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_ED_PUBLIC_KEY" "$APP_PLIST"
    fi
    if [ -n "${DOWNLOAD_URL_PREFIX:-}" ]; then
      /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $DOWNLOAD_URL_PREFIX/appcast.xml" "$APP_PLIST" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :SUFeedURL $DOWNLOAD_URL_PREFIX/appcast.xml" "$APP_PLIST"
    fi
    /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$APP_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks true" "$APP_PLIST"
    log_info "Injected Sparkle keys into Info.plist"

    # Re-sign the Sparkle framework and the app
    if [ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]; then
      codesign --force --deep --sign "$CODE_SIGN_IDENTITY" \
        --timestamp --options runtime \
        "$APP_PATH/Contents/Frameworks/Sparkle.framework" \
        >> "$LOG_FILE" 2>&1
    fi

    codesign --force --sign "$CODE_SIGN_IDENTITY" \
      --timestamp --options runtime \
      "$APP_PATH" \
      >> "$LOG_FILE" 2>&1

    NOTARIZE_ZIP="$BUILD_DIR/$APP_NAME-notarize.zip"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

    if [ -n "${NOTARY_PROFILE:-}" ]; then
      xcrun notarytool submit "$NOTARIZE_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait >> "$LOG_FILE" 2>&1
    else
      xcrun notarytool submit "$NOTARIZE_ZIP" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait >> "$LOG_FILE" 2>&1
    fi

    log_success "Notarization succeeded"

    xcrun stapler staple "$APP_PATH" >> "$LOG_FILE" 2>&1
    spctl --assess --verbose "$APP_PATH" >> "$LOG_FILE" 2>&1
  fi
fi

# ============================================================================
# PACKAGING PHASE
# ============================================================================

log_info "Creating DMG..."

RELEASE_NAME="$APP_NAME-$VERSION"
RELEASE_DMG="$BUILD_DIR/$RELEASE_NAME.dmg"

if $DRY_RUN; then
  log_warn "[DRY RUN] Would create DMG at: $RELEASE_DMG"
else

  create-dmg \
    --overwrite \
    "$EXPORT_PATH/$APP_NAME.app" \
    "$BUILD_DIR" \
    >> "$LOG_FILE" 2>&1

  # create-dmg names the output "<AppName> <Version>.dmg"; rename to our convention
  mv "$BUILD_DIR/$APP_NAME $VERSION.dmg" "$RELEASE_DMG"

  log_success "DMG created: $RELEASE_DMG"
fi

# ============================================================================
# DONE: no release, no git, no appcast
# ============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                   TEST BUILD COMPLETE                      ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║ Version:        $VERSION (build $BUILD_NUMBER)"
echo "║ DMG:            $RELEASE_DMG"
echo "║ Notarized:      $( $DO_NOTARIZE && echo 'YES' || echo 'NO' )"
echo "║ Build Log:      $LOG_FILE"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║                                                            ║"
echo "║  To test:  open $RELEASE_DMG"
echo "║                                                            ║"
echo "║  When ready to release, run:                               ║"
echo "║    ./scripts/build-and-release.sh --version $VERSION"
echo "║                                                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Open DMG if requested
if $OPEN_DMG && ! $DRY_RUN && [ -f "$RELEASE_DMG" ]; then
  log_info "Opening DMG in Finder..."
  open "$RELEASE_DMG"
fi

exit 0
