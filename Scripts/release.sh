#!/bin/bash

# Usage: ./Scripts/release.sh <version|keyword>
# Examples:
#   ./Scripts/release.sh 0.2.0
#   ./Scripts/release.sh patch
#   ./Scripts/release.sh minor
#   ./Scripts/release.sh major

set -e

if [ -z "$1" ]; then
  echo "Usage: ./Scripts/release.sh <version|keyword>"
  echo ""
  echo "Version: X.Y.Z (e.g., 0.2.0)"
  echo ""
  echo "Keywords:"
  echo "  major  - Bump major version (X.0.0)"
  echo "  minor  - Bump minor version (x.Y.0)"
  echo "  patch  - Bump patch version (x.y.Z)"
  exit 1
fi

INPUT="$1"

# Get current version from Info.plist
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist 2>/dev/null)

if [ -z "$CURRENT_VERSION" ]; then
  echo "Error: Could not read current version from Info.plist"
  exit 1
fi

# Parse current version components
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# Check if input is a keyword or explicit version
case "$INPUT" in
  major)
    VERSION="$((MAJOR + 1)).0.0"
    echo "Bumping major: $CURRENT_VERSION -> $VERSION"
    ;;
  minor)
    VERSION="$MAJOR.$((MINOR + 1)).0"
    echo "Bumping minor: $CURRENT_VERSION -> $VERSION"
    ;;
  patch)
    VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
    echo "Bumping patch: $CURRENT_VERSION -> $VERSION"
    ;;
  *)
    VERSION="$INPUT"
    # Validate version format (semver without v prefix)
    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Error: Version must be in format X.Y.Z (e.g., 0.2.0) or a keyword (major/minor/patch)"
      exit 1
    fi
    echo "Setting version: $CURRENT_VERSION -> $VERSION"
    ;;
esac

echo ""
echo "Bumping version to $VERSION..."
echo ""

# Update Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
echo "  Updated Info.plist"

# Update Homebrew cask (version + download URL; SHA256 is updated by release CI)
sed -i '' "s/version \"[^\"]*\"/version \"$VERSION\"/" Casks/claude-battery.rb
sed -i '' "s|download/v[^/]*/Battery-[^\"]*\.dmg|download/v$VERSION/Battery-$VERSION.dmg|" Casks/claude-battery.rb
echo "  Updated Casks/claude-battery.rb"

# Update the User-Agent every API request sends. Missed here until 0.8.0, so
# releases from 0.2.4 onward all identified themselves as 0.2.4 — which quietly
# ruins the one signal that says which build a request came from.
sed -i '' "s|static let userAgent = \"Battery/[^\"]*\"|static let userAgent = \"Battery/$VERSION\"|" \
  Sources/Utilities/Constants.swift
echo "  Updated Sources/Utilities/Constants.swift"

# Fail loudly rather than shipping a build that lies about its version.
if ! grep -q "static let userAgent = \"Battery/$VERSION\"" Sources/Utilities/Constants.swift; then
  echo "Error: could not update userAgent in Sources/Utilities/Constants.swift" >&2
  exit 1
fi

echo ""

# Commit the changes
git add Info.plist Casks/claude-battery.rb Sources/Utilities/Constants.swift
git commit -m "chore: bump version to $VERSION"
echo "  Committed version bump"

# Create and push the tag
git tag "v$VERSION"
echo "  Created tag v$VERSION"

git push
git push origin "v$VERSION"
echo "  Pushed commit and tag to origin"

echo ""
echo "Done! Version bumped to $VERSION"
echo "The release workflow will now build, sign, and publish v$VERSION."
