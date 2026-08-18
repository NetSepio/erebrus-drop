#!/usr/bin/env bash
#
# Build store / release artifacts for every platform this host can produce.
#
# Outputs land in dist/ with the naming convention:
#   ErebrusDrop-<platform>-vX.X.X.<ext>
#
# Examples:
#   ErebrusDrop-android-playstore-v1.0.8.aab
#   ErebrusDrop-android-dappstore-v1.0.8.apk
#   ErebrusDrop-ios-v1.0.8.ipa
#   ErebrusDrop-macos-v1.0.8.zip
#   ErebrusDrop-windows-v1.0.8.zip
#   ErebrusDrop-ubuntu-v1.0.8.tar.gz
#
# Usage:
#   ./scripts/build-all-release.sh              # all platforms supported here
#   ./scripts/build-all-release.sh android      # playstore AAB + dappstore APK
#   ./scripts/build-all-release.sh ios macos
#   ./scripts/build-all-release.sh --skip-verify
#   ./scripts/build-all-release.sh --skip-tests
#   ./scripts/build-all-release.sh --list
#
# On macOS: Android, iOS, macOS (native). Ubuntu via Docker when available.
# Windows requires a Windows host (or the GitHub Release workflow).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

APP_NAME="ErebrusDrop"
DIST_DIR="${ROOT_DIR}/dist"
SKIP_VERIFY=0
SKIP_TESTS=0
TARGETS=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { echo "✗ $*" >&2; exit 1; }
info() { echo "▸ $*"; }
ok() { echo "✓ $*"; }
warn() { echo "⚠ $*" >&2; }

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

read_version() {
  # Canonical version is pubspec.yaml only (Flutter's version: X.Y.Z+build).
  local pubspec="${ROOT_DIR}/pubspec.yaml"
  [[ -f "${pubspec}" ]] || die "pubspec.yaml not found at ${pubspec}"

  local version_line
  version_line="$(grep -E '^version:[[:space:]]*' "${pubspec}" | head -1 | awk '{print $2}')"
  [[ -n "${version_line}" ]] || die "Could not read version: from pubspec.yaml"

  VERSION_NAME="${version_line%%+*}"
  VERSION_CODE="${version_line##*+}"
  [[ -n "${VERSION_NAME}" ]] || die "Empty version name in pubspec.yaml (${version_line})"
  # If there is no +build suffix, treat build as 1.
  if [[ "${VERSION_CODE}" == "${version_line}" ]]; then
    VERSION_CODE="1"
  fi
  [[ "${VERSION_NAME}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.+-]+)?$ ]] \
    || die "Unexpected version name '${VERSION_NAME}' in pubspec.yaml (expected X.Y.Z)"

  VERSION_TAG="v${VERSION_NAME}"
  ok "version from pubspec.yaml: ${VERSION_NAME}+${VERSION_CODE} → ${VERSION_TAG}"
}

artifact_path() {
  # artifact_path <platform-slug> <ext>
  echo "${DIST_DIR}/${APP_NAME}-$1-${VERSION_TAG}.$2"
}

dart_define_args() {
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    echo "--dart-define-from-file=${ROOT_DIR}/.env"
  else
    warn ".env missing — copy env.example → .env for production API keys"
    echo ""
  fi
}

host_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) echo "windows" ;;
    *) echo "unknown" ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ensure_dist() {
  mkdir -p "${DIST_DIR}"
}

copy_artifact() {
  local src="$1" dest="$2"
  [[ -f "${src}" ]] || die "Build output missing: ${src}"
  cp -f "${src}" "${dest}"
  ok "artifact → ${dest##${ROOT_DIR}/} ($(du -h "${dest}" | awk '{print $1}'))"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
  require_cmd flutter
  require_cmd python3
  ensure_dist

  info "host=$(host_os)  version=${VERSION_NAME}+${VERSION_CODE}  out=dist/"
  info "flutter pub get"
  flutter pub get

  if [[ "${SKIP_TESTS}" -eq 0 ]]; then
    info "flutter analyze"
    flutter analyze
    info "flutter test"
    flutter test
  else
    warn "skipping analyze + test (--skip-tests)"
  fi
}

