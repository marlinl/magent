#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="$ROOT_DIR/.swift-format"
SOURCE_PATHS=(
  "$ROOT_DIR/MagentX"
  "$ROOT_DIR/MagentXTests"
  "$ROOT_DIR/MagentXUITests"
)

usage() {
  echo "usage: $0 [--check]" >&2
}

case "${1:-}" in
  "")
    /usr/bin/xcrun swift format format \
      --configuration "$CONFIG_PATH" \
      --recursive \
      --parallel \
      --in-place \
      "${SOURCE_PATHS[@]}"
    ;;
  --check)
    ;;
  *)
    usage
    exit 2
    ;;
esac

/usr/bin/xcrun swift format lint \
  --configuration "$CONFIG_PATH" \
  --recursive \
  --parallel \
  --strict \
  "${SOURCE_PATHS[@]}"
