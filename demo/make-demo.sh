#!/usr/bin/env bash
set -euo pipefail

# make-demo.sh — Regenerate the DevJournal demo GIF from the VHS tape file.
#
# Usage: ./make-demo.sh [output-name]
#   output-name  Optional. Defaults to "demo.gif".
#
# Cleans up previous GIFs and devjournal artifacts before and after rendering.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAPE_FILE="$SCRIPT_DIR/devjournal-demo.tape"
OUTPUT="${1:-demo.gif}"
JOURNAL_DIR="$SCRIPT_DIR/journal"

# Guarantee cleanup of devjournal artifacts on exit (success, failure, or signal).
cleanup() {
  if [[ -d "$JOURNAL_DIR" ]]; then
    echo "Cleaning up journal: $JOURNAL_DIR"
    rm -rf "$JOURNAL_DIR"
  fi
  # .devjournal.toml is created by 'devjournal init' in the CWD (the tape's CWD).
  local devjournal_toml="$SCRIPT_DIR/.devjournal.toml"
  if [[ -f "$devjournal_toml" ]]; then
    echo "Cleaning up $devjournal_toml"
    rm -f "$devjournal_toml"
  fi
}
trap cleanup EXIT

# ── Dependency check ──────────────────────────────────────
missing=()
for cmd in vhs devjournal tree jq; do
  if ! command -v "$cmd" &>/dev/null; then
    missing+=("$cmd")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Error: required commands not found: ${missing[*]}" >&2
  echo "" >&2
  echo "Install them:" >&2
  [[ " ${missing[*]} " == *" vhs "* ]] && echo "  brew install vhs" >&2
  [[ " ${missing[*]} " == *" devjournal "* ]] && echo "  cd ~/Documents/GitHub/DevJournal && zig build install-local" >&2
  [[ " ${missing[*]} " == *" tree "* ]] && echo "  brew install tree" >&2
  [[ " ${missing[*]} " == *" jq "* ]] && echo "  brew install jq" >&2
  exit 1
fi

if [[ ! -f "$TAPE_FILE" ]]; then
  echo "Error: tape file not found: $TAPE_FILE" >&2
  exit 1
fi

# ── Clean up previous outputs ─────────────────────────────
echo "Cleaning up previous GIFs and artifacts..."
rm -f "$SCRIPT_DIR/demo.gif" "$SCRIPT_DIR/devjournal-demo.gif" "$SCRIPT_DIR/$OUTPUT"
rm -f "$SCRIPT_DIR/.devjournal.toml"
rm -rf "$JOURNAL_DIR"

# ── Render ────────────────────────────────────────────────
echo "Rendering $TAPE_FILE → $OUTPUT"
cd "$SCRIPT_DIR"
vhs "$TAPE_FILE"

# If the tape produced a file with a different name than requested, rename it.
if [[ "$OUTPUT" != "demo.gif" && -f "$SCRIPT_DIR/demo.gif" ]]; then
  mv "$SCRIPT_DIR/demo.gif" "$SCRIPT_DIR/$OUTPUT"
fi

# Verify the output was created.
if [[ ! -s "$SCRIPT_DIR/$OUTPUT" ]]; then
  echo "Error: $OUTPUT was not created or is empty" >&2
  exit 1
fi

echo "Done: $SCRIPT_DIR/$OUTPUT"
