#!/bin/bash
#
# build-and-release.sh - Complete automated build and release pipeline
#
# This script handles the entire process from source code to production release:
# 1. Validates environment and configuration
# 2. Extracts version from Info.plist
# 3. Bumps version/build numbers
# 4. Builds and archives the Xcode project
# 5. Exports the app bundle
# 6. Notarizes and staples the app
# 7. Creates a release DMG archive
# 8. Generates the Sparkle appcast.xml
# 9. Commits changes to git
#
# Usage:
#   ./scripts/build-and-release.sh [options]
#
# Options:
#   --dry-run              Show what would be done without making changes
#   --skip-git             Don't commit or push to git
#   --release-notes FILE   Include release notes HTML/TXT file
#   --version VERSION      Override version detection
#   --bump TYPE            Version bump type: patch | minor | major (default: patch)
#   --verbose              Enable verbose output
#   --help                 Show this help message
#

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( dirname "$SCRIPT_DIR" )"

# Source configuration
source "$SCRIPT_DIR/config.sh"

# ============================================================================
# DEFAULTS AND ARGUMENT PARSING
# ============================================================================

DRY_RUN=false
SKIP_GIT=false
RELEASE_NOTES_FILE=""
OVERRIDE_VERSION=""
VERBOSE=false
BUMP_TYPE="patch"
BUILD_NUMBER="unknown"

show_help() {
  sed -n '/^#/p' "$0" | sed 's/^# *//' | sed '/^$/d'
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --skip-git)
      SKIP_GIT=true
      shift
      ;;
    --release-notes)
      [ -z "${2:-}" ] && { log_error "--release-notes requires a file"; exit 1; }
      RELEASE_NOTES_FILE="$2"
      shift 2
      ;;
    --version)
      [ -z "${2:-}" ] && { log_error "--version requires a value"; exit 1; }
      OVERRIDE_VERSION="$2"
      shift 2
      ;;
    --bump)
      [ -z "${2:-}" ] && { log_error "--bump requires patch, minor, or major"; exit 1; }
      BUMP_TYPE="$2"
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
echo "=== Snapback Build & Release Started: $(date) ===" > "$LOG_FILE"

log_info "Starting Snapback build and release pipeline..."
log_info "Project directory: $PROJECT_DIR"
log_info "Xcode project: $XCODE_PROJECT_PATH"

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

for tool in xcodebuild agvtool dmgbuild xcrun ditto; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_error "Required tool not found: $tool"
    exit 1
  fi
done

log_success "All required tools available"

# ============================================================================
# VERSION DETECTION
# ============================================================================

log_info "Detecting version..."

if [ -n "$OVERRIDE_VERSION" ]; then
  VERSION="$OVERRIDE_VERSION"
  log_info "Using override version: $VERSION"
else
  PLIST_PATH="$XCODE_PROJECT_PATH/$INFO_PLIST"
  
  if ! file_exists "$PLIST_PATH"; then
    log_error "Info.plist not found at: $PLIST_PATH"
    exit 1
  fi
  
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST_PATH" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST_PATH")
  
  if [ -z "$VERSION" ]; then
    log_error "Could not extract version from Info.plist"
    exit 1
  fi
fi

log_success "Version detected: $VERSION"

# ============================================================================
# VERSION BUMP PHASE
# ============================================================================

log_info "Bumping version in Xcode build settings..."

