#!/usr/bin/env bash
#
# Writes .env for CI builds from environment variables of the same name.
# scripts/build.sh then passes it to Flutter as --dart-define-from-file.
#
# Only non-empty values are written: an empty KEY= line would override the
# app's compile-time default (e.g. APPLE_REDIRECT_URI) with an empty string.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

KEYS=(
  REOWN_PROJECT_ID
  GATEWAY_URL
  IPFS_GATEWAY_URL
  GOOGLE_SERVER_CLIENT_ID
  APPLE_SERVICE_ID
  APPLE_REDIRECT_URI
  EREBRUS_WEB_ORIGIN
  REDDIT_CLIENT_ID
)

umask 077
: > "${ENV_FILE}"
written=()
for key in "${KEYS[@]}"; do
  value="${!key:-}"
  if [[ -n "${value}" ]]; then
    printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
    written+=("${key}")
  fi
done
echo "Wrote .env with: ${written[*]:-(no values)}"
