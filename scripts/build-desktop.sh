#!/usr/bin/env bash
#
# Build desktop release bundles for macOS, Windows, and Linux.
# Usage: ./scripts/build-desktop.sh [macos|windows|linux|all]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

PLATFORM="${1:-macos}"

package_macos() {
  local app
  app="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' | head -1)"
  if [[ -z "${app}" ]]; then
    echo "✗ macOS .app not found — run flutter build macos first"
    exit 1
  fi
  local tag="${1:-local}"
  mkdir -p dist
  local out="dist/erebrus-drop-macos-${tag}.zip"
  ditto -c -k --keepParent "${app}" "${out}"
  echo "✓ packaged → ${out}"
}

package_linux() {
  local bundle
  bundle="$(find build/linux -maxdepth 2 -type d -name 'bundle' | head -1)"
  if [[ -z "${bundle}" ]]; then
    echo "✗ linux bundle not found"
    exit 1
  fi
  local tag="${1:-local}"
  mkdir -p dist
  local out="dist/erebrus-drop-linux-${tag}.tar.gz"
  tar -czf "${out}" -C "$(dirname "${bundle}")" "$(basename "${bundle}")"
  echo "✓ packaged → ${out}"
}

package_windows() {
  local runner
  runner="$(find build/windows/x64/runner/Release -maxdepth 1 -type d 2>/dev/null | head -1)"
  if [[ -z "${runner}" ]]; then
    echo "✗ windows Release folder not found"
    exit 1
  fi
  local tag="${1:-local}"
  mkdir -p dist
  local out="dist/erebrus-drop-windows-${tag}.zip"
  (cd "${runner}" && zip -qr "${ROOT_DIR}/${out}" .)
  echo "✓ packaged → ${out}"
}

read_version_tag() {
  local version_line
  version_line="$(grep '^version:' pubspec.yaml | awk '{print $2}')"
  local version_name="${version_line%%+*}"
  echo "v${version_name}"
}

build_one() {
  local p="$1"
  local tag
  tag="$(read_version_tag)"
  echo "▸ flutter pub get"
  flutter pub get
  echo "▸ generate desktop brand assets"
  python3 scripts/generate-desktop-assets.py
  echo "▸ flutter build ${p} --release"
  scripts/build.sh "build-${p}" --release
  case "${p}" in
    macos) package_macos "${tag}" ;;
    linux) package_linux "${tag}" ;;
    windows) package_windows "${tag}" ;;
  esac
}

case "${PLATFORM}" in
  macos) build_one macos ;;
  linux) build_one linux ;;
  windows) build_one windows ;;
  all)
    build_one macos
    build_one linux || echo "⚠ linux build skipped (needs Linux host)"
    build_one windows || echo "⚠ windows build skipped (needs Windows host)"
    ;;
  *) echo "usage: $0 [macos|windows|linux|all]"; exit 1 ;;
esac