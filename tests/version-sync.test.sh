#!/bin/bash
# Release-sweep guard (plain bash, no harness): every public version surface
# must agree. Catches the 0.4.0 regression where plugin.json and the README
# badge were bumped but the marketplace catalog entry was not.
# Surfaces checked:
#   (i)   .claude-plugin/plugin.json        — top-level "version"
#   (ii)  .claude-plugin/marketplace.json   — plugins[0].version
#   (iii) README.md                         — shields.io version badge
#
# Run: bash tests/version-sync.test.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."

PASS=0
FAIL=0
ok()   { echo "ok   - $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

json_version() {
  # json_version <file> — first "version" value at/after line 1; for
  # marketplace.json the metadata.version is skipped by scoping to "plugins".
  grep -m1 '"version"' "$1" | sed 's/.*"version"[^"]*"\([^"]*\)".*/\1/'
}

PLUGIN_VER="$(json_version "$ROOT/.claude-plugin/plugin.json")"
# marketplace.json carries two "version" keys (metadata + plugin entry);
# take the first one inside the "plugins" array.
MARKET_VER="$(sed -n '/"plugins"/,$p' "$ROOT/.claude-plugin/marketplace.json" \
  | grep -m1 '"version"' | sed 's/.*"version"[^"]*"\([^"]*\)".*/\1/')"
BADGE_VER="$(grep -m1 -o 'badge/version-[0-9][0-9.]*-' "$ROOT/README.md" \
  | sed 's|badge/version-||; s/-$//')"

case "$PLUGIN_VER" in
  [0-9]*.[0-9]*.[0-9]*) ok "plugin.json version is semver-shaped ($PLUGIN_VER)" ;;
  *) fail "plugin.json version is semver-shaped (got: '$PLUGIN_VER')" ;;
esac

if [ -n "$MARKET_VER" ] && [ "$MARKET_VER" = "$PLUGIN_VER" ]; then
  ok "marketplace plugin entry matches plugin.json ($MARKET_VER)"
else
  fail "marketplace plugin entry matches plugin.json (plugin=$PLUGIN_VER marketplace=$MARKET_VER)"
fi

if [ -n "$BADGE_VER" ] && [ "$BADGE_VER" = "$PLUGIN_VER" ]; then
  ok "README version badge matches plugin.json ($BADGE_VER)"
else
  fail "README version badge matches plugin.json (plugin=$PLUGIN_VER badge=$BADGE_VER)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