# ---------------------------------------------------------------------------
# Android — Play Store AAB + dApp Store APK (signed via key.properties)
# ---------------------------------------------------------------------------

ensure_android_signing() {
  [[ -f android/key.properties ]] || die \
    "Missing android/key.properties. See android/key.properties.example and docs/BUILD.md."

  local missing=0
  for prefix in playstore dappstore; do
    for key in storeFile storePassword keyAlias keyPassword; do
      if ! grep -qE "^${prefix}\\.${key}=.+" android/key.properties; then
        warn "android/key.properties missing ${prefix}.${key}"
        missing=1
      fi
    done
  done
  [[ "${missing}" -eq 0 ]] || die "Fix android/key.properties before Android release builds."

  # Gradle resolves storeFile relative to android/app/ (app module).
  resolve_keystore() {
    local raw="$1"
    if [[ "${raw}" = /* ]]; then
      [[ -f "${raw}" ]] && { echo "${raw}"; return; }
      return 1
    fi
    local candidates=(
      "android/app/${raw}"
      "android/${raw}"
      "${raw}"
    )
    local c
    for c in "${candidates[@]}"; do
      if [[ -f "${c}" ]]; then
        echo "${c}"
        return 0
      fi
    done
    return 1
  }

  local play_ks dapp_ks play_path dapp_path
  play_ks="$(grep '^playstore.storeFile=' android/key.properties | cut -d= -f2-)"
  dapp_ks="$(grep '^dappstore.storeFile=' android/key.properties | cut -d= -f2-)"
  play_path="$(resolve_keystore "${play_ks}")" \
    || die "Play Store keystore not found (playstore.storeFile=${play_ks})"
  dapp_path="$(resolve_keystore "${dapp_ks}")" \
    || die "dApp Store keystore not found (dappstore.storeFile=${dapp_ks})"
  ok "playstore keystore: ${play_path}"
  ok "dappstore keystore: ${dapp_path}"
}

build_android_playstore() {
  info "Google Play App Bundle (playstoreRelease, arm64)"
  ensure_android_signing
  local define_args
  define_args="$(dart_define_args)"
  # shellcheck disable=SC2086
  flutter build appbundle --flavor playstore --release \
    --target-platform android-arm64 ${define_args}

  local src="build/app/outputs/bundle/playstoreRelease/app-playstore-release.aab"
  local dest
  dest="$(artifact_path android-playstore aab)"
  copy_artifact "${src}" "${dest}"
}

build_android_dappstore() {
  info "Solana dApp Store APK (dappstoreRelease, arm64)"
  ensure_android_signing
  local define_args
  define_args="$(dart_define_args)"
  # shellcheck disable=SC2086
  flutter build apk --flavor dappstore --release \
    --target-platform android-arm64 ${define_args}

  local src="build/app/outputs/flutter-apk/app-dappstore-release.apk"
  if [[ ! -f "${src}" ]]; then
    src="build/app/outputs/apk/dappstore/release/app-dappstore-release.apk"
  fi
  local dest
  dest="$(artifact_path android-dappstore apk)"
  copy_artifact "${src}" "${dest}"
}

build_android() {
  build_android_playstore
  build_android_dappstore
}

# ---------------------------------------------------------------------------
# iOS — IPA for TestFlight / App Store
# ---------------------------------------------------------------------------

build_ios() {
  [[ "$(host_os)" == "macos" ]] || die "iOS builds require macOS + Xcode"

  info "iOS IPA (App Store / TestFlight)"
  require_cmd xcodebuild

  local define_args
  define_args="$(dart_define_args)"
  # shellcheck disable=SC2086
  flutter build ipa --release ${define_args}

  local src
  src="$(find build/ios/ipa -maxdepth 1 -name '*.ipa' 2>/dev/null | head -1 || true)"
  [[ -n "${src}" ]] || die "IPA not found under build/ios/ipa/ — check signing / export logs"
  local dest
  dest="$(artifact_path ios ipa)"
  copy_artifact "${src}" "${dest}"

  if [[ "${SKIP_VERIFY}" -eq 0 ]]; then
    verify_ios_ipa "${dest}"
  fi
}

verify_ios_ipa() {
  local ipa="$1"
  info "Verifying iOS IPA version metadata…"
  local work
  work="$(mktemp -d)"
  unzip -q "${ipa}" -d "${work}"
  local app
  app="$(find "${work}/Payload" -maxdepth 1 -name '*.app' | head -1)"
  [[ -n "${app}" ]] || { rm -rf "${work}"; die "IPA has no Payload/*.app"; }

  local short build
  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app}/Info.plist" 2>/dev/null || true)"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${app}/Info.plist" 2>/dev/null || true)"
  echo "    Runner CFBundleShortVersionString=${short} CFBundleVersion=${build}"

  if [[ "${short}" != "${VERSION_NAME}" ]]; then
    warn "Runner short version '${short}' != pubspec ${VERSION_NAME}"
  else
    ok "Runner version matches pubspec (${VERSION_NAME})"
  fi
  if [[ "${build}" != "${VERSION_CODE}" ]]; then
    warn "Runner build '${build}' != pubspec build ${VERSION_CODE}"
  else
    ok "Runner build matches pubspec (${VERSION_CODE})"
  fi

  # ShareExtension is part of the iOS share-sheet flow (com.erebrus.drop.share).
  local appex
  appex="$(find "${app}/PlugIns" -maxdepth 1 -name '*.appex' 2>/dev/null | head -1 || true)"
  if [[ -n "${appex}" ]]; then
    local ext_short ext_build
    ext_short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${appex}/Info.plist" 2>/dev/null || true)"
    ext_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${appex}/Info.plist" 2>/dev/null || true)"
    echo "    ShareExtension CFBundleShortVersionString=${ext_short} CFBundleVersion=${ext_build}"
    if [[ "${ext_short}" == "${VERSION_NAME}" && "${ext_build}" == "${VERSION_CODE}" ]]; then
      ok "ShareExtension version matches pubspec"
    else
      warn "ShareExtension version ${ext_short}+${ext_build} should be ${VERSION_NAME}+${VERSION_CODE}"
    fi
  else
    warn "No PlugIns/*.appex found — ShareExtension may be missing from the IPA"
  fi

  rm -rf "${work}"
}

# ---------------------------------------------------------------------------
# macOS — .app ZIP for distribution; App Store uses Xcode Organizer archive
# ---------------------------------------------------------------------------

build_macos() {
  [[ "$(host_os)" == "macos" ]] || die "macOS builds require a Mac"

  info "macOS release .app"
  require_cmd xcodebuild

  python3 scripts/generate-desktop-assets.py
  local define_args
  define_args="$(dart_define_args)"
  # shellcheck disable=SC2086
  flutter build macos --release ${define_args}

  local app
  app="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' | head -1)"
  [[ -n "${app}" ]] || die "macOS .app not found under build/macos/Build/Products/Release"

  if [[ "${SKIP_VERIFY}" -eq 0 ]]; then
    verify_macos_app "${app}"
  fi

  local dest
  dest="$(artifact_path macos zip)"
  rm -f "${dest}"
  ditto -c -k --keepParent "${app}" "${dest}"
  ok "artifact → ${dest##${ROOT_DIR}/} ($(du -h "${dest}" | awk '{print $1}'))"
}

verify_macos_app() {
  local app="$1"
  info "Verifying macOS .app version metadata…"
  local plist="${app}/Contents/Info.plist"
  local short build
  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}" 2>/dev/null || true)"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${plist}" 2>/dev/null || true)"
  echo "    Runner CFBundleShortVersionString=${short} CFBundleVersion=${build}"
  if [[ "${short}" == "${VERSION_NAME}" && "${build}" == "${VERSION_CODE}" ]]; then
    ok "macOS Runner version matches pubspec (${VERSION_NAME}+${VERSION_CODE})"
  else
    warn "macOS Runner ${short}+${build} should be ${VERSION_NAME}+${VERSION_CODE}"
  fi
}

# ---------------------------------------------------------------------------
# Windows — native host only (Flutter cannot cross-compile Windows from macOS)
# ---------------------------------------------------------------------------

build_windows() {
  if [[ "$(host_os)" != "windows" ]]; then
    warn "Windows desktop builds require a Windows host (or GitHub Actions release.yml)."
    warn "Skipped: ${APP_NAME}-windows-${VERSION_TAG}.zip"
    warn "  On Windows:  ./scripts/build-desktop.sh windows"
    warn "  Then rename: dist/erebrus-drop-windows-${VERSION_TAG}.zip"
    warn "           →   dist/${APP_NAME}-windows-${VERSION_TAG}.zip"
    return 0
  fi

  info "Windows release bundle"
  python3 scripts/generate-desktop-assets.py
  local define_args
  define_args="$(dart_define_args)"
  # shellcheck disable=SC2086
  flutter build windows --release ${define_args}

  local runner_dir="${ROOT_DIR}/build/windows/x64/runner/Release"
  [[ -d "${runner_dir}" ]] || die "Windows Release folder missing: ${runner_dir}"

  local dest
  dest="$(artifact_path windows zip)"
  rm -f "${dest}"
  (cd "${runner_dir}" && zip -qr "${dest}" .)
  ok "artifact → ${dest##${ROOT_DIR}/} ($(du -h "${dest}" | awk '{print $1}'))"
}

# ---------------------------------------------------------------------------
# Ubuntu / Linux — native Linux, or Docker on macOS when available
# ---------------------------------------------------------------------------

build_ubuntu_native() {
  info "Ubuntu/Linux release bundle (native)"
  python3 scripts/generate-desktop-assets.py
  local define_args
  define_args="$(dart_define_args)"
  # shellcheck disable=SC2086
  flutter build linux --release ${define_args}

  local bundle
  bundle="$(find build/linux -maxdepth 3 -type d -name 'bundle' | head -1)"
  [[ -n "${bundle}" ]] || die "Linux bundle not found under build/linux"

  local dest
  dest="$(artifact_path ubuntu tar.gz)"
  rm -f "${dest}"
  tar -czf "${dest}" -C "$(dirname "${bundle}")" "$(basename "${bundle}")"
  ok "artifact → ${dest##${ROOT_DIR}/} ($(du -h "${dest}" | awk '{print $1}'))"
}

build_ubuntu_docker() {
  require_cmd docker
  info "Ubuntu/Linux release via Docker (cross-build from $(host_os))"

  # Use a stable Flutter Linux image; install GTK build deps inside.
  local image="${EREBRUS_LINUX_DOCKER_IMAGE:-ghcr.io/cirruslabs/flutter:stable}"
  info "docker pull ${image}"
  docker pull "${image}"

  docker run --rm \
    -v "${ROOT_DIR}:/app" \
    -w /app \
    "${image}" \
    bash -lc '
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev zip >/dev/null
      if [[ -f env.example && ! -f .env ]]; then cp env.example .env; fi
      flutter config --enable-linux-desktop
      flutter pub get
      python3 scripts/generate-desktop-assets.py || true
      DEFINE=""
      if [[ -f .env ]]; then DEFINE="--dart-define-from-file=/app/.env"; fi
      # shellcheck disable=SC2086
      flutter build linux --release ${DEFINE}
      BUNDLE="$(find build/linux -maxdepth 3 -type d -name bundle | head -1)"
      test -n "${BUNDLE}"
      VERSION_LINE="$(grep "^version:" pubspec.yaml | awk "{print \$2}")"
      VERSION_NAME="${VERSION_LINE%%+*}"
      DEST="dist/ErebrusDrop-ubuntu-v${VERSION_NAME}.tar.gz"
      mkdir -p dist
      rm -f "${DEST}"
      tar -czf "${DEST}" -C "$(dirname "${BUNDLE}")" "$(basename "${BUNDLE}")"
      echo "✓ docker artifact → ${DEST}"
      ls -lh "${DEST}"
    '
  local dest
  dest="$(artifact_path ubuntu tar.gz)"
  [[ -f "${dest}" ]] || die "Docker Linux build did not produce ${dest##${ROOT_DIR}/}"
  ok "artifact → ${dest##${ROOT_DIR}/} ($(du -h "${dest}" | awk '{print $1}'))"
}

build_ubuntu() {
  case "$(host_os)" in
    linux)
      build_ubuntu_native
      ;;
    macos|windows)
      if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        build_ubuntu_docker
      else
        warn "Ubuntu/Linux Flutter builds need a Linux host or a running Docker daemon."
        warn "Skipped: ${APP_NAME}-ubuntu-${VERSION_TAG}.tar.gz"
        warn "  Options:"
        warn "    1) Start Docker Desktop, re-run: ./scripts/build-all-release.sh ubuntu"
        warn "    2) On Ubuntu: ./scripts/build-desktop.sh linux"
        warn "    3) GitHub Actions: workflow_dispatch → Release"
      fi
      ;;
    *)
      warn "Unknown host — cannot build Ubuntu/Linux"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Upload instructions (printed after successful Apple builds)
# ---------------------------------------------------------------------------

print_apple_upload_steps() {
  cat <<EOF

══════════════════════════════════════════════════════════════════════════════
  TestFlight / App Store upload steps (iOS + macOS)
══════════════════════════════════════════════════════════════════════════════

Version: ${VERSION_NAME}+${VERSION_CODE}  (from pubspec.yaml)
Bundle:  com.erebrus.drop

── iOS (TestFlight / App Store) ──────────────────────────────────────────────

Artifact: dist/${APP_NAME}-ios-${VERSION_TAG}.ipa

Option A — Transporter (GUI, recommended for first upload)
  1. Open Transporter from the Mac App Store (or Xcode → Open Developer Tool).
  2. Sign in with the Apple ID that has App Store Connect access for
     com.erebrus.drop.
  3. Drag dist/${APP_NAME}-ios-${VERSION_TAG}.ipa into Transporter → Deliver.
  4. In App Store Connect → My Apps → Erebrus Drop → TestFlight, wait for
     processing, then add internal/external testers.

Option B — xcrun altool / notary-style upload (CLI)
  xcrun altool --upload-app --type ios \\
    --file "dist/${APP_NAME}-ios-${VERSION_TAG}.ipa" \\
    --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
  # Create an App Store Connect API key under Users and Access → Integrations.

Option C — Xcode Organizer
  1. open ios/Runner.xcworkspace
  2. Product → Destination → Any iOS Device
  3. Product → Archive
  4. Distribute App → App Store Connect → Upload
  5. Ensure both Runner (com.erebrus.drop) and ShareExtension
     (com.erebrus.drop.share) use App Store profiles with App Groups.

Verify before shipping:
  • CFBundleShortVersionString == ${VERSION_NAME}
  • CFBundleVersion == ${VERSION_CODE}
  • PlugIns/ShareExtension.appex is present and matches the same versions
  • Physical-device smoke-test for share-sheet intake + Drop Room hosting

── macOS (Mac App Store / optional notarized DMG) ────────────────────────────

ZIP artifact (sideload / GitHub): dist/${APP_NAME}-macos-${VERSION_TAG}.zip
  → Unzip and run Erebrus Drop.app locally. For store delivery use Archive:

Mac App Store path:
  1. open macos/Runner.xcworkspace
  2. Select scheme Runner, destination "Any Mac" (or "My Mac" then Archive)
  3. Product → Archive
  4. Distribute App → App Store Connect → Upload
  5. Runner (com.erebrus.drop) needs Mac App Store provisioning with the
     sandbox entitlements used by Drop (network client/server, user-selected
     files, app sandbox).
  6. App Store Connect → TestFlight (macOS) or submit for review.

Direct distribution (outside MAS) — notarize the .app:
  1. codesign --deep --force --options runtime \\
       --sign "Developer ID Application: <Your Team>" \\
       "path/to/Erebrus Drop.app"
  2. ditto -c -k --keepParent "Erebrus Drop.app" ErebrusDrop-submit.zip
  3. xcrun notarytool submit ErebrusDrop-submit.zip \\
       --apple-id <id> --team-id <TEAM_ID> --password <app-specific-password> \\
       --wait
  4. xcrun stapler staple "Erebrus Drop.app"

── Android (reminder) ────────────────────────────────────────────────────────

  Google Play AAB:
    dist/${APP_NAME}-android-playstore-${VERSION_TAG}.aab
    → Play Console → Production/Internal testing → Create release → upload AAB

  Solana dApp Store APK:
    dist/${APP_NAME}-android-dappstore-${VERSION_TAG}.apk
    → Submit via Solana dApp Store publisher tooling (signed with dappstore keystore)
    → See docs/solana-dapp-store-release.md

── Desktop sideload ──────────────────────────────────────────────────────────

  Windows: dist/${APP_NAME}-windows-${VERSION_TAG}.zip  (Windows host / CI)
  Ubuntu:  dist/${APP_NAME}-ubuntu-${VERSION_TAG}.tar.gz

══════════════════════════════════════════════════════════════════════════════
EOF
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
  echo
  echo "══════════════════════════════════════════════════════════════════════════════"
  echo "  Release artifacts (${VERSION_NAME}+${VERSION_CODE})"
  echo "══════════════════════════════════════════════════════════════════════════════"
  if compgen -G "${DIST_DIR}/${APP_NAME}-*-${VERSION_TAG}.*" >/dev/null; then
    ls -lh "${DIST_DIR}/${APP_NAME}"-*-"${VERSION_TAG}".* 2>/dev/null | awk '{print "  " $9 "  (" $5 ")"}'
  else
    echo "  (no matching artifacts in dist/)"
  fi
  echo "══════════════════════════════════════════════════════════════════════════════"
}

# ---------------------------------------------------------------------------
# Target selection
# ---------------------------------------------------------------------------

default_targets() {
  # Platforms this host can reasonably produce.
  case "$(host_os)" in
    macos)
      echo "android ios macos ubuntu windows"
      ;;
    linux)
      echo "android ubuntu"
      ;;
    windows)
      echo "android windows"
      ;;
    *)
      echo "android"
      ;;
  esac
}

list_targets() {
  cat <<EOF
Available targets (pass as args; default = all supported on this host):

  android              Google Play AAB + Solana dApp Store APK (keystore)
  android-playstore    Google Play App Bundle only
  android-dappstore    Solana dApp Store APK only
  ios                  IPA for TestFlight / App Store (macOS only)
  macos                .app ZIP + verification (macOS only)
  windows              Desktop ZIP (Windows host only; skipped elsewhere)
  ubuntu | linux       Linux/GTK tar.gz (native Linux or Docker)

Flags:
  --skip-tests         Skip flutter analyze + flutter test
  --skip-verify        Skip IPA / .app version checks
  --list               Show this help
  -h, --help           Show usage

This host ($(host_os)) default set: $(default_targets)
Naming: ${APP_NAME}-<platform>-vX.X.X.<ext>  (version from pubspec.yaml)
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage 0 ;;
      --list) list_targets; exit 0 ;;
      --skip-tests) SKIP_TESTS=1; shift ;;
      --skip-verify) SKIP_VERIFY=1; shift ;;
      android|android-playstore|android-dappstore|ios|macos|windows|ubuntu|linux|all)
        TARGETS+=("$1"); shift ;;
      *)
        die "Unknown argument: $1 (try --help)"
        ;;
    esac
  done

  read_version

  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    # shellcheck disable=SC2207
    TARGETS=($(default_targets))
  fi

  # Expand aliases
  local expanded=()
  for t in "${TARGETS[@]}"; do
    case "$t" in
      all) expanded+=($(default_targets)) ;;
      linux) expanded+=("ubuntu") ;;
      *) expanded+=("$t") ;;
    esac
  done
  TARGETS=("${expanded[@]}")

  # De-dupe while preserving order
  local seen="|" uniq=()
  for t in "${TARGETS[@]}"; do
    if [[ "${seen}" != *"|${t}|"* ]]; then
      uniq+=("$t")
      seen="${seen}${t}|"
    fi
  done
  TARGETS=("${uniq[@]}")

  preflight

  local built_apple=0
  for t in "${TARGETS[@]}"; do
    echo
    echo "────────── ${t} ──────────"
    case "$t" in
      android) build_android; ;;
      android-playstore) build_android_playstore; ;;
      android-dappstore) build_android_dappstore; ;;
      ios) build_ios; built_apple=1; ;;
      macos) build_macos; built_apple=1; ;;
      windows) build_windows; ;;
      ubuntu) build_ubuntu; ;;
      *) die "Unhandled target: $t" ;;
    esac
  done

  print_summary
  if [[ "${built_apple}" -eq 1 ]]; then
    print_apple_upload_steps
  fi
}

main "$@"
