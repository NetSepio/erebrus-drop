#!/usr/bin/env bash
# One-shot macOS desktop dev setup for Erebrus Drop.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

flutter pub get
echo "Run: flutter run -d macos"