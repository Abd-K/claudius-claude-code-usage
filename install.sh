#!/bin/zsh
# One-step install: the claude-usage backend into ~/.local/bin and Claudius into
# /Applications, then (re)launch it. Safe to re-run to upgrade.
set -euo pipefail
DIR="${0:A:h}"

command -v swiftc >/dev/null || { echo "Needs the Xcode command-line tools: xcode-select --install"; exit 1; }
command -v python3 >/dev/null || { echo "Needs python3"; exit 1; }
command -v claude >/dev/null || [ -x ~/.local/bin/claude ] \
  || echo "Note: Claude Code isn't on your PATH — Claudius reads the sign-in it stores."

mkdir -p ~/.local/bin
install -m 0755 "$DIR/claude-usage" ~/.local/bin/claude-usage
"$DIR/build.sh"
pkill -x Claudius 2>/dev/null || true
open /Applications/Claudius.app
echo "Claudius is running — look for it in your menu bar."
