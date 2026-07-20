#!/bin/sh
# Xcode Cloud pre-build script for the iOS Flutter app.
# Installs Flutter (if needed), fetches dependencies, and generates the
# Swift Package Manager files Xcode requires before it can resolve packages.
set -e

# Xcode Cloud provides the checked-out repository path.
cd "$CI_PRIMARY_REPOSITORY_PATH"

FLUTTER_DIR="$HOME/flutter"
FLUTTER_BRANCH="stable"

# Install or update Flutter in the build environment.
if [ -d "$FLUTTER_DIR" ]; then
  echo "Updating existing Flutter checkout..."
  git -C "$FLUTTER_DIR" fetch origin
  git -C "$FLUTTER_DIR" checkout "$FLUTTER_BRANCH"
  git -C "$FLUTTER_DIR" pull origin "$FLUTTER_BRANCH"
else
  echo "Cloning Flutter..."
  git clone https://github.com/flutter/flutter.git -b "$FLUTTER_BRANCH" --depth 1 "$FLUTTER_DIR"
fi

export PATH="$FLUTTER_DIR/bin:$PATH"

flutter --version
flutter pub get

# Generate iOS configuration, local Swift packages, and run pod install
# without performing the full compile (Xcode Cloud will do that next).
flutter build ios --config-only
