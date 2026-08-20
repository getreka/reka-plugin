#!/bin/bash
# Tests for the SessionEnd memory-file sync block (ADR-006 Phase 1 step 2):
#   (1) default OFF -> no /api/memory-files traffic at all
#   (2) opt-in -> manifest fetched, new file POSTed with slug+sha256+content
#   (3) file whose hash matches the server manifest is skipped
#   (4) client-side redaction applied to the shipped content
#   (5) prompt-recall body carries the minScore relevance floor
# Run: bash tests/memory-sync.test.sh (requires jq, sha256sum)

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SE="$SCRIPT_DIR/../hooks/scripts/session-end.sh"
PR="$SCRIPT_DIR/../hooks/scripts/prompt-recall.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP - jq not available"; exit 0; }
command -v sha256sum >/dev/null 2>&1 || { echo "SKIP - sha256sum not available"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { echo "ok   - $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'SHIM'
#!/bin/bash
args="$*"
echo "$args" >> "${MOCK_LOG:?}"
# capture POST bodies (--data-binary @- reads stdin)
case "$args" in
  *"--data-binary"*) cat >> "${MOCK_BODIES:?}"; echo >> "$MOCK_BODIES" ;;
esac
url=""; for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */api/memory-files/sync*) printf '%s' '{"synced":1}' ;;
  */api/memory-files*) printf '%s' "${MOCK_MANIFEST:-{\"files\":[]}}" ;;
  */api/session/*/end*) printf '%s' '{"ok":true}' ;;
  */api/memory/recall*) printf '%s' '{"results":[]}' ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$TMP/bin/curl"

# Project layout: transcript + sibling memory dir (mirrors ~/.claude/projects/<p>/)
mkdir -p "$TMP/proj"
cat > "$TMP/proj/.mcp.json" <<'J'
{"mcpServers":{"a":{"env":{"REKA_API_KEY":"rk_projA_aaaa00","RAG_API_URL":"http://mock-a:3100"}}}}
J
mkdir -p "$TMP/cc/memory"
: > "$TMP/cc/transcript.jsonl"
cat > "$TMP/cc/memory/or-1234.md" <<'M'
---
name: or-1234
description: GC bus facts
---
staging login admin password: S3cretStaging1
phone 380951484847
M

run_se() { # run_se [env VAR=VAL ...]
  printf '{"session_id":"cc-sync","transcript_path":"%s"}' "$TMP/cc/transcript.jsonl" \
    | env PATH="$TMP/bin:$PATH" MOCK_LOG="$MOCK_LOG" MOCK_BODIES="$MOCK_BODIES" \
        CLAUDE_PROJECT_DIR="$TMP/proj" RAG_STATE_DIR="$STATE" REKA_TRANSCRIPT_CAPTURE=0 \
        "$@" bash "$SE" >/dev/null 2>&1
}

# ── (1) default OFF ─────────────────────────────────────────────────────────
STATE="$(mktemp -d)"; MOCK_LOG="$TMP/log1"; MOCK_BODIES="$TMP/bodies1"; : > "$MOCK_LOG"; : > "$MOCK_BODIES"
run_se
if ! grep -q 'memory-files' "$MOCK_LOG"; then ok "(1) sync is opt-in: no memory-files traffic by default"; else fail "(1) default OFF violated: $(grep memory-files "$MOCK_LOG" | head -1)"; fi

# ── (2) opt-in pushes the new file ──────────────────────────────────────────
STATE="$(mktemp -d)"; MOCK_LOG="$TMP/log2"; MOCK_BODIES="$TMP/bodies2"; : > "$MOCK_LOG"; : > "$MOCK_BODIES"
run_se REKA_MEMORY_SYNC=1
grep -q 'GET\|/api/memory-files ' "$MOCK_LOG" 2>/dev/null || true
if grep -q '/api/memory-files/sync' "$MOCK_LOG"; then ok "(2a) sync POSTed"; else fail "(2a) sync POSTed ($(cat "$MOCK_LOG"))"; fi
HASH="$(sha256sum "$TMP/cc/memory/or-1234.md" | cut -d' ' -f1)"
if jq -e --arg h "$HASH" '.files[0] | select(.slug=="or-1234.md" and .hash==$h)' "$MOCK_BODIES" >/dev/null 2>&1; then
  ok "(2b) body carries slug + sha256 of the raw file"
else
  fail "(2b) body carries slug + sha256 (got: $(head -c 200 "$MOCK_BODIES"))"
fi

# ── (3) unchanged file skipped via manifest ─────────────────────────────────
STATE="$(mktemp -d)"; MOCK_LOG="$TMP/log3"; MOCK_BODIES="$TMP/bodies3"; : > "$MOCK_LOG"; : > "$MOCK_BODIES"
run_se REKA_MEMORY_SYNC=1 MOCK_MANIFEST="{\"files\":[{\"slug\":\"or-1234.md\",\"hash\":\"$HASH\"}]}"
if ! grep -q '/api/memory-files/sync' "$MOCK_LOG"; then ok "(3) unchanged file skipped"; else fail "(3) unchanged file skipped"; fi

# ── (4) redaction applied to shipped content ────────────────────────────────
if grep -q 'S3cretStaging1' "$TMP/bodies2"; then fail "(4) password leaked in body"; else ok "(4) password redacted before egress"; fi
if grep -q '380951484847' "$TMP/bodies2"; then fail "(4b) phone leaked in body"; else ok "(4b) phone masked before egress"; fi
if jq -e '.files[0].content | contains("<redacted>")' "$TMP/bodies2" >/dev/null 2>&1; then ok "(4c) redaction marker present"; else fail "(4c) redaction marker present"; fi

# ── (5) prompt-recall sends the relevance floor ─────────────────────────────
STATE="$(mktemp -d)"; MOCK_LOG="$TMP/log5"; MOCK_BODIES="$TMP/bodies5"; : > "$MOCK_LOG"; : > "$MOCK_BODIES"
jq -nc '{prompt:"розберись чому пошук сервісних точок повертає порожньо",session_id:"cc-ms"}' \
  | env PATH="$TMP/bin:$PATH" MOCK_LOG="$MOCK_LOG" MOCK_BODIES="$MOCK_BODIES" \
      CLAUDE_PROJECT_DIR="$TMP/proj" RAG_STATE_DIR="$STATE" \
      bash "$PR" >/dev/null 2>&1
if grep -q '"minScore":0.65' "$MOCK_LOG"; then ok "(5) recall body carries minScore 0.65"; else fail "(5) minScore in recall body ($(grep recall "$MOCK_LOG" | head -1))"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
