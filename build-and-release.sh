#!/bin/bash
#
# build-and-release.sh - Complete automated build and release pipeline
#
# This script handles the entire process from source code to production release:
# 1. Validates environment and configuration
# 2. Determines next version from git history via git-cliff (feat->minor, fix->patch)
# 3. Bumps version in Info.plist and project.pbxproj
# 4. Builds and archives the Xcode project
# 5. Exports the app bundle
# 6. Notarizes and staples the app
# 7. Creates a release DMG archive
# 8. Generates HTML release notes via git-cliff
# 9. Generates the Sparkle appcast.xml
# 10. Commits version bump to app repo, commits release to web repo, tags app repo
#
# Usage:
#   ./scripts/build-and-release.sh [options]
#
# Options:
#   --dry-run              Show what would be done without making changes
#   --skip-git             Don't commit or push to git
#   --release-notes FILE   Override auto-generated release notes with a custom file
#   --version VERSION      Override version determined by git-cliff
#   --verbose              Enable verbose output
#   --help                 Show this help message
#

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( dirname "$SCRIPT_DIR" )"

# Source project-specific configuration (lives in the release repo, not in this script dir)
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
SKIP_GIT=false
RELEASE_NOTES_FILE=""
OVERRIDE_VERSION=""
VERBOSE=false
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
echo "=== $APP_NAME Build & Release Started: $(date) ===" > "$LOG_FILE"

log_info "Starting $APP_NAME build and release pipeline..."
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

for tool in xcodebuild create-dmg xcrun ditto git-cliff; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log_error "Required tool not found: $tool"
    exit 1
  fi
done

log_success "All required tools available"

# create-dmg (npm) ships a native addon (macos-alias) built against a specific
# Node ABI. A `brew upgrade node` or version-manager switch can silently break
# it; detect that and self-heal instead of failing mid-release.
log_info "Verifying create-dmg native module compatibility..."
CREATE_DMG_CHECK=$(create-dmg --help 2>&1) || true
if echo "$CREATE_DMG_CHECK" | grep -q "NODE_MODULE_VERSION"; then
  log_warn "create-dmg's native module doesn't match the active Node ($(node -v 2>/dev/null)). Rebuilding..."
  if ! npm rebuild -g create-dmg >> "$LOG_FILE" 2>&1; then
    log_error "Failed to rebuild create-dmg. Run manually: npm rebuild -g create-dmg"
    exit 1
  fi
  CREATE_DMG_CHECK=$(create-dmg --help 2>&1) || true
  if echo "$CREATE_DMG_CHECK" | grep -q "NODE_MODULE_VERSION"; then
    log_error "create-dmg still broken after rebuild. Run manually: npm rebuild -g create-dmg"
    exit 1
  fi
  log_success "create-dmg rebuilt and verified against active Node"
else
  log_success "create-dmg native module OK"
fi

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
else
  log_info "Determining next version from git history..."

  LAST_TAG=$(git -C "$XCODE_PROJECT_PATH" tag --sort=-version:refname 2>/dev/null | head -1)

  if [ -z "$LAST_TAG" ]; then
    # No tags yet: read current version from Info.plist and do an initial minor bump
    CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST_PATH" | tr -d '[:space:]')
    IFS='.' read -r V_MAJOR V_MINOR V_PATCH <<< "$CURRENT_VERSION"
    VERSION="$V_MAJOR.$((V_MINOR + 1)).0"
    log_info "No tags found, using $CURRENT_VERSION -> $VERSION as first release"
  else
    VERSION=$(git-cliff \
                --repository "$XCODE_PROJECT_PATH" \
                --config "$SCRIPT_DIR/cliff.toml" \
                --bumped-version --unreleased 2>/dev/null | tr -d '[:space:]')
    VERSION="${VERSION#v}"  # strip leading 'v' if present

    if [ -z "$VERSION" ]; then
      log_error "git-cliff could not determine next version. Ensure there are conventional commits since the last tag."
      exit 1
    fi
  fi

  CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST_PATH" 2>/dev/null || echo "0")
  if [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    BUILD_NUMBER=$((CURRENT_BUILD + 1))
  else
    BUILD_NUMBER="$CURRENT_BUILD"
  fi
fi

log_success "Version: $VERSION (build $BUILD_NUMBER)"

# ============================================================================
# VERSION BUMP PHASE
# ============================================================================

log_info "Writing version to app repo..."

if $DRY_RUN; then
  log_warn "[DRY RUN] Would bump Info.plist and project.pbxproj to $VERSION (build $BUILD_NUMBER)"
else
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST_PATH"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST_PATH"

  # agvtool fails to update MARKETING_VERSION in pbxproj when GENERATE_INFOPLIST_FILE=YES,
  # so patch it directly with sed.
  sed -i '' "s/MARKETING_VERSION = [0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/MARKETING_VERSION = $VERSION/g" "$PBXPROJ"
  sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9][0-9]*/CURRENT_PROJECT_VERSION = $BUILD_NUMBER/g" "$PBXPROJ"

  # Update web constants with the new version
  WEB_CONSTANTS_FILE="$PROJECT_DIR/web/src/lib/constants.ts"
  if [ -f "$WEB_CONSTANTS_FILE" ]; then
    sed -i '' "s/export const LATEST_VERSION = \"[^\"]*\"/export const LATEST_VERSION = \"$VERSION\"/" "$WEB_CONSTANTS_FILE"
  fi

  log_success "Version bumped to $VERSION (build $BUILD_NUMBER)"
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
    <string>$CODE_SIGN_IDENTITY</string>
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

  APP_PATH="$EXPORT_PATH/$APP_NAME.app"

  # Xcode's GENERATE_INFOPLIST_FILE only processes Apple-defined keys.
  # Sparkle's SU* keys are silently dropped, so inject them before codesigning.
  APP_PLIST="$APP_PATH/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string 1btXa+HGNXBso5RoX1qjX2lltfdpXbryUma3dw6+/O4=" "$APP_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey 1btXa+HGNXBso5RoX1qjX2lltfdpXbryUma3dw6+/O4=" "$APP_PLIST"
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $DOWNLOAD_URL_PREFIX/appcast.xml" "$APP_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL $DOWNLOAD_URL_PREFIX/appcast.xml" "$APP_PLIST"
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

  NOTARIZE_ZIP="$BUILD_DIR/$APP_NAME-notarize.zip"

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

