#!/usr/bin/env bash
#
# Build / run wrapper that injects variables from .env as --dart-define flags.
#
# Usage:
#   scripts/build.sh run [flutter_run_args...]
#   scripts/build.sh build-apk [flutter_build_args...]
#   scripts/build.sh build-appbundle [flutter_build_args...]
#   scripts/build.sh build-ios [flutter_build_args...]
#   scripts/build.sh build-macos [flutter_build_args...]
#   scripts/build.sh build-windows [flutter_build_args...]
#   scripts/build.sh build-linux [flutter_build_args...]
#   scripts/build.sh build-web [flutter_build_args...]
#
# The wrapper passes --dart-define-from-file=.env to Flutter, which reads the
# .env file at compile time and makes every KEY=VALUE available via
# String.fromEnvironment. This keeps .env the single source of truth without a
# runtime dependency on flutter_dotenv.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

ENV_FILE="${ROOT_DIR}/.env"

print_usage() {
  cat <<EOF
Usage: scripts/build.sh <command> [flutter_args...]

Commands:
  run              flutter run
  build-apk        flutter build apk
  build-appbundle  flutter build appbundle
  build-ios        flutter build ios
  build-macos      flutter build macos
  build-windows    flutter build windows
  build-linux      flutter build linux
  build-web        flutter build web

Any trailing arguments are forwarded to the Flutter command.
EOF
}

COMMAND="${1:-}"
shift 2>/dev/null || true

# Build the Flutter argument list. Extra args from the command line come last
# so the user can override .env values with explicit --dart-define flags.
FLUTTER_ARGS=()
if [[ -f "${ENV_FILE}" ]]; then
  FLUTTER_ARGS+=("--dart-define-from-file=${ENV_FILE}")
fi
FLUTTER_ARGS+=("$@")

# Android has two product flavors (playstore, dappstore). `flutter run` picks
# playstore by default because dappstore debug variants are disabled, but
# `flutter build apk/appbundle` still requires an explicit --flavor. Default to
# playstore so the wrapper works without extra args.
ensure_android_flavor() {
  local arg
  for arg in "${FLUTTER_ARGS[@]}"; do
    if [[ "${arg}" == --flavor* ]]; then
      return
    fi
  done
  FLUTTER_ARGS+=("--flavor" "playstore")
}

# Dappstore debug builds are disabled (only release exists). If the user asks
# to run dappstore without an explicit --release or --profile, switch to release
# so `scripts/build.sh run --flavor dappstore` works.
ensure_dappstore_release_for_run() {
  local hasDappstore=false
  local hasBuildMode=false
  local expectFlavorValue=false
  local arg
  for arg in "${FLUTTER_ARGS[@]}"; do
    if [[ "${expectFlavorValue}" == true ]]; then
      if [[ "${arg}" == "dappstore" ]]; then
        hasDappstore=true
      fi
      expectFlavorValue=false
      continue
    fi
    case "${arg}" in
      --flavor=dappstore) hasDappstore=true ;;
      --flavor) expectFlavorValue=true ;;
      --release|--profile|--debug) hasBuildMode=true ;;
    esac
  done
  if [[ "${hasDappstore}" == true && "${hasBuildMode}" == false ]]; then
    echo "ℹ dappstore debug is disabled; switching run to --release." >&2
    FLUTTER_ARGS+=("--release")
  fi
}

case "${COMMAND}" in
  run)
    ensure_dappstore_release_for_run
    flutter run "${FLUTTER_ARGS[@]}"
    ;;
  build-apk)
    ensure_android_flavor
    flutter build apk "${FLUTTER_ARGS[@]}"
    ;;
  build-appbundle)
    ensure_android_flavor
    flutter build appbundle "${FLUTTER_ARGS[@]}"
    ;;
  build-ios)
    flutter build ios "${FLUTTER_ARGS[@]}"
    ;;
  build-macos)
    flutter build macos "${FLUTTER_ARGS[@]}"
    ;;
  build-windows)
    flutter build windows "${FLUTTER_ARGS[@]}"
    ;;
  build-linux)
    flutter build linux "${FLUTTER_ARGS[@]}"
    ;;
  build-web)
    flutter build web "${FLUTTER_ARGS[@]}"
    ;;
  *)
    print_usage
    exit 1
    ;;
esac
