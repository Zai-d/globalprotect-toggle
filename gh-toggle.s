#!/bin/bash
# Compatibility wrapper for gp-toggle.sh.
# This repo now uses the canonical file name gp-toggle.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/gp-toggle.sh"

if [[ ! -f "$TARGET" ]]; then
  echo "Missing $TARGET" >&2
  exit 1
fi

exec "$TARGET" "$@"
