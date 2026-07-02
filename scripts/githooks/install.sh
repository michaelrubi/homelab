#!/usr/bin/env bash
# Install/refresh Git hooks from this directory into .git/hooks/.
# Run after cloning, or after pulling new hooks. Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-.git/hooks}"
mkdir -p "$DEST"
for f in "$HERE"/*; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  # Don't install this installer script itself as a hook.
  if [ "$name" = "install.sh" ]; then
    continue
  fi
  cp -f "$f" "$DEST/$name"
  chmod +x "$DEST/$name"
  echo "installed $DEST/$name"
done
