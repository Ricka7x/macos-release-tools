#!/bin/bash
#
# build-and-release.sh - Complete automated build and release pipeline
#
# This script handles the entire process from source code to production release:
# 1. Validates environment and configuration
# 2. Runs the test suite (if TEST_COMMAND is set), aborting before touching anything on failure
# 3. Determines next version from git history via git-cliff (feat->minor, fix->patch)
# 4. Bumps version in Info.plist and project.pbxproj
# 5. Builds and archives the Xcode project
# 6. Exports the app bundle, verifying its embedded version matches
# 7. Notarizes and staples the app
# 8. Creates a release DMG archive
# 9. Generates HTML release notes via git-cliff
# 10. Generates and verifies the Sparkle appcast.xml
# 11. Syncs release files into EXTERNAL_SITE_REPO, if configured (e.g. a dedicated
#     marketing site with its own independent deploy workflow)
# 12. Updates the download link in CATALOG_FILE for CATALOG_APP_SLUG, if configured
# 13. Commits version bump + release files, tags the app repo, and pushes everything
#     (app repo, release repo, external site repo) now that every prior step passed
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
# Optional config.sh variables added by this pipeline revision:
#   TEST_COMMAND        Shell command to run before anything else; non-zero aborts the release
#   EXTERNAL_SITE_REPO  Path to another repo whose own releases/ folder should get a copy
#   CATALOG_FILE        Path to 66-studio's apps.ts (or similar) to update a download link in
#   CATALOG_APP_SLUG    The app's slug within CATALOG_FILE; required together with CATALOG_FILE
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

# ============================================================================
# TEST PHASE
# ============================================================================
#
# Runs before anything else touches a file, so a failing suite leaves the repo
# completely untouched. Optional per-app: set TEST_COMMAND in config.sh to a
# shell command that exits non-zero on failure (e.g. `xcodebuild test -scheme
# Foo -destination 'platform=macOS'` for an Xcode test target, or `cd FooKit
# && swift test` for an SPM package living alongside the app). Runs with its
# working directory set to XCODE_PROJECT_PATH.

if [ -n "${TEST_COMMAND:-}" ]; then
  log_info "Running test suite..."
  if $DRY_RUN; then
    log_warn "[DRY RUN] Would run: $TEST_COMMAND"
  else
    if ! (cd "$XCODE_PROJECT_PATH" && eval "$TEST_COMMAND") >> "$LOG_FILE" 2>&1; then
      log_error "Test suite failed, refusing to release. Check log: $LOG_FILE"
      exit 1
    fi
    log_success "Test suite passed"
  fi
else
  log_warn "TEST_COMMAND not set in config.sh, skipping the pre-release test gate"
fi

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
  log_info "Using override version: $VERSION"
else
  log_info "Determining next version from git history..."

  LAST_TAG=$(git -C "$XCODE_PROJECT_PATH" tag --sort=-version:refname 2>/dev/null | head -1)

  if [ -z "$LAST_TAG" ]; then
    # No tags yet: read current version from Info.plist and do an initial minor bump.
    # A brand-new app's custom Info.plist (the GENERATE_INFOPLIST_FILE=YES merge source)
    # may not carry CFBundleShortVersionString at all yet, PlistBuddy's Print then fails
    # with a non-zero exit and empty output. Treat that as 0.0.0 so the very first
    # release of a new app comes out as 0.1.0, not a hard failure.
    # `set -o pipefail` means a failing PlistBuddy still fails this whole pipeline
    # even with 2>/dev/null and the empty string swallowed into tr's output.
    # Run it unpiped first so a missing key doesn't trip `set -e`.
    CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST_PATH" 2>/dev/null) || CURRENT_VERSION=""
    CURRENT_VERSION=$(echo "$CURRENT_VERSION" | tr -d '[:space:]')
    CURRENT_VERSION="${CURRENT_VERSION:-0.0.0}"
    IFS='.' read -r V_MAJOR V_MINOR V_PATCH <<< "$CURRENT_VERSION"
    V_MAJOR="${V_MAJOR:-0}"
    V_MINOR="${V_MINOR:-0}"
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
fi

# The build number always increments from whatever's currently on disk,
# whether VERSION came from --version or from git-cliff above: Sparkle
# compares CFBundleVersion, not CFBundleShortVersionString, to decide
# whether an update is newer, and refuses to generate an appcast with two
# archives sharing the same build number (seen first-hand: using --version
# twice in a row with no intervening normal release left CFBundleVersion
# unchanged on disk, and generate_appcast correctly rejected the resulting
# duplicate "0" between the two DMGs).
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST_PATH" 2>/dev/null || echo "0")
if [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
  BUILD_NUMBER=$((CURRENT_BUILD + 1))
else
  BUILD_NUMBER="$CURRENT_BUILD"
fi

log_success "Version: $VERSION (build $BUILD_NUMBER)"

# ============================================================================
# VERSION BUMP PHASE
# ============================================================================

log_info "Writing version to app repo..."

if $DRY_RUN; then
  log_warn "[DRY RUN] Would bump Info.plist and project.pbxproj to $VERSION (build $BUILD_NUMBER)"
else
  # Add-or-Set: a brand-new app's custom Info.plist (GENERATE_INFOPLIST_FILE=YES merge
  # source) may not carry these keys yet, and PlistBuddy's Set fails outright if the key
  # doesn't already exist (unlike Xcode, which creates it). Add first, falling back to Set
  # when the key is already there, same pattern used for Sparkle's SU* keys below.
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$PLIST_PATH" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST_PATH"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$PLIST_PATH" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST_PATH"

  # agvtool fails to update MARKETING_VERSION in pbxproj when GENERATE_INFOPLIST_FILE=YES,
  # so patch it directly with sed.
  sed -i '' "s/MARKETING_VERSION = [0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/MARKETING_VERSION = $VERSION/g" "$PBXPROJ"
  sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9][0-9]*/CURRENT_PROJECT_VERSION = $BUILD_NUMBER/g" "$PBXPROJ"

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
  # Manual-signing distribution requires an explicit provisioning profile when the app
  # has entitlements beyond plain sandboxing/network (e.g. iCloud). Xcode's automatic
  # signing can't generate those for Developer ID. Set BUNDLE_IDENTIFIER and
  # PROVISIONING_PROFILE_UUID in config.sh for apps that need one (Boomark does for its
  # CloudKit container; Snapback doesn't and leaves both unset).
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
    <string>$CODE_SIGN_IDENTITY</string>
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

  # Catches a stale archive or a version-bump that silently didn't take,
  # before spending time on notarization for a build that would ship the
  # wrong version.
  EXPORTED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$EXPORT_PATH/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || echo "")
  if [ "$EXPORTED_VERSION" != "$VERSION" ]; then
    log_error "Exported app reports version '$EXPORTED_VERSION', expected '$VERSION'. Refusing to release a mismatched build."
    exit 1
  fi
  log_success "Exported app version verified: $VERSION"
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
  if [ -z "${SPARKLE_ED_PUBLIC_KEY:-}" ]; then
    log_error "SPARKLE_ED_PUBLIC_KEY is not set in config.sh. Refusing to build with no (or a borrowed) Sparkle public key."
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_ED_PUBLIC_KEY" "$APP_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_ED_PUBLIC_KEY" "$APP_PLIST"
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $DOWNLOAD_URL_PREFIX/appcast.xml" "$APP_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL $DOWNLOAD_URL_PREFIX/appcast.xml" "$APP_PLIST"
  /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$APP_PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks true" "$APP_PLIST"
  log_info "Injected Sparkle keys into Info.plist"

  codesign --force --deep --sign "$CODE_SIGN_IDENTITY" \
    --timestamp --options runtime \
    "$APP_PATH/Contents/Frameworks/Sparkle.framework" \
    >> "$LOG_FILE" 2>&1

  # Re-signing to pick up the Sparkle Info.plist edits above would otherwise silently
  # strip every entitlement baked in by xcodebuild's export (codesign does not carry
  # entitlements forward on a plain re-sign): apps with hard-enforced entitlements like
  # iCloud/CloudKit then crash at launch with no error, since Gatekeeper/notarization
  # don't catch a *missing* entitlement, only a malformed one. Extract and re-apply them
  # explicitly instead of trusting --preserve-metadata, which xcodebuild's own export step
  # uses internally but a bare `codesign --force` does not.
  ENTITLEMENTS_PLIST="$BUILD_DIR/ReExportEntitlements.plist"
  codesign -d --entitlements "$ENTITLEMENTS_PLIST" --xml "$APP_PATH" >> "$LOG_FILE" 2>&1
  if [ -s "$ENTITLEMENTS_PLIST" ]; then
    codesign --force --sign "$CODE_SIGN_IDENTITY" \
      --timestamp --options runtime \
      --entitlements "$ENTITLEMENTS_PLIST" \
      "$APP_PATH" \
      >> "$LOG_FILE" 2>&1
  else
    log_warn "No entitlements found on exported app; re-signing without --entitlements (this is only correct for an app with none)."
    codesign --force --sign "$CODE_SIGN_IDENTITY" \
      --timestamp --options runtime \
      "$APP_PATH" \
      >> "$LOG_FILE" 2>&1
  fi

  # Verify the re-sign didn't drop anything: fail loudly instead of shipping a build
  # that will crash silently at launch for entitlement-gated features.
  POST_RESIGN_ENTITLEMENTS=$(codesign -d --entitlements - "$APP_PATH" 2>/dev/null)
  if [ -s "$ENTITLEMENTS_PLIST" ] && [ -z "$POST_RESIGN_ENTITLEMENTS" ]; then
    log_error "Entitlements were present before the final codesign but are missing after it. Refusing to ship a build that would crash at launch."
    exit 1
  fi

  NOTARIZE_ZIP="$BUILD_DIR/$APP_NAME-notarize.zip"

  ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

  if [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait >> "$LOG_FILE" 2>&1
  else
    # NOTARY_PROFILE empty falls through to direct Apple ID auth, which needs all
    # three of these. Checked explicitly, since the bare `set -u` failure on one of
    # them (seen first-hand on Snapback's config, which had NOTARY_PROFILE default
    # to empty) just says "unbound variable" with no hint of what's actually missing
    # or how to fix it.
    if [ -z "${APPLE_ID:-}" ] || [ -z "${TEAM_ID:-}" ] || [ -z "${APP_PASSWORD:-}" ]; then
      log_error "No notarization credentials configured. Set NOTARY_PROFILE in config.sh (preferred, via xcrun notarytool store-credentials), or all of APPLE_ID, TEAM_ID, and APP_PASSWORD as environment variables."
      exit 1
    fi
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
# CHANGELOG.md PHASE
# ============================================================================
#
# Regenerates CHANGELOG.md in the app repo from the full tag history (not
# appended incrementally). Full regeneration is git-cliff's recommended
# pattern: it stays correct even if tags or commits are amended later, and
# running it twice is a no-op. Separate from the per-release HTML notes
# above (cliff.toml), which feed Sparkle's appcast; this is a human-readable
# changelog meant to live in the app repo's git history, e.g. for GitHub's
# release notes page or anyone browsing the repo.

CHANGELOG_PATH="$XCODE_PROJECT_PATH/CHANGELOG.md"

log_info "Updating CHANGELOG.md..."

if $DRY_RUN; then
  log_warn "[DRY RUN] Would regenerate $CHANGELOG_PATH"
elif git-cliff \
    --repository "$XCODE_PROJECT_PATH" \
    --config "$SCRIPT_DIR/cliff-changelog.toml" \
    --tag "v$VERSION" \
    --output "$CHANGELOG_PATH" >> "$LOG_FILE" 2>&1; then
  log_success "CHANGELOG.md updated: $CHANGELOG_PATH"
else
  log_warn "Could not update CHANGELOG.md (continuing without)"
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

  log_info "Verifying generated appcast..."
  APPCAST_PATH="$RELEASES_DIR/appcast.xml"
  if [ ! -f "$APPCAST_PATH" ]; then
    log_error "appcast.xml not found at $APPCAST_PATH after release.sh ran."
    exit 1
  fi
  if ! grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST_PATH"; then
    log_error "appcast.xml has no entry for version $VERSION. Refusing to publish a feed that doesn't match this release."
    exit 1
  fi
  log_success "appcast.xml verified for version $VERSION"
fi

# ============================================================================
# EXTERNAL SITE SYNC PHASE
# ============================================================================
#
# Optional per-app: set EXTERNAL_SITE_REPO in config.sh to another repo whose
# own releases/ folder should also receive this release's files. Snapback's
# dedicated site repo has its own independent deploy workflow reading from
# its own local releases/ folder; this step only ever feeds that existing,
# untouched workflow data, never its code. Every copy is checksum-verified
# against its source before anything commits it.

if [ -n "${EXTERNAL_SITE_REPO:-}" ] && ! $SKIP_GIT && ! $DRY_RUN; then
  log_info "Syncing release files to external site repo: $EXTERNAL_SITE_REPO"

  if [ ! -d "$EXTERNAL_SITE_REPO" ]; then
    log_error "EXTERNAL_SITE_REPO is set but does not exist: $EXTERNAL_SITE_REPO"
    exit 1
  fi

  EXTERNAL_RELEASES_DIR="$EXTERNAL_SITE_REPO/releases"
  mkdir -p "$EXTERNAL_RELEASES_DIR"

  SYNC_FILES=()
  for f in "$RELEASES_DIR/$RELEASE_NAME".*; do
    [ -f "$f" ] && SYNC_FILES+=("$f")
  done
  [ -f "$RELEASES_DIR/appcast.xml" ] && SYNC_FILES+=("$RELEASES_DIR/appcast.xml")

  for f in "${SYNC_FILES[@]}"; do
    cp "$f" "$EXTERNAL_RELEASES_DIR/"
  done

  for f in "${SYNC_FILES[@]}"; do
    SRC_SUM=$(shasum -a 256 "$f" | awk '{print $1}')
    DEST_SUM=$(shasum -a 256 "$EXTERNAL_RELEASES_DIR/$(basename "$f")" | awk '{print $1}')
    if [ "$SRC_SUM" != "$DEST_SUM" ]; then
      log_error "Checksum mismatch after copying $(basename "$f") to $EXTERNAL_SITE_REPO. Refusing to commit a corrupted file."
      exit 1
    fi
  done

  if git -C "$EXTERNAL_SITE_REPO" rev-parse --git-dir > /dev/null 2>&1; then
    git -C "$EXTERNAL_SITE_REPO" add releases/ 2>/dev/null || true
    if ! git -C "$EXTERNAL_SITE_REPO" diff --quiet --cached; then
      git -C "$EXTERNAL_SITE_REPO" commit -m "chore(release): $APP_NAME v$VERSION"
      log_success "Committed release files in $EXTERNAL_SITE_REPO"
    else
      log_warn "Nothing new to commit in $EXTERNAL_SITE_REPO"
    fi
  fi
fi

# ============================================================================
# CATALOG UPDATE PHASE
# ============================================================================
#
# Optional per-app: set CATALOG_FILE (path to 66-studio's apps.ts) and
# CATALOG_APP_SLUG in config.sh to update that app's download link. The
# actual edit happens in update-catalog-link.py, which scopes itself to the
# block between this app's `slug:` line and the next one so it can never
# touch a different app's entry, and only ever changes that one line.

if [ -n "${CATALOG_FILE:-}" ] && ! $SKIP_GIT && ! $DRY_RUN; then
  log_info "Updating catalog download link for '${CATALOG_APP_SLUG:-}'..."

  if [ -z "${CATALOG_APP_SLUG:-}" ]; then
    log_error "CATALOG_FILE is set but CATALOG_APP_SLUG is not. Both are required together."
    exit 1
  fi
  if [ ! -f "$CATALOG_FILE" ]; then
    log_error "CATALOG_FILE not found: $CATALOG_FILE"
    exit 1
  fi

  NEW_DOWNLOAD_URL="$DOWNLOAD_URL_PREFIX/$RELEASE_NAME.dmg"
  CATALOG_REPO="$(cd "$(dirname "$CATALOG_FILE")" && git rev-parse --show-toplevel 2>/dev/null)"

  if ! python3 "$SCRIPT_DIR/update-catalog-link.py" "$CATALOG_FILE" "$CATALOG_APP_SLUG" "$NEW_DOWNLOAD_URL" >> "$LOG_FILE" 2>&1; then
    log_error "Failed to update catalog download link. Check log: $LOG_FILE"
    exit 1
  fi

  if [ -n "$CATALOG_REPO" ] && git -C "$CATALOG_REPO" rev-parse --git-dir > /dev/null 2>&1; then
    git -C "$CATALOG_REPO" add "$CATALOG_FILE"
    if ! git -C "$CATALOG_REPO" diff --quiet --cached -- "$CATALOG_FILE"; then
      git -C "$CATALOG_REPO" commit -m "chore: update $CATALOG_APP_SLUG download link to v$VERSION"
      log_success "Catalog download link updated and committed"
    else
      log_warn "Catalog download link already up to date"
    fi
  fi
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
      git -C "$XCODE_PROJECT_PATH" add "$PLIST_PATH" "$PBXPROJ" "$CHANGELOG_PATH" 2>/dev/null || true
      if ! git -C "$XCODE_PROJECT_PATH" diff --quiet --cached; then
        git -C "$XCODE_PROJECT_PATH" commit -m "chore: bump version to $VERSION (build $BUILD_NUMBER)"
        log_success "Version bump committed in app repo"
      fi
    fi

    # Tag the app repo so future changelogs have an accurate commit range. A tag that
    # already exists locally (e.g. left behind by a run whose later push failed, such
    # as a transient GitHub outage) must still be pushed here: it existing locally is
    # not evidence it ever reached the remote, and skipping the push in that case
    # silently left a release's tag missing from GitHub even though this script
    # reported success (caught first-hand after a GitHub 500 on an earlier run).
    if git -C "$XCODE_PROJECT_PATH" rev-parse --git-dir > /dev/null 2>&1; then
      if git -C "$XCODE_PROJECT_PATH" rev-parse "v$VERSION" > /dev/null 2>&1; then
        log_warn "Tag v$VERSION already exists locally, pushing it in case an earlier run never got it to origin"
      else
        git -C "$XCODE_PROJECT_PATH" tag -a "v$VERSION" -m "Release $VERSION (build $BUILD_NUMBER)"
      fi
      git -C "$XCODE_PROJECT_PATH" push origin "v$VERSION" >> "$LOG_FILE" 2>&1
      log_success "Tagged app repo: v$VERSION"
    fi

    # Push everything else only now that every guard above has already
    # passed: build, tests, the exported-version check, notarization, the
    # appcast check, and (if configured) the external site sync and catalog
    # update. Any failure in those would already have exited this script
    # non-zero before reaching here, so a push past this point only ever
    # ships a release that's been verified end to end.
    if git -C "$XCODE_PROJECT_PATH" rev-parse --git-dir > /dev/null 2>&1; then
      git -C "$XCODE_PROJECT_PATH" push origin HEAD >> "$LOG_FILE" 2>&1
      log_success "Pushed $APP_NAME app repo"
    fi

    if git -C "$PROJECT_DIR" rev-parse --git-dir > /dev/null 2>&1; then
      git -C "$PROJECT_DIR" push origin HEAD >> "$LOG_FILE" 2>&1
      log_success "Pushed release repo"
    fi

    if [ -n "${EXTERNAL_SITE_REPO:-}" ] && git -C "$EXTERNAL_SITE_REPO" rev-parse --git-dir > /dev/null 2>&1; then
      git -C "$EXTERNAL_SITE_REPO" push origin HEAD >> "$LOG_FILE" 2>&1
      log_success "Pushed external site repo"
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