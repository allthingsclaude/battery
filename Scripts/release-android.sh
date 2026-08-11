#!/bin/bash

# Usage: ./Scripts/release-android.sh <version|keyword> [--yes]
# Examples:
#   ./Scripts/release-android.sh 0.2.0
#   ./Scripts/release-android.sh patch
#   ./Scripts/release-android.sh minor
#   ./Scripts/release-android.sh major
#
# The Android counterpart to release.sh and release-ios.sh. The shape is the
# same; what's missing is the interesting part:
#
#   * There is no version to bump, and so no commit. `versionName` comes from
#     the tag and `versionCode` from the commit count (see the Resolve version
#     step in .github/workflows/android-release.yml) — the literals in
#     app/build.gradle.kts are local-build defaults that CI overrides with -P
#     flags. So the current version has to be read back out of the tag list,
#     which is the only place it is recorded.
#   * The tag is `android-v*`, a third namespace beside the Mac's `v*` and the
#     iPhone's `ios-v*`, so an Android patch doesn't cut a menu-bar release.
#   * Nothing is built locally. CI runs :core:test before it signs anything, and
#     a release build here would need the keystore this script deliberately
#     never touches.
#
# It asks before pushing, like the iOS script, though for a weaker reason: a
# GitHub release can be deleted, unlike a consumed TestFlight build number. But
# every installed APK polls the releases feed on its own schedule, so a release
# can reach a device before you've finished deciding you regret it. Pass --yes
# to skip the prompt.

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ASSUME_YES=false
INPUT=""

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
    *)        INPUT="$arg" ;;
  esac
done

if [ -z "$INPUT" ]; then
  echo "Usage: ./Scripts/release-android.sh <version|keyword> [--yes]"
  echo ""
  echo "Version: X.Y.Z (e.g., 0.2.0)"
  echo ""
  echo "Keywords:"
  echo "  major  - Bump major version (X.0.0)"
  echo "  minor  - Bump minor version (x.Y.0)"
  echo "  patch  - Bump patch version (x.y.Z)"
  exit 1
fi

# ── Current version ─────────────────────────────────────────────────────
# The tags are the record. -v:refname sorts them as versions rather than
# lexically, so android-v0.10.0 beats android-v0.9.0.
LATEST_TAG=$(git tag -l 'android-v*' --sort=-v:refname | head -n1)
CURRENT_VERSION="${LATEST_TAG#android-v}"

case "$INPUT" in
  major|minor|patch)
    # A keyword needs something to bump from. On the very first release there is
    # no previous tag and no file to fall back on, so ask for the number.
    if [ -z "$CURRENT_VERSION" ]; then
      echo "Error: No android-v* tag exists yet, so there's nothing for '$INPUT'"
      echo "       to bump from. Give the first version explicitly, e.g. 0.1.0."
      exit 1
    fi
    ;;
esac

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

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
    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Error: Version must be in format X.Y.Z (e.g., 0.2.0) or a keyword (major/minor/patch)"
      exit 1
    fi
    if [ -n "$CURRENT_VERSION" ]; then
      echo "Setting version: $CURRENT_VERSION -> $VERSION"
    else
      echo "Setting version: $VERSION (first Android release)"
    fi
    ;;
esac

TAG="android-v$VERSION"

# ── Preflight ───────────────────────────────────────────────────────────
# Each of these otherwise surfaces minutes into the workflow, or — worse — not
# at all.

if [ -n "$(git status --porcelain)" ]; then
  echo "Error: Working tree is dirty. Commit or stash first — the release must"
  echo "       build from exactly what's tagged."
  exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Error: Tag $TAG already exists."
  exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
  # Not fatal: the workflow triggers on the tag push, so it runs fine from a
  # branch that has never been merged.
  echo "Warning: On branch '$BRANCH', not main."
fi

# Going backwards is silent rather than loud, which is why it's worth catching.
# UpdateChecker only offers a release that is *newer* than what's installed, so
# an older version number publishes an APK that no installed app will ever
# surface — it just sits there looking released.
if [ -n "$CURRENT_VERSION" ]; then
  OLDEST=$(printf '%s\n%s\n' "$CURRENT_VERSION" "$VERSION" | sort -V | head -n1)
  if [ "$OLDEST" != "$CURRENT_VERSION" ]; then
    echo "Warning: $VERSION is older than the last release ($CURRENT_VERSION)."
    echo "         Installed apps only offer strictly newer versions, so nobody"
    echo "         running $CURRENT_VERSION will be told about this one."
  fi
fi

# The four signing secrets. None are shared with the Mac or iOS releases —
# Apple certificates can't sign an APK. Only checked when gh is available and
# logged in; a missing one otherwise fails the build after :core:test has run.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  MISSING=""
  EXISTING=$(gh secret list --json name --jq '.[].name' 2>/dev/null || echo "")
  if [ -n "$EXISTING" ]; then
    for required in ANDROID_KEYSTORE ANDROID_KEYSTORE_PASSWORD \
                    ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
      if ! echo "$EXISTING" | grep -qx "$required"; then
        MISSING="$MISSING $required"
      fi
    done
  fi
  if [ -n "$MISSING" ]; then
    echo ""
    echo "Error: Missing repository secrets:$MISSING"
    echo "       See android/README.md — 'Secrets'."
    exit 1
  fi
fi

echo ""

# ── Tag ─────────────────────────────────────────────────────────────────
git tag "$TAG"
echo "  Created tag $TAG"

# ── Confirm, then push ──────────────────────────────────────────────────
if [ "$ASSUME_YES" != true ]; then
  echo ""
  echo "About to push $TAG. This builds and signs an APK and publishes it to"
  echo "GitHub Releases, where installed apps will find it on their next check."
  echo ""
  read -r -p "Push? [y/N] " REPLY
  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Stopped. $TAG exists locally but nothing was pushed. To undo:"
    echo "    git tag -d $TAG"
    exit 0
  fi
fi

# Pushing the tag carries the commit it points at, so the branch pointer is the
# only thing that would be left behind. Push it when there's an upstream and
# something to send; skip quietly otherwise, because a branch with no upstream
# is the workflow's supported case and a bare `git push` there would fail with
# the tag already created.
if UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
  if [ -n "$(git log --oneline "$UPSTREAM..HEAD" 2>/dev/null)" ]; then
    git push
    echo "  Pushed $BRANCH to $UPSTREAM"
  fi
else
  echo "  Branch '$BRANCH' has no upstream — pushing the tag only"
fi

git push origin "$TAG"
echo "  Pushed tag to origin"

echo ""
echo "Done! Tagged $TAG"
echo "The Android release workflow will now test, sign, and publish battery-$VERSION.apk."
if command -v gh >/dev/null 2>&1; then
  echo ""
  echo "Follow it with:  gh run watch"
fi
