#!/bin/bash
# session-snapshot CLI — install plugin, manage wrapper
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PLUGIN_SRC="$REPO_DIR/src/snapshot.ts"
CONFIG_DIR="$HOME/.config/session-snapshot"
SNAPSHOTS_DIR="$CONFIG_DIR/snapshots"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'

info()  { echo -e "${CYAN}[session-snapshot]${NC} $1"; }
ok()    { echo -e "${GREEN}  ✓${NC} $1"; }
fail()  { echo -e "${RED}  ✗${NC} $1"; }
warn()  { echo -e "${YELLOW}  !${NC} $1"; }

# ── install ───────────────────────────────────────────────────
cmd_install() {
  echo ""
  echo -e "${BOLD}session-snapshot — install${NC}"
  echo ""

  # Check Node.js 22+
  NODE_VER=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
  if [ -z "$NODE_VER" ] || [ "$NODE_VER" -lt 22 ]; then
    fail "Node.js 22+ required (got: $(node --version 2>/dev/null || echo 'not found'))"
    exit 1
  fi
  ok "Node.js $(node --version)"

  # Create config dirs
  mkdir -p "$SNAPSHOTS_DIR"
  ok "Config directory: $CONFIG_DIR"

  # Check if claude-hooks is installed
  HOOKS_PLUGINS="$HOME/.config/claude-hooks/plugins"
  if [ -d "$HOOKS_PLUGINS" ]; then
    # Install via claude-hooks
    DEST="$HOOKS_PLUGINS/PostToolUse/snapshot.ts"
    ln -sf "$PLUGIN_SRC" "$DEST"
    ok "Plugin installed: PostToolUse/snapshot.ts"
  else
    warn "claude-hooks not found — installing plugin manually"
    # Fallback: register directly in settings.json
    SETTINGS="$HOME/.claude/settings.json"
    if [ ! -f "$SETTINGS" ]; then
      echo '{}' > "$SETTINGS"
    fi

    NODE_CMD="node --experimental-strip-types"
    node -e "
const fs = require('fs');
const settings = JSON.parse(fs.readFileSync('$SETTINGS', 'utf-8'));
if (!settings.hooks) settings.hooks = {};
if (!settings.hooks.PostToolUse) settings.hooks.PostToolUse = [];

// Remove old session-snapshot entries
for (const group of settings.hooks.PostToolUse) {
  if (group.hooks) {
    group.hooks = group.hooks.filter(h => !h.command?.includes('session-snapshot'));
  }
}

// Add to matcher '.*' group
let group = settings.hooks.PostToolUse.find(g => g.matcher === '.*');
if (!group) {
  group = { matcher: '.*', hooks: [] };
  settings.hooks.PostToolUse.push(group);
}
if (!group.hooks) group.hooks = [];

group.hooks.push({
  type: 'command',
  command: '${NODE_CMD} ${PLUGIN_SRC}',
  timeout: 10000
});

fs.writeFileSync('$SETTINGS', JSON.stringify(settings, null, 2) + '\n');
"
    ok "Plugin registered in settings.json (standalone mode)"
  fi

  # Install wrapper
  WRAPPER_DEST="$HOME/.local/bin/cclaude"
  mkdir -p "$HOME/.local/bin"
  cp "$REPO_DIR/bin/cclaude.sh" "$WRAPPER_DEST"
  chmod +x "$WRAPPER_DEST"
  ok "Wrapper installed: $WRAPPER_DEST"

  # Check PATH
  if echo "$PATH" | grep -q "$HOME/.local/bin"; then
    ok "~/.local/bin is in PATH"
  else
    warn "~/.local/bin is NOT in your PATH — add it to your shell profile"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi

  echo ""
  echo -e "${GREEN}${BOLD}Installed!${NC} Restart Claude Code to activate."
  echo ""
  echo "  Usage:"
  echo "    cclaude --dangerously-skip-permissions     — launch with auto-restore"
  echo "    session-snapshot status                     — show snapshot info"
  echo "    session-snapshot clean                      — remove old snapshots"
  echo ""
}

# ── uninstall ─────────────────────────────────────────────────
cmd_uninstall() {
  echo ""
  echo -e "${BOLD}session-snapshot — uninstall${NC}"
  echo ""

  # Remove from claude-hooks
  HOOKS_PLUGIN="$HOME/.config/claude-hooks/plugins/PostToolUse/snapshot.ts"
  if [ -f "$HOOKS_PLUGIN" ]; then
    rm "$HOOKS_PLUGIN"
    ok "Plugin removed from claude-hooks"
  fi

  # Remove from settings.json (standalone mode)
  SETTINGS="$HOME/.claude/settings.json"
  if [ -f "$SETTINGS" ] && grep -q "session-snapshot" "$SETTINGS"; then
    node -e "
const fs = require('fs');
const settings = JSON.parse(fs.readFileSync('$SETTINGS', 'utf-8'));
if (settings.hooks?.PostToolUse) {
  for (const group of settings.hooks.PostToolUse) {
    if (group.hooks) {
      group.hooks = group.hooks.filter(h => !h.command?.includes('session-snapshot'));
    }
  }
}
fs.writeFileSync('$SETTINGS', JSON.stringify(settings, null, 2) + '\n');
"
    ok "Plugin removed from settings.json"
  fi

  # Remove wrapper
  if [ -f "$HOME/.local/bin/cclaude" ]; then
    rm "$HOME/.local/bin/cclaude"
    ok "Wrapper removed"
  fi

  echo ""
  echo "  Snapshots are still in: $SNAPSHOTS_DIR"
  echo "  To remove everything: rm -rf $CONFIG_DIR"
  echo ""
}

# ── status ────────────────────────────────────────────────────
cmd_status() {
  echo ""
  echo -e "${BOLD}session-snapshot — status${NC}"
  echo ""

  # Check plugin installation
  HOOKS_PLUGIN="$HOME/.config/claude-hooks/plugins/PostToolUse/snapshot.ts"
  if [ -f "$HOOKS_PLUGIN" ]; then
    ok "Plugin: installed (claude-hooks)"
  elif [ -f "$HOME/.claude/settings.json" ] && grep -q "session-snapshot" "$HOME/.claude/settings.json"; then
    ok "Plugin: installed (standalone)"
  else
    fail "Plugin: not installed"
  fi

  # Check wrapper
  if command -v cclaude &>/dev/null; then
    ok "Wrapper: available ($(which cclaude))"
  else
    warn "Wrapper: not in PATH"
  fi

  # Show snapshots
  if [ -d "$SNAPSHOTS_DIR" ]; then
    local count=$(ls "$SNAPSHOTS_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
    ok "Snapshots: $count session(s)"

    if [ -f "$SNAPSHOTS_DIR/latest.json" ]; then
      local sid=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$SNAPSHOTS_DIR/latest.json','utf-8')).sessionId.slice(0,8))" 2>/dev/null)
      local size=$(node -e "console.log((JSON.parse(require('fs').readFileSync('$SNAPSHOTS_DIR/latest.json','utf-8')).snapshotSize/1024).toFixed(0))" 2>/dev/null)
      echo -e "    Latest: ${sid}... (${size}KB)"
    fi

    # Show individual snapshots
    for state in "$SNAPSHOTS_DIR"/*.state.json; do
      [ -f "$state" ] || continue
      local sid=$(node -e "const s=JSON.parse(require('fs').readFileSync('$state','utf-8'));console.log(s.sessionId.slice(0,8)+'... ('+s.snapshotCount+' snapshots, '+(s.lastSnapshotSize/1024).toFixed(0)+'KB)')" 2>/dev/null)
      echo -e "    ${DIM}$sid${NC}"
    done
  else
    warn "No snapshots directory"
  fi
  echo ""
}

# ── clean ─────────────────────────────────────────────────────
cmd_clean() {
  echo ""
  echo -e "${BOLD}session-snapshot — clean${NC}"
  echo ""

  if [ ! -d "$SNAPSHOTS_DIR" ]; then
    info "Nothing to clean."
    echo ""
    return
  fi

  local count=0
  for f in "$SNAPSHOTS_DIR"/*.jsonl "$SNAPSHOTS_DIR"/*.state.json; do
    [ -f "$f" ] || continue
    rm "$f"
    count=$((count + 1))
  done
  rm -f "$SNAPSHOTS_DIR/latest.json"

  ok "Removed $count file(s)"
  echo ""
}

# ── test ──────────────────────────────────────────────────────
cmd_test() {
  echo ""
  echo -e "${BOLD}session-snapshot — self-test${NC}"
  echo ""

  local PASS=0 TOTAL=0

  check() {
    TOTAL=$((TOTAL + 1))
    if eval "$1" &>/dev/null; then
      ok "$2"
      PASS=$((PASS + 1))
    else
      fail "$2"
    fi
  }

  # Plugin check
  check "[ -f '$HOME/.config/claude-hooks/plugins/PostToolUse/snapshot.ts' ] || ([ -f '$HOME/.claude/settings.json' ] && grep -q 'session-snapshot' '$HOME/.claude/settings.json')" "Plugin installed"

  # Config dir
  check "[ -d '$CONFIG_DIR' ]" "Config directory exists"
  check "[ -d '$SNAPSHOTS_DIR' ]" "Snapshots directory exists"

  # Wrapper
  check "[ -f '$HOME/.local/bin/cclaude' ] || command -v cclaude" "Wrapper available"

  # Test snapshot module loads
  TOTAL=$((TOTAL + 1))
  RESULT=$(node --experimental-strip-types -e "
    import { maybeSnapshot } from '$PLUGIN_SRC';
    console.log(typeof maybeSnapshot === 'function' ? 'OK' : 'FAIL');
  " 2>&1)
  if echo "$RESULT" | grep -q "OK"; then
    ok "Snapshot module loads correctly"
    PASS=$((PASS + 1))
  else
    fail "Snapshot module failed to load: $RESULT"
  fi

  # Test path discovery
  TOTAL=$((TOTAL + 1))
  RESULT=$(node --experimental-strip-types -e "
    import { findSessionJsonl, paths } from '$REPO_DIR/src/claude-paths.ts';
    console.log(typeof findSessionJsonl === 'function' && paths.snapshotsDir ? 'OK' : 'FAIL');
  " 2>&1)
  if echo "$RESULT" | grep -q "OK"; then
    ok "Path discovery module loads correctly"
    PASS=$((PASS + 1))
  else
    fail "Path discovery module failed: $RESULT"
  fi

  echo ""
  if [ "$PASS" -eq "$TOTAL" ]; then
    echo -e "  ${GREEN}${BOLD}All $TOTAL checks passed${NC}"
  else
    echo -e "  ${YELLOW}${BOLD}$PASS/$TOTAL checks passed${NC}"
  fi
  echo ""
}

# ── help ──────────────────────────────────────────────────────
cmd_help() {
  echo ""
  echo -e "${BOLD}session-snapshot${NC} — rolling JSONL snapshots for Claude Code"
  echo ""
  echo "  Auto-saves session state so context overload is recoverable."
  echo ""
  echo "  Usage: session-snapshot <command>"
  echo ""
  echo "  Setup:"
  echo "    install           Install plugin + wrapper"
  echo "    uninstall         Remove plugin + wrapper"
  echo ""
  echo "  Info:"
  echo "    status            Show snapshot info"
  echo "    clean             Remove all snapshots"
  echo "    test              Run self-test"
  echo ""
  echo "  Wrapper:"
  echo "    Use ${BOLD}cclaude${NC} instead of ${BOLD}claude${NC} to enable auto-restore."
  echo "    cclaude --dangerously-skip-permissions"
  echo ""
}

# ── main ──────────────────────────────────────────────────────
COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  clean)     cmd_clean ;;
  test)      cmd_test ;;
  help|--help|-h) cmd_help ;;
  *)
    fail "Unknown command: $COMMAND"
    cmd_help
    exit 1
    ;;
esac
