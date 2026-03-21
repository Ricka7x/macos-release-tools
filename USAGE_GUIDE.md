# Usage Guide

Automated release pipeline for macOS apps. Handles versioning, building, notarization, release notes, and Sparkle appcast generation — all from a single command.

## Prerequisites

Install required tools:

```bash
brew install git-cliff dmgbuild
```

Xcode command line tools must be installed (`xcodebuild`, `xcrun`).

A notarization credential must be stored in your Keychain:
```bash
xcrun notarytool store-credentials "MyNotaryProfile" \
  --apple-id you@example.com \
  --team-id XXXXXXXXXX \
  --password xxxx-xxxx-xxxx-xxxx
```

---

## Setting up a new project

### 1. Create a release repo

This repo holds your release artifacts (DMGs, appcast, release notes HTML) and is deployed via GitHub Pages or similar.

```bash
mkdir my-app-releases && cd my-app-releases
git init && git branch -m main
```

### 2. Add this repo as a submodule

```bash
git submodule add git@github.com:Ricka7x/macos-release-tools.git scripts
```

### 3. Create your config

```bash
cp scripts/config.example.sh config.sh
```

Edit `config.sh` and fill in your values:

```bash
APP_NAME="MyApp"
XCODE_PROJECT_PATH="/path/to/MyApp"
XCODE_SCHEME="MyApp"
INFO_PLIST="MyApp/Info.plist"
WEBSITE_URL="https://myapp.com"
NOTARY_PROFILE="MyNotaryProfile"
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

### 4. Set up Sparkle in your app

Make sure your app's `Info.plist` contains:
```xml
<key>SUFeedURL</key>
<string>https://myapp.com/releases/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>YOUR_PUBLIC_ED_KEY</string>
```

### 5. Tag your current release

If your app already has releases, tag the current version so git-cliff has a baseline:

```bash
cd /path/to/MyApp
git tag -a v1.2.3 HEAD -m "Release 1.2.3"
git push origin v1.2.3
```

---

## Day-to-day workflow

### Making changes

Commit freely using [Conventional Commits](https://www.conventionalcommits.org/):

```bash
git commit -m "feat: add dark mode support"
git commit -m "fix: crash on launch when no workspaces exist"
git commit -m "feat(settings): add keyboard shortcut customization"
```

Rules:
- `feat:` → triggers a **minor** version bump at release time (0.3.x → 0.4.0)
- `fix:` → triggers a **patch** version bump (0.3.5 → 0.3.6)
- `chore:`, `docs:`, `refactor:`, etc. → skipped in release notes, no version bump impact
- `BREAKING CHANGE:` in footer → triggers a **major** bump (0.3.x → 1.0.0)

No need to touch version numbers in Xcode — the release script handles that.

### Releasing

When ready to ship, run from your release repo:

```bash
cd ~/Projects/my-app-releases
./scripts/build-and-release.sh
```

That's it. The script will:

1. Read commits since the last tag via `git-cliff`
2. Determine the next version automatically (`feat` → minor, `fix` → patch)
3. Write the new version to `Info.plist` and `project.pbxproj`
4. Build and archive with Xcode
5. Export, notarize, and staple the app
6. Create a release DMG
7. Generate HTML release notes from your commit messages
8. Copy DMG + notes to `releases/`
9. Regenerate `appcast.xml` (with `<sparkle:releaseNotesLink>`)
10. Commit the version bump to the app repo
11. Commit the release to the release repo
12. Tag the app repo `v{VERSION}` and push the tag
13. Push the release repo (triggering GH Pages deploy)

---

## Options

```bash
# Preview everything without making any changes
./scripts/build-and-release.sh --dry-run

# Skip all git operations (commit, push, tag)
./scripts/build-and-release.sh --skip-git

# Override auto-generated release notes with your own file
./scripts/build-and-release.sh --release-notes ./my-notes.html

# Override the version determined by git-cliff
./scripts/build-and-release.sh --version 2.0.0

# Verbose output (also written to build.log)
./scripts/build-and-release.sh --verbose
```

---

## How versioning works

`git-cliff` reads all commits since the last `vX.Y.Z` tag and determines the bump:

| Commits since last tag | Version bump | Example |
|------------------------|--------------|---------|
| Only `fix:` commits | patch | `0.3.5` → `0.3.6` |
| Any `feat:` commit | minor | `0.3.5` → `0.4.0` |
| Any `BREAKING CHANGE:` | major | `0.3.5` → `1.0.0` |
| No conventional commits | patch (fallback) | `0.3.5` → `0.3.6` |

The version is written to both `Info.plist` (`CFBundleShortVersionString`) and `project.pbxproj` (`MARKETING_VERSION`). The build number (`CFBundleVersion` / `CURRENT_PROJECT_VERSION`) is incremented by 1 from whatever it currently is.

---

## Release notes

Release notes are generated automatically from `feat:` and `fix:` commits since the last tag. The output is an HTML file saved to `releases/AppName-X.Y.Z.html`.

Sparkle picks this up automatically via `<sparkle:releaseNotesLink>` in the appcast, so users see a formatted changelog in the update dialog.

To customize the HTML template, edit `cliff.toml` in this repo.

---

## Using on multiple projects

Each project that uses these tools needs:

1. This repo as a submodule at `scripts/`
2. Its own `config.sh` at the root of the release repo (copied from `config.example.sh`)

The scripts themselves contain no project-specific code.

---

## Troubleshooting

**`config.sh not found`**
Run `cp scripts/config.example.sh config.sh` and fill in your values.

**`git-cliff could not determine next version`**
Make sure there are conventional commits (`feat:` or `fix:`) since the last tag. Run `git log vLAST..HEAD --oneline` to check.

**Build fails**
Check `build.log` in the root of the release repo for the full Xcode output.

**Sparkle not found**
Set `SPARKLE_BIN` in your `.env.local` or shell profile:

```bash
export SPARKLE_BIN="$HOME/Library/Developer/Xcode/DerivedData/[YourApp]/SourcePackages/artifacts/sparkle/Sparkle/bin"
```

**Notarization fails**
Verify your keychain profile: `xcrun notarytool history --keychain-profile "YourProfile"`
