#!/bin/sh
# Xcode Cloud post-clone script for the iOS Flutter app.
# Must live at ios/ci_scripts/ci_post_clone.sh — Xcode Cloud only discovers
# scripts under ci_scripts/ relative to the Xcode project (or repo root).
#
# Runs after git clone, before xcodebuild resolves Swift packages / builds.
# FlutterGeneratedPluginSwiftPackage is gitignored under ios/Flutter/ephemeral/
# and must be regenerated here or package resolution fails.
set -e

# The default working directory for this script is ios/ci_scripts/.
cd "${CI_PRIMARY_REPOSITORY_PATH}"

FLUTTER_DIR="${HOME}/flutter"
FLUTTER_BRANCH="stable"

# Install or update Flutter in the build environment.
if [ -d "${FLUTTER_DIR}/.git" ]; then
  echo "Updating existing Flutter checkout..."
  git -C "${FLUTTER_DIR}" fetch --depth 1 origin "${FLUTTER_BRANCH}"
  git -C "${FLUTTER_DIR}" checkout -f "${FLUTTER_BRANCH}"
  git -C "${FLUTTER_DIR}" reset --hard "origin/${FLUTTER_BRANCH}"
else
  echo "Cloning Flutter (${FLUTTER_BRANCH})..."
  rm -rf "${FLUTTER_DIR}"
  git clone https://github.com/flutter/flutter.git \
    --depth 1 -b "${FLUTTER_BRANCH}" "${FLUTTER_DIR}"
fi

export PATH="${FLUTTER_DIR}/bin:${PATH}"

echo "Flutter version:"
flutter --version

# Pre-download iOS engine artifacts (speeds up config generation).
flutter precache --ios

echo "flutter pub get"
flutter pub get

# Generate ios/Flutter/ephemeral (including Packages/FlutterGeneratedPluginSwiftPackage)
# and Generated.xcconfig so Xcode can resolve local Swift packages and build settings.
# --config-only skips compiling the app; Xcode Cloud compiles next.
echo "flutter build ios --config-only"
flutter build ios --config-only --no-codesign

# CocoaPods (plugins still use pods alongside SPM in many apps).
if ! command -v pod >/dev/null 2>&1; then
  echo "Installing CocoaPods via Homebrew..."
  HOMEBREW_NO_AUTO_UPDATE=1 brew install cocoapods
fi

echo "pod install"
cd ios
pod install --repo-update

echo "ci_post_clone complete."
# Sanity-check the package Xcode will resolve next.
if [ ! -d "Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage" ]; then
  echo "error: FlutterGeneratedPluginSwiftPackage was not generated" >&2
  ls -la Flutter/ephemeral 2>/dev/null || true
  ls -la Flutter/ephemeral/Packages 2>/dev/null || true
  exit 1
fi

echo "FlutterGeneratedPluginSwiftPackage is present."
exit 0
