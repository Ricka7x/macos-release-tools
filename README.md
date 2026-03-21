# Release Scripts

Production-ready automated build and release pipeline for macOS apps.

## Scripts Overview

| Script | Purpose | Usage |
|--------|---------|-------|
| **build-and-release.sh** | Complete end-to-end pipeline | `./build-and-release.sh [options]` |
| **release.sh** | Add release to repository | `./release.sh Snapback-X.Y.Z.zip [options]` |
| **generate-appcast.sh** | Generate Sparkle feed | `./generate-appcast.sh [options]` |
| **config.example.sh** | Configuration template | Copy to `config.sh` and fill in values |

## Quick Start

### One-Command Release

```bash
./build-and-release.sh
```

This handles everything:

- ✅ Validates environment
- ✅ Builds Xcode project
- ✅ Archives and exports app
- ✅ Creates release zip
- ✅ Generates appcast.xml
- ✅ Commits to git

### With Options

```bash
# Test without changes
./build-and-release.sh --dry-run

# Include release notes
./build-and-release.sh --release-notes ../release-notes/v1.0.0.html

# Manual git control
./build-and-release.sh --skip-git

# Verbose output
./build-and-release.sh --verbose

# Show help
./build-and-release.sh --help
```

## Manual Workflow

For more control, run scripts individually:

### 1. Add a Release

```bash
./release.sh /path/to/Snapback-1.0.0.zip
```

### 2. With Release Notes

```bash
./release.sh /path/to/Snapback-1.0.0.zip \
  --release-notes ../release-notes/v1.0.0.html
```

### 3. Manual Appcast Generation

```bash
./generate-appcast.sh
```

## Configuration

Copy `config.example.sh` to `config.sh` and customize:

- Project paths
- Xcode scheme and configuration
- Release URLs
- Sparkle settings
- Build directories



## Environment Setup

The scripts require:

- ✅ macOS with Xcode
- ✅ Xcode command line tools
- ✅ Sparkle framework (via Xcode package or Homebrew)
- ✅ Git repository
- ✅ `SPARKLE_BIN` set in your environment

### Install Dependencies

```bash
# Xcode command line tools (if needed)
xcode-select --install
```

### Sparkle Setup

`generate-appcast.sh` requires `SPARKLE_BIN` to point to Sparkle's binary directory. Set it in your `.env.local` or shell profile:

```bash
# .env.local (gitignored)
export SPARKLE_BIN="$HOME/Library/Developer/Xcode/DerivedData/[YourApp]/SourcePackages/artifacts/sparkle/Sparkle/bin"
```

The DerivedData path is created automatically when you build your Xcode project with Sparkle as a Swift Package dependency.

## Error Handling

All scripts include:

- ✅ Input validation
- ✅ File existence checks
- ✅ Detailed error messages
- ✅ Structured logging
- ✅ Colored output

Check `build.log` for detailed output:

```bash
tail -f build.log
```

## Best Practices

1. **Test locally first**
   ```bash
   ./build-and-release.sh --dry-run
   ```

2. **Review changes**
   ```bash
   git diff
   ```

3. **Keep versions semantic** (semver)
   - `Snapback-1.0.0.zip` ✅
   - `Snapback-v1.0.0.zip` ❌
   - `Snapback-1-0-0.zip` ❌

4. **Include meaningful release notes**
   - What's new
   - Bug fixes
   - Breaking changes

5. **Verify before production**
   - Test on staging first
   - Monitor GitHub Actions logs
   - Verify appcast.xml is valid

## Troubleshooting

### Script Not Executable

```bash
chmod +x *.sh
```

### Sparkle Not Found

```bash
export SPARKLE_BIN="$HOME/Library/Developer/Xcode/DerivedData/[YourApp]/SourcePackages/artifacts/sparkle/Sparkle/bin"
./build-and-release.sh
```

### Build Fails

```bash
# Check logs
tail build.log

# Run with verbose
./build-and-release.sh --verbose
```

### Git Issues

```bash
# Skip git and do manually
./build-and-release.sh --skip-git

# Then:
cd ..
git add releases/
git commit -m "chore(release): Snapback v1.0.0"
git push
```

## CI/CD Integration

GitHub Actions automatically runs when you push releases:

- 📁 Push to `releases/` folder
- 🔄 Workflow triggers
- 📋 Appcast generated
- ✅ Changes committed back

See `.github/workflows/generate-appcast.yml` for automation details.


