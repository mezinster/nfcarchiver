#!/bin/bash
# Version bump script for NFC Archiver
# Usage: ./scripts/bump_version.sh [major|minor|patch] [--tag]

set -e

PUBSPEC_FILE="pubspec.yaml"

# Get current version from pubspec.yaml
CURRENT_VERSION=$(grep "^version:" "$PUBSPEC_FILE" | sed 's/version: //' | cut -d'+' -f1)
CURRENT_BUILD=$(grep "^version:" "$PUBSPEC_FILE" | sed 's/version: //' | cut -d'+' -f2)

echo "Current version: $CURRENT_VERSION+$CURRENT_BUILD"

# Parse version components
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# Determine bump type
BUMP_TYPE="${1:-patch}"
CREATE_TAG="${2:-}"

case "$BUMP_TYPE" in
  major)
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
    ;;
  minor)
    MINOR=$((MINOR + 1))
    PATCH=0
    ;;
  patch)
    PATCH=$((PATCH + 1))
    ;;
  *)
    echo "Usage: $0 [major|minor|patch] [--tag]"
    echo "  major - Breaking changes (1.0.0 -> 2.0.0)"
    echo "  minor - New features (1.0.0 -> 1.1.0)"
    echo "  patch - Bug fixes (1.0.0 -> 1.0.1)"
    echo "  --tag - Also create a git tag"
    exit 1
    ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "New version: $NEW_VERSION+$NEW_BUILD"

# Update pubspec.yaml
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS
  sed -i '' "s/^version: .*/version: $NEW_VERSION+$NEW_BUILD/" "$PUBSPEC_FILE"
else
  # Linux
  sed -i "s/^version: .*/version: $NEW_VERSION+$NEW_BUILD/" "$PUBSPEC_FILE"
fi

echo "Updated $PUBSPEC_FILE"

# Create git tag if requested
if [ "$CREATE_TAG" == "--tag" ]; then
  git add "$PUBSPEC_FILE"
  git commit -m "Bump version to $NEW_VERSION"
  git tag -a "v$NEW_VERSION" -m "Release v$NEW_VERSION"
  echo "Created tag v$NEW_VERSION"
  echo "Run 'git push && git push --tags' to trigger release"
fi

echo "Done!"
