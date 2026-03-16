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

HOOKS_DIR="$HOME/.config/claude-hooks"
HOOKS_REGISTRY="$HOOKS_DIR/registry.json"
HOOKS_VALIDATE="$HOOKS_DIR/validate-hooks.ts"
PROJECT_NAME="session-snapshot"
SHELL_MARKER="# session-snapshot: transparent wrapper"

# ── registry helpers ─────────────────────────────────────────
_register_hook() {
  local key="$1"   # e.g. "PostToolUse/snapshot.ts"
  local source="$2" # e.g. "/path/to/src/snapshot.ts"

  # Ensure registry exists
  if [ ! -f "$HOOKS_REGISTRY" ]; then
    echo '{"version":1,"plugins":{}}' > "$HOOKS_REGISTRY"
  fi

  node -e "
const fs = require('fs');
const reg = JSON.parse(fs.readFileSync('$HOOKS_REGISTRY', 'utf-8'));
reg.plugins['$key'] = {
  project: '$PROJECT_NAME',
  repo: '$REPO_DIR',
  source: '$source',
  installed: new Date().toISOString()
};
fs.writeFileSync('$HOOKS_REGISTRY', JSON.stringify(reg, null, 2) + '\n');
"
}

_unregister_hook() {
  local key="$1"
  [ -f "$HOOKS_REGISTRY" ] || return 0
  node -e "
const fs = require('fs');
const reg = JSON.parse(fs.readFileSync('$HOOKS_REGISTRY', 'utf-8'));
delete reg.plugins['$key'];
fs.writeFileSync('$HOOKS_REGISTRY', JSON.stringify(reg, null, 2) + '\n');
"
}

_validate_all_hooks() {
  if [ -f "$HOOKS_VALIDATE" ]; then
    node --experimental-strip-types "$HOOKS_VALIDATE" "$@"
  else
    warn "validate-hooks.ts not found — skipping hook validation"
  fi
}

_detect_shell_rc() {
  if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-bash}")" = "zsh" ]; then
    echo "$HOME/.zshrc"
  else
    echo "$HOME/.bashrc"
  fi
}

_install_shell_function() {
  local rc
  rc="$(_detect_shell_rc)"

  # Already installed?
  if [ -f "$rc" ] && grep -qF "$SHELL_MARKER" "$rc"; then
    ok "Shell function already in $(basename "$rc")"
    return
  fi

  cat >> "$rc" << 'FUNC'

# session-snapshot: transparent wrapper
# Routes `claude` through cclaude for auto-restore on context overload
claude() { command cclaude "$@"; }
FUNC

  ok "Shell function added to $(basename "$rc") — claude() → cclaude"
}

_remove_shell_function() {
  local rc
  rc="$(_detect_shell_rc)"

  if [ ! -f "$rc" ] || ! grep -qF "$SHELL_MARKER" "$rc"; then
    return
  fi

  # Remove the block (marker + comment + function + blank line before)
  local tmp="$rc.session-snapshot-bak"
  awk -v marker="$SHELL_MARKER" '
    BEGIN { skip=0 }
    $0 ~ marker { skip=1; next }
    skip && /^# Routes .* cclaude/ { next }
    skip && /^claude\(\)/ { skip=0; next }
    { skip=0; print }
  ' "$rc" > "$tmp" && mv "$tmp" "$rc"

  ok "Shell function removed from $(basename "$rc")"
}

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
  mkdir -p "$CONFIG_DIR/md"
  ok "Config directory: $CONFIG_DIR"

  # Create default config if missing
  if [ ! -f "$CONFIG_DIR/config.json" ]; then
    cat > "$CONFIG_DIR/config.json" << EOF
{
  "mdDir": "$CONFIG_DIR/md"
}
EOF
    ok "Config file created: $CONFIG_DIR/config.json"
  else
    ok "Config file exists"
  fi

  # Check if claude-hooks is installed
  HOOKS_PLUGINS="$HOME/.config/claude-hooks/plugins"
  if [ -d "$HOOKS_PLUGINS" ]; then
    # Install via claude-hooks
    DEST="$HOOKS_PLUGINS/PostToolUse/snapshot.ts"
    ln -sf "$PLUGIN_SRC" "$DEST"
    _register_hook "PostToolUse/snapshot.ts" "$PLUGIN_SRC"
    ok "Plugin installed: PostToolUse/snapshot.ts (registered)"
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

  # Add transparent shell function: claude() → cclaude
  _install_shell_function

  echo ""
  echo -e "${GREEN}${BOLD}Installed!${NC} Restart your shell to activate."
  echo ""
  echo "  Just use ${BOLD}claude${NC} as usual — auto-restore is now built in."
  echo "  session-snapshot status     — show snapshot info"
  echo "  session-snapshot clean      — remove old snapshots"
  echo ""
}

# ── uninstall ─────────────────────────────────────────────────
cmd_uninstall() {
  echo ""
  echo -e "${BOLD}session-snapshot — uninstall${NC}"
  echo ""

  # Remove from claude-hooks + registry
  HOOKS_PLUGIN="$HOME/.config/claude-hooks/plugins/PostToolUse/snapshot.ts"
  if [ -f "$HOOKS_PLUGIN" ] || [ -L "$HOOKS_PLUGIN" ]; then
    rm "$HOOKS_PLUGIN"
    ok "Plugin removed from claude-hooks"
  fi
  _unregister_hook "PostToolUse/snapshot.ts"

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

  # Remove shell function
  _remove_shell_function

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

  # Check shell function
  local rc
  rc="$(_detect_shell_rc)"
  if [ -f "$rc" ] && grep -qF "$SHELL_MARKER" "$rc"; then
    ok "Shell function: active in $(basename "$rc")"
  else
    warn "Shell function: not installed (run 'session-snapshot install')"
  fi

  # Show MD cache info
  local md_dir="$CONFIG_DIR/md"
  if [ -f "$CONFIG_DIR/config.json" ]; then
    md_dir=$(node -e "const c=JSON.parse(require('fs').readFileSync('$CONFIG_DIR/config.json','utf-8')); console.log(c.mdDir || c.archiveDir || '$CONFIG_DIR/md')" 2>/dev/null)
  fi
  if [ -d "$md_dir" ]; then
    local md_count=$(find "$md_dir" -name "*.md" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
    local msize=$(du -sh "$md_dir" 2>/dev/null | cut -f1)
    ok "MD cache: $md_count session(s) ($msize) in $md_dir"
  else
    warn "MD cache: directory not found ($md_dir)"
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

  # Validate all hooks (not just ours)
  TOTAL=$((TOTAL + 1))
  if _validate_all_hooks --json 2>/dev/null | node -e "
    let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
      try { const r=JSON.parse(d); process.exit(r.issues.length > 0 ? 1 : 0); }
      catch { process.exit(0); }
    });
  " 2>/dev/null; then
    ok "All hooks healthy (no broken symlinks)"
    PASS=$((PASS + 1))
  else
    fail "Broken hooks detected — run: session-snapshot validate --fix"
  fi

  echo ""
  if [ "$PASS" -eq "$TOTAL" ]; then
    echo -e "  ${GREEN}${BOLD}All $TOTAL checks passed${NC}"
  else
    echo -e "  ${YELLOW}${BOLD}$PASS/$TOTAL checks passed${NC}"
  fi
  echo ""
}

# ── validate ─────────────────────────────────────────────────
cmd_validate() {
  _validate_all_hooks "$@"
}

# ── config ────────────────────────────────────────────────
cmd_config() {
  local key="${1:-}"
  local value="${2:-}"

  if [ -z "$key" ]; then
    echo ""
    echo -e "${BOLD}session-snapshot — config${NC}"
    echo ""
    if [ -f "$CONFIG_DIR/config.json" ]; then
      cat "$CONFIG_DIR/config.json"
    else
      echo "  No config file. Run 'session-snapshot install' first."
    fi
    echo ""
    return
  fi

  case "$key" in
    mdDir|md-dir)
      if [ -z "$value" ]; then
        fail "Usage: session-snapshot config mdDir /path/to/dir"
        exit 1
      fi
      # Expand ~ to $HOME
      value="${value/#\~/$HOME}"
      mkdir -p "$value"
      node -e "
const fs = require('fs');
const f = '$CONFIG_DIR/config.json';
let c = {}; try { c = JSON.parse(fs.readFileSync(f,'utf-8')); } catch {}
c.mdDir = '$value';
fs.writeFileSync(f, JSON.stringify(c, null, 2) + '\n');
"
      ok "mdDir set to: $value"
      ;;
    *)
      fail "Unknown config key: $key"
      echo "  Available: mdDir"
      exit 1
      ;;
  esac
}

# ── view ─────────────────────────────────────────────────────
cmd_view() {
  local session_id="${1:-}"
  local tail_lines="${2:-100}"

  # If no session ID, show latest or list sessions
  if [ -z "$session_id" ]; then
    # Try latest.json
    if [ -f "$SNAPSHOTS_DIR/latest.json" ]; then
      session_id=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$SNAPSHOTS_DIR/latest.json','utf-8')).sessionId)" 2>/dev/null)
    fi
    if [ -z "$session_id" ]; then
      fail "No session ID provided and no latest session found."
      echo ""
      echo "  Usage: session-snapshot view <session-id> [--tail N] [--full] [--no-results]"
      echo "         session-snapshot view latest"
      echo ""
      echo "  Find session IDs: session-snapshot list"
      return 1
    fi
  fi

  if [ "$session_id" = "latest" ]; then
    if [ -f "$SNAPSHOTS_DIR/latest.json" ]; then
      session_id=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$SNAPSHOTS_DIR/latest.json','utf-8')).sessionId)" 2>/dev/null)
    else
      fail "No latest session found."
      return 1
    fi
  fi

  # Parse remaining flags
  shift 2>/dev/null || true
  local full=false
  local no_results=""
  local tail_n="100"

  while [ $# -gt 0 ]; do
    case "$1" in
      --full) full=true ;;
      --no-results) no_results="--no-results" ;;
      --tail) shift; tail_n="${1:-100}" ;;
      *) tail_n="$1" ;;
    esac
    shift
  done

  # Find the JSONL file — try exact match first, then prefix
  local jsonl_path
  jsonl_path=$(node --experimental-strip-types -e "
    import { findSessionJsonl } from '$REPO_DIR/src/claude-paths.ts';
    const p = findSessionJsonl('$session_id');
    if (p) console.log(p);
  " 2>/dev/null || true)

  if [ -z "$jsonl_path" ]; then
    # Try partial match (prefix)
    jsonl_path=$(find "$HOME/.claude/projects" -name "${session_id}*.jsonl" -not -path "*/subagents/*" 2>/dev/null | head -1)
  fi

  if [ -z "$jsonl_path" ] || [ ! -f "$jsonl_path" ]; then
    fail "Session not found: $session_id"
    return 1
  fi

  local file_size=$(stat -f%z "$jsonl_path" 2>/dev/null || stat -c%s "$jsonl_path" 2>/dev/null)
  local size_kb=$((file_size / 1024))

  echo -e "${DIM}session: ${session_id}${NC}" >&2
  echo -e "${DIM}source:  ${jsonl_path} (${size_kb}KB)${NC}" >&2

  # Resolve full session ID from the JSONL filename
  local full_sid=$(basename "$jsonl_path" .jsonl)

  if [ "$full" = true ]; then
    echo -e "${DIM}mode:    full (cached + incremental)${NC}" >&2
    # Use view-session.ts which reads cached MD, appends new lines, outputs everything
    node --experimental-strip-types "$REPO_DIR/src/view-session.ts" "$full_sid" "$jsonl_path" $no_results
  else
    echo -e "${DIM}mode:    tail ${tail_n} lines${NC}" >&2
    node --experimental-strip-types "$REPO_DIR/src/jsonl-to-md.ts" "$jsonl_path" --tail "$tail_n" $no_results
  fi
}

# ── list ─────────────────────────────────────────────────────
cmd_list() {
  echo ""
  echo -e "${BOLD}session-snapshot — sessions${NC}"
  echo ""

  # Find all session JSONLs, sorted by modification time (newest first)
  local found=0
  while IFS= read -r jsonl; do
    [ -f "$jsonl" ] || continue
    local sid=$(basename "$jsonl" .jsonl)
    local size=$(stat -f%z "$jsonl" 2>/dev/null || stat -c%s "$jsonl" 2>/dev/null)
    local size_kb=$((size / 1024))
    local dir=$(basename "$(dirname "$jsonl")")
    local mod=$(stat -f"%Sm" -t"%Y-%m-%d %H:%M" "$jsonl" 2>/dev/null || stat -c"%y" "$jsonl" 2>/dev/null | cut -d. -f1)

    # Extract project name
    local project
    project=$(node --experimental-strip-types -e "
      import { extractProjectName } from '$REPO_DIR/src/jsonl-to-md.ts';
      console.log(extractProjectName('$jsonl'));
    " 2>/dev/null || echo "?")

    echo -e "  ${CYAN}${sid:0:8}${NC}  ${size_kb}KB  ${DIM}${mod}${NC}  ${project}"
    found=$((found + 1))
  done < <(find "$HOME/.claude/projects" -name "*.jsonl" -not -path "*/subagents/*" 2>/dev/null | xargs ls -t 2>/dev/null | head -30)

  if [ "$found" -eq 0 ]; then
    echo "  No sessions found."
  else
    echo ""
    echo -e "  ${DIM}Showing $found most recent. Use: session-snapshot view <id>${NC}"
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
  echo "  View:"
  echo "    view [id] [--tail N]  Show session as Markdown (default: last 100 lines)"
  echo "    view [id] --full      Show full session as Markdown"
  echo "    list                  List recent sessions"
  echo ""
  echo "  Setup:"
  echo "    install           Install plugin + wrapper"
  echo "    uninstall         Remove plugin + wrapper"
  echo ""
  echo "  Info:"
  echo "    status            Show snapshot info"
  echo "    clean             Remove all snapshots"
  echo "    test              Run self-test"
  echo "    validate          Check all hooks are healthy"
  echo "    validate --fix    Auto-remove broken hooks"
  echo ""
  echo "  Config:"
  echo "    config                   Show current config"
  echo "    config mdDir PATH        Set MD storage directory (e.g. Google Drive)"
  echo ""
  echo "  After install, just use ${BOLD}claude${NC} as usual — auto-restore is built in."
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
  config)    cmd_config "$@" ;;
  test)      cmd_test ;;
  validate)  cmd_validate "$@" ;;
  view)      cmd_view "$@" ;;
  list|ls)   cmd_list ;;
  help|--help|-h) cmd_help ;;
  *)
    fail "Unknown command: $COMMAND"
    cmd_help
    exit 1
    ;;
esac