RELEASE_NAME="$APP_NAME-$VERSION"
RELEASE_DMG="$BUILD_DIR/$RELEASE_NAME.dmg"

if $DRY_RUN; then
  log_warn "[DRY RUN] Would create DMG"
else

  create-dmg \
    --overwrite \
    "$EXPORT_PATH/$APP_NAME.app" \
    "$BUILD_DIR" \
    >> "$LOG_FILE" 2>&1

  # create-dmg names the output "<AppName> <Version>.dmg"; rename to our convention
  mv "$BUILD_DIR/$APP_NAME $VERSION.dmg" "$RELEASE_DMG"

  log_success "Release DMG created: $RELEASE_DMG"

fi

# ============================================================================
# CHANGELOG PHASE
# ============================================================================

if [ -z "$RELEASE_NOTES_FILE" ]; then
  log_info "Generating release notes with git-cliff..."
  AUTO_NOTES_FILE="$BUILD_DIR/$RELEASE_NAME-notes.html"

  if $DRY_RUN; then
    log_info "[DRY RUN] Previewing release notes (git-cliff is read-only)..."
    git-cliff \
      --repository "$XCODE_PROJECT_PATH" \
      --config "$SCRIPT_DIR/cliff.toml" \
      --unreleased \
      --tag "v$VERSION" 2>> "$LOG_FILE" || true
  elif git-cliff \
      --repository "$XCODE_PROJECT_PATH" \
      --config "$SCRIPT_DIR/cliff.toml" \
      --unreleased \
      --tag "v$VERSION" \
      --output "$AUTO_NOTES_FILE" 2>> "$LOG_FILE"; then
    RELEASE_NOTES_FILE="$AUTO_NOTES_FILE"
    log_success "Release notes generated: $AUTO_NOTES_FILE"
  else
    log_warn "Could not generate release notes (continuing without)"
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

if ! $SKIP_GIT && ! $DRY_RUN; then

  cd "$PROJECT_DIR"

  if git rev-parse --git-dir > /dev/null 2>&1; then

    git add releases/ 2>/dev/null || true
    git add -u releases/ 2>/dev/null || true

    if ! git diff --quiet --cached; then

      git commit -m "chore(release): $APP_NAME v$VERSION

 - Build: $BUILD_NUMBER
 - App archive: $RELEASE_NAME.dmg
 - Built: $(date +'%Y-%m-%d %H:%M:%S')"

      log_success "Changes committed"

    fi

    # Commit version bump in app repo
    if git -C "$XCODE_PROJECT_PATH" rev-parse --git-dir > /dev/null 2>&1; then
      git -C "$XCODE_PROJECT_PATH" add "$PLIST_PATH" "$PBXPROJ" 2>/dev/null || true
      if ! git -C "$XCODE_PROJECT_PATH" diff --quiet --cached; then
        git -C "$XCODE_PROJECT_PATH" commit -m "chore: bump version to $VERSION (build $BUILD_NUMBER)"
        log_success "Version bump committed in app repo"
      fi
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