#!/bin/bash
#
# init-release-repo.sh - Scaffold a new app's release repo using this pipeline
#
# Run this from wherever you keep your projects (e.g. ~/Projects). It creates
# a new release repo, adds this repo as the `scripts/` submodule, generates
# config.sh from your answers, and makes the first commit.
#
# Usage:
#   ./init-release-repo.sh <release-repo-name>
#
# Example:
#   cd ~/Projects
#   /path/to/macos-release-tools/init-release-repo.sh myapp-web
#
# After this finishes:
#   1. Review config.sh in the new repo and fill in anything left blank
#   2. Make sure Sparkle's SUFeedURL / SUPublicEDKey are set in your app's Info.plist
#   3. Store a notarization credential:
#        xcrun notarytool store-credentials "MyNotaryProfile" \
#          --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
#   4. If your app already has releases, tag its current version so git-cliff
#      has a baseline: git -C /path/to/YourApp tag -a v1.0.0 -m "Release 1.0.0"
#   5. Create the GitHub repo and push: gh repo create <org>/<name> --public --source=. --push
#   6. Ship: cd <release-repo> && ./scripts/build-and-release.sh --dry-run
#

set -euo pipefail

TOOLS_REMOTE_URL="https://github.com/Ricka7x/macos-release-tools.git"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <release-repo-name>"
  echo ""
  echo "Example: $0 myapp-web"
  exit 1
fi

REPO_NAME="$1"

if [ -e "$REPO_NAME" ]; then
  echo "❌ $REPO_NAME already exists here. Pick a different name or remove it first."
  exit 1
fi

ask() {
  local prompt="$1" default="${2:-}" answer
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " answer
    echo "${answer:-$default}"
  else
    read -r -p "$prompt: " answer
    echo "$answer"
  fi
}

echo "📦 Scaffolding release repo: $REPO_NAME"
echo ""

APP_NAME=$(ask "App name (used for DMG naming, e.g. MyApp)")
if [ -z "$APP_NAME" ]; then
  echo "❌ App name is required."
  exit 1
fi

XCODE_PROJECT_PATH=$(ask "Absolute path to the Xcode project directory")
XCODE_SCHEME=$(ask "Xcode scheme" "$APP_NAME")
INFO_PLIST=$(ask "Info.plist path (relative to Xcode project dir)" "$APP_NAME/Info.plist")
WEBSITE_URL=$(ask "Public website URL (e.g. https://myapp.com)")
CODE_SIGN_IDENTITY=$(ask "Code signing identity (exact Keychain name)")
NOTARY_PROFILE=$(ask "Notarytool keychain profile name (blank to use APPLE_ID/TEAM_ID/APP_PASSWORD env vars instead)" "")

echo ""
echo "Creating $REPO_NAME..."
mkdir -p "$REPO_NAME"
cd "$REPO_NAME"
git init -q
git branch -m main

echo "Adding macos-release-tools as scripts/ submodule..."
git submodule add "$TOOLS_REMOTE_URL" scripts

echo "Writing config.sh..."
cp scripts/config.example.sh config.sh

# Portable in-place sed (BSD/macOS sed requires the '' after -i)
sed_inplace() { sed -i '' "$@"; }

sed_inplace "s|^APP_NAME=.*|APP_NAME=\"$APP_NAME\"|" config.sh
sed_inplace "s|^XCODE_PROJECT_PATH=.*|XCODE_PROJECT_PATH=\"$XCODE_PROJECT_PATH\"|" config.sh
sed_inplace "s|^XCODE_SCHEME=.*|XCODE_SCHEME=\"$XCODE_SCHEME\"|" config.sh
sed_inplace "s|^INFO_PLIST=.*|INFO_PLIST=\"$INFO_PLIST\"|" config.sh
sed_inplace "s|^BUILD_DIR=.*|BUILD_DIR=\"/tmp/$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]')-build\"|" config.sh
sed_inplace "s|^ARCHIVE_PATH=.*|ARCHIVE_PATH=\"\$BUILD_DIR/$APP_NAME.xcarchive\"|" config.sh
if [ -n "$WEBSITE_URL" ]; then
  sed_inplace "s|^WEBSITE_URL=.*|WEBSITE_URL=\"$WEBSITE_URL\"|" config.sh
fi
if [ -n "$CODE_SIGN_IDENTITY" ]; then
  sed_inplace "s|^CODE_SIGN_IDENTITY=.*|CODE_SIGN_IDENTITY=\"$CODE_SIGN_IDENTITY\"|" config.sh
fi
if [ -n "$NOTARY_PROFILE" ]; then
  sed_inplace "s|^NOTARY_PROFILE=.*|NOTARY_PROFILE=\"\${NOTARY_PROFILE:-$NOTARY_PROFILE}\"|" config.sh
fi

mkdir -p releases

cat > .gitignore <<'EOF'
build.log
.env.local
.DS_Store
EOF

cat > README.md <<EOF
# $APP_NAME release repo

Release artifacts (DMGs, Sparkle appcast, release notes) for $APP_NAME,
built with [macos-release-tools](https://github.com/Ricka7x/macos-release-tools).

## Release

\`\`\`bash
./scripts/build-and-release.sh --dry-run   # preview
./scripts/build-and-release.sh             # ship it
\`\`\`

See \`scripts/USAGE_GUIDE.md\` for the full workflow.
EOF

git add .
git commit -q -m "chore: scaffold $APP_NAME release repo from macos-release-tools"

echo ""
echo "✅ Done. Created $(pwd)"
echo ""
echo "Next steps:"
echo "  1. Review config.sh (fill in anything left blank, e.g. notarization)"
echo "  2. Make sure your app's Info.plist has SUFeedURL + SUPublicEDKey for Sparkle"
echo "  3. Store a notarization credential if you haven't:"
echo "       xcrun notarytool store-credentials \"MyNotaryProfile\" --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx"
echo "  4. If $APP_NAME already has releases, tag its current version:"
echo "       git -C \"$XCODE_PROJECT_PATH\" tag -a v1.0.0 -m \"Release 1.0.0\""
echo "  5. Create the GitHub repo and push:"
echo "       gh repo create Ricka7x/$REPO_NAME --public --source=. --push"
echo "  6. Try it: ./scripts/build-and-release.sh --dry-run"
