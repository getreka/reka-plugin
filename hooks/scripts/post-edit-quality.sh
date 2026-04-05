#!/bin/bash
# PostToolUse hook: Auto-format with prettier and type-check TypeScript.
# Reads edited file path from stdin JSON (tool_input.file_path).
# Auto-detects project root via tsconfig.json for tsc.
# Dependencies: none required (npx/prettier/tsc are optional, jq has fallback)

INPUT=$(cat)

# Parse file_path: try jq first, fallback to pure shell
if command -v jq &>/dev/null; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")
else
  # Shell-only fallback: extract file_path from JSON without jq
  FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi

if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

# Run prettier if npx is available
if command -v npx &>/dev/null; then
  npx prettier --write "$FILE_PATH" 2>/dev/null || true
fi

# TypeScript check: only for .ts files, only if tsc is available
case "$FILE_PATH" in
  *.ts)
    if ! command -v npx &>/dev/null; then
      exit 0
    fi
    # Walk up to find the nearest tsconfig.json
    DIR=$(dirname "$FILE_PATH")
    while [ "$DIR" != "/" ]; do
      if [ -f "$DIR/tsconfig.json" ]; then
        (cd "$DIR" && npx tsc --noEmit --pretty 2>&1 | head -20)
        break
      fi
      DIR=$(dirname "$DIR")
    done
    ;;
esac

exit 0
