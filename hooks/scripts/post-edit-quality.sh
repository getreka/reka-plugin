#!/bin/bash
# PostToolUse hook: Auto-format with prettier and type-check TypeScript.
# Reads edited file path from stdin JSON (tool_input.file_path).
# Auto-detects project root via tsconfig.json for tsc.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")

if [[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]]; then
  exit 0
fi

# Run prettier if available
npx prettier --write "$FILE_PATH" 2>/dev/null || true

# TypeScript check: only for .ts files, only if tsconfig.json exists
if [[ "$FILE_PATH" == *.ts ]]; then
  # Walk up to find the nearest tsconfig.json
  DIR=$(dirname "$FILE_PATH")
  while [[ "$DIR" != "/" ]]; do
    if [[ -f "$DIR/tsconfig.json" ]]; then
      cd "$DIR" && npx tsc --noEmit --pretty 2>&1 | head -20
      break
    fi
    DIR=$(dirname "$DIR")
  done
fi

exit 0
