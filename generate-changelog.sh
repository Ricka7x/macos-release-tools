#!/bin/bash
#
# generate-changelog.sh - Generate HTML release notes from git commit history
#
# Reads conventional commits between the last git tag and HEAD in the app repo,
# groups them by type (feat/fix), and outputs an HTML file for Sparkle.
#
# Usage:
#   ./generate-changelog.sh --version X.Y.Z [options]
#
# Options:
#   --version VERSION   The version being released (required)
#   --app-repo PATH     Path to the app repo (default: XCODE_PROJECT_PATH from config.sh)
#   --output FILE       Write HTML to this file (default: stdout)
#

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/config.sh"

VERSION=""
APP_REPO="$XCODE_PROJECT_PATH"
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --version)
      [ -z "${2:-}" ] && { echo "Error: --version requires a value" >&2; exit 1; }
      VERSION="$2"; shift 2 ;;
    --app-repo)
      [ -z "${2:-}" ] && { echo "Error: --app-repo requires a path" >&2; exit 1; }
      APP_REPO="$2"; shift 2 ;;
    --output)
      [ -z "${2:-}" ] && { echo "Error: --output requires a file path" >&2; exit 1; }
      OUTPUT="$2"; shift 2 ;;
    --help)
      sed -n '/^#/p' "$0" | sed 's/^# *//' | sed '/^$/d'
      exit 0 ;;
    *)
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "Error: --version is required" >&2
  exit 1
fi

if [ ! -d "$APP_REPO/.git" ]; then
  echo "Error: app repo not found or not a git repo: $APP_REPO" >&2
  exit 1
fi

# ============================================================================
# COLLECT COMMITS
# ============================================================================

cd "$APP_REPO"

# Find the most recent tag to determine the commit range.
# If no tags exist yet, use all commits.
LAST_TAG=$(git tag --sort=-version:refname 2>/dev/null | head -1)

if [ -n "$LAST_TAG" ]; then
  RANGE="$LAST_TAG..HEAD"
else
  RANGE="HEAD"
fi

# Gather subject lines, excluding merge commits
COMMITS=$(git log "$RANGE" --pretty=format:"%s" --no-merges 2>/dev/null || true)

# ============================================================================
# PARSE COMMITS INTO CATEGORIES
# ============================================================================

FEATURES=()
FIXES=()

capitalize() {
  local s="$1"
  echo "$(tr '[:lower:]' '[:upper:]' <<< "${s:0:1}")${s:1}"
}

while IFS= read -r line; do
  [ -z "$line" ] && continue

  # Extract the type: everything before the first '(' or ':'
  # Handles both "feat: msg" and "feat(scope): msg"
  prefix="${line%%:*}"       # e.g. "feat" or "feat(scope)"
  type="${prefix%%(*}"       # strip optional scope → "feat"
  msg="${line#*: }"          # everything after the first ": "

  # Skip if msg is same as line (no ": " found — not a conventional commit)
  [ "$msg" = "$line" ] && continue

  case "$type" in
    feat)   FEATURES+=("$(capitalize "$msg")") ;;
    fix)    FIXES+=("$(capitalize "$msg")") ;;
    # chore/docs/refactor/style/test/perf/ci/build — not user-facing, skip
  esac
done <<< "$COMMITS"

# ============================================================================
# GENERATE HTML
# ============================================================================

generate_html() {
  echo "<!DOCTYPE html>"
  echo "<html>"
  echo "<head><meta charset=\"utf-8\"></head>"
  echo "<body>"
  echo "<h3>What's new in $VERSION</h3>"

  if [ ${#FEATURES[@]} -gt 0 ]; then
    echo "<h4>New Features</h4>"
    echo "<ul>"
    for item in "${FEATURES[@]}"; do
      echo "  <li>$item</li>"
    done
    echo "</ul>"
  fi

  if [ ${#FIXES[@]} -gt 0 ]; then
    echo "<h4>Bug Fixes</h4>"
    echo "<ul>"
    for item in "${FIXES[@]}"; do
      echo "  <li>$item</li>"
    done
    echo "</ul>"
  fi

  if [ ${#FEATURES[@]} -eq 0 ] && [ ${#FIXES[@]} -eq 0 ]; then
    echo "<p>Minor improvements and stability fixes.</p>"
  fi

  echo "</body>"
  echo "</html>"
}

if [ -n "$OUTPUT" ]; then
  generate_html > "$OUTPUT"
  echo "✅ Release notes written to: $OUTPUT" >&2
else
  generate_html
fi