if ! $DRY_RUN && [ -z "$OVERRIDE_VERSION" ]; then
  cd "$XCODE_PROJECT_PATH"

  CURRENT_BUILD=$(agvtool what-version -terse | head -1 | tr -d '[:space:]')

  if ! [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    log_error "Could not parse build number from agvtool: '$CURRENT_BUILD'"
    exit 1
  fi

  BUILD_NUMBER=$((CURRENT_BUILD + 1))

  agvtool new-version "$BUILD_NUMBER"

  CURRENT_MARKETING=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$XCODE_PROJECT_PATH/$INFO_PLIST" | tr -d '[:space:]')

  IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_MARKETING"

  MAJOR=${MAJOR:-0}
  MINOR=${MINOR:-0}
  PATCH=${PATCH:-0}

  case "$BUMP_TYPE" in
    patch)
      PATCH=$((PATCH + 1))
      ;;
    minor)
      MINOR=$((MINOR + 1))
      PATCH=0
      ;;
    major)
      MAJOR=$((MAJOR + 1))
      MINOR=0
      PATCH=0
      ;;
    *)
      log_error "Invalid bump type: $BUMP_TYPE"
      exit 1
      ;;
  esac

  VERSION="$MAJOR.$MINOR.$PATCH"

  agvtool new-marketing-version "$VERSION" 2>> "$LOG_FILE"

  # agvtool fails to update MARKETING_VERSION in pbxproj when GENERATE_INFOPLIST_FILE=YES,
  # so patch it directly with sed.
  sed -i '' "s/MARKETING_VERSION = 0\.[0-9]*\.[0-9]*/MARKETING_VERSION = $VERSION/g" \
    "$XCODE_PROJECT_PATH/Snapback.xcodeproj/project.pbxproj"

  # Keep source plist in sync too.
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$XCODE_PROJECT_PATH/$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$XCODE_PROJECT_PATH/$INFO_PLIST"
  log_info "Confirmed version after bump: $VERSION (build $BUILD_NUMBER)"

  log_success "Version bumped to $VERSION (build $BUILD_NUMBER)"

  cd "$PROJECT_DIR"

elif [ -n "$OVERRIDE_VERSION" ]; then
  VERSION="$OVERRIDE_VERSION"
  BUILD_NUMBER=$(agvtool what-version -terse | head -1 | tr -d '[:space:]' 2>/dev/null || echo "unknown")
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
    -project "$XCODE_PROJECT_PATH/Snapback.xcodeproj" \
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
  cat > "$EXPORT_OPTIONS_PLIST" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application: Ricardo Ramirez (6WA4QS23C4)</string>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
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
# NOTARIZATION PHASE
# ============================================================================

log_info "Notarizing app bundle..."

if ! $DRY_RUN; then

  APP_PATH="$EXPORT_PATH/Snapback.app"

  # Xcode's GENERATE_INFOPLIST_FILE only processes Apple-defined keys.
  # Sparkle's SU* keys are silently dropped, so inject them before codesigning.
  APP_PLIST="$APP_PATH/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string 1btXa+HGNXBso5RoX1qjX2lltfdpXbryUma3dw6+/O4=" "$APP_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey 1btXa+HGNXBso5RoX1qjX2lltfdpXbryUma3dw6+/O4=" "$APP_PLIST"
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://snapbackapp.com/releases/appcast.xml" "$APP_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL https://snapbackapp.com/releases/appcast.xml" "$APP_PLIST"
  /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$APP_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks true" "$APP_PLIST"
  log_info "Injected Sparkle keys into Info.plist"

  codesign --force --deep --sign "$CODE_SIGN_IDENTITY" \
    --timestamp --options runtime \
    "$APP_PATH/Contents/Frameworks/Sparkle.framework" \
    >> "$LOG_FILE" 2>&1

  codesign --force --sign "$CODE_SIGN_IDENTITY" \
    --timestamp --options runtime \
    "$APP_PATH" \
    >> "$LOG_FILE" 2>&1

  NOTARIZE_ZIP="$BUILD_DIR/Snapback-notarize.zip"

  ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

  if [ -n "$NOTARY_PROFILE" ]; then
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

# ============================================================================
# PACKAGING PHASE
# ============================================================================

log_info "Creating DMG release..."

RELEASE_NAME="Snapback-$VERSION"
RELEASE_DMG="$BUILD_DIR/$RELEASE_NAME.dmg"

if $DRY_RUN; then
  log_warn "[DRY RUN] Would create DMG"
