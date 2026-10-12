#!/bin/zsh
# Render the README screenshots from fixed demo data — no live usage, no real
# session names. Usage: scripts/snapshot.sh [out-dir]   (default: docs/)
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="${1:-$ROOT/docs}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The app's sources, minus the entry point — the snapshot tool brings its own.
for f in "$ROOT"/Sources/*.swift; do
  sed '/^@main$/d' "$f" > "$WORK/${f:t}"
done
cp "$ROOT/scripts/snapshot.swift" "$WORK/"
swiftc -parse-as-library -o "$WORK/snapshot" "$WORK"/*.swift
mkdir -p "$OUT"
"$WORK/snapshot" "$OUT" "$ROOT/AppIcon.icns"
