#!/bin/sh
# Xcode Cloud post-clone script for the iOS Flutter app.
# Runs immediately after the repo is cloned and before Xcode resolves packages.
# Installs Flutter, fetches dependencies, and generates the local Swift Package
# Manager files Xcode needs to resolve the workspace.
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

# Generate the iOS configuration and local Swift packages so Xcode can resolve
# dependencies. This does not compile the app (Xcode Cloud will do that next).
flutter build ios --config-only
