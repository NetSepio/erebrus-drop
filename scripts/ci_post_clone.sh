#!/bin/sh
# Thin wrapper — Xcode Cloud runs ios/ci_scripts/ci_post_clone.sh.
# This path is kept so docs / manual invocation still work.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec sh "${ROOT}/ios/ci_scripts/ci_post_clone.sh"