else

  dmgbuild \
    -s "$SCRIPT_DIR/dmg-settings.py" \
    -D "app=$EXPORT_PATH/Snapback.app" \
    -D "background=$SCRIPT_DIR/assets/dmg-background.png" \
    "Snapback" \
    "$RELEASE_DMG" \
    >> "$LOG_FILE" 2>&1

  log_success "Release DMG created: $RELEASE_DMG"

fi

# ============================================================================
# CHANGELOG PHASE
# ============================================================================

if [ -z "$RELEASE_NOTES_FILE" ]; then
  log_info "Auto-generating release notes from git history..."
  CHANGELOG_SCRIPT="$SCRIPT_DIR/generate-changelog.sh"
  AUTO_NOTES_FILE="$BUILD_DIR/Snapback-$VERSION-notes.html"

  if [ -f "$CHANGELOG_SCRIPT" ]; then
    if $DRY_RUN; then
      log_warn "[DRY RUN] Would generate release notes: $AUTO_NOTES_FILE"
    elif bash "$CHANGELOG_SCRIPT" --version "$VERSION" --output "$AUTO_NOTES_FILE" 2>/dev/null; then
      RELEASE_NOTES_FILE="$AUTO_NOTES_FILE"
      log_success "Release notes generated: $AUTO_NOTES_FILE"
    else
      log_warn "Could not auto-generate release notes (continuing without)"
    fi
  fi
fi

# ============================================================================
# RELEASE PHASE
# ============================================================================

log_info "Adding DMG release to repository..."

RELEASE_SCRIPT="$SCRIPT_DIR/release.sh"

RELEASE_ARGS=("$RELEASE_DMG")

if [ -n "$RELEASE_NOTES_FILE" ]; then
  RELEASE_ARGS+=("--release-notes" "$RELEASE_NOTES_FILE")
fi

if $DRY_RUN; then
  log_warn "[DRY RUN] Would execute release script"
else
  bash "$RELEASE_SCRIPT" "${RELEASE_ARGS[@]}"
fi

# ============================================================================
# GIT PHASE
# ============================================================================

if ! $SKIP_GIT; then

  cd "$PROJECT_DIR"

  if git rev-parse --git-dir > /dev/null 2>&1; then

    git add releases/*.dmg 2>/dev/null || true
    git add releases/*.delta 2>/dev/null || true
    git add releases/*.html 2>/dev/null || true
    git add releases/appcast.xml 2>/dev/null || true
    git add -u releases/ 2>/dev/null || true

    if ! git diff --quiet --cached; then

      git commit -m "chore(release): Snapback v$VERSION

 - Build: $BUILD_NUMBER
 - App archive: $RELEASE_NAME.dmg
 - Built: $(date +'%Y-%m-%d %H:%M:%S')"

      log_success "Changes committed"

    fi

    # Tag the app repo so future changelogs have an accurate commit range
    if git -C "$XCODE_PROJECT_PATH" rev-parse --git-dir > /dev/null 2>&1; then
      if git -C "$XCODE_PROJECT_PATH" rev-parse "v$VERSION" > /dev/null 2>&1; then
        log_warn "Tag v$VERSION already exists in app repo, skipping"
      else
        git -C "$XCODE_PROJECT_PATH" tag -a "v$VERSION" -m "Release $VERSION (build $BUILD_NUMBER)"
        git -C "$XCODE_PROJECT_PATH" push origin "v$VERSION" >> "$LOG_FILE" 2>&1
        log_success "Tagged app repo: v$VERSION"
      fi
    fi

  fi
fi

# ============================================================================
# SUMMARY
# ============================================================================

log_success "Build and release pipeline completed!"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    RELEASE SUMMARY                        ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║ Version:        $VERSION"
echo "║ Build:          $BUILD_NUMBER"
echo "║ Release DMG:    $RELEASE_DMG"
echo "║ Website URL:    $WEBSITE_URL"
echo "║ Download URL:   $DOWNLOAD_URL_PREFIX/$RELEASE_NAME.dmg"
echo "║ Build Log:      $LOG_FILE"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

exit 0