#!/bin/bash
# cclaude — wrapper for claude that auto-restores from snapshot after context overload.
# Usage: cclaude [args...]  (or alias claude=cclaude)
set -euo pipefail

CONFIG_DIR="$HOME/.config/session-snapshot"
SNAPSHOTS_DIR="$CONFIG_DIR/snapshots"
LATEST="$SNAPSHOTS_DIR/latest.json"
FLAGS_FILE="$CONFIG_DIR/pending-flags.txt"

# Extract persistent flags from args
PERSIST_FLAGS=()
for arg in "$@"; do
  case "$arg" in
    --dangerously-skip-permissions|--verbose|--debug)
      PERSIST_FLAGS+=("$arg")
      ;;
  esac
done

# Save flags for use after restart
if [ ${#PERSIST_FLAGS[@]} -gt 0 ]; then
  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "${PERSIST_FLAGS[@]}" > "$FLAGS_FILE"
else
  rm -f "$FLAGS_FILE"
fi

while true; do
  env -u CLAUDECODE claude "$@"

  # ── Auto-restore from snapshot after context overload ──
  if [ ! -f "$LATEST" ]; then
    break
  fi

  # Parse latest snapshot info
  SNAP_SESSION=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$LATEST','utf-8')).sessionId)" 2>/dev/null || echo "")
  SNAP_PATH=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$LATEST','utf-8')).snapshotPath)" 2>/dev/null || echo "")
  SNAP_JSONL=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$LATEST','utf-8')).jsonlPath)" 2>/dev/null || echo "")
  SNAP_TS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$LATEST','utf-8')).timestamp)" 2>/dev/null || echo "0")
  NOW_TS=$(node -e "console.log(Date.now())" 2>/dev/null)

  # Only restore if snapshot is recent (< 10 min) and session JSONL grew beyond snapshot
  if [ -z "$SNAP_SESSION" ] || [ ! -f "$SNAP_PATH" ] || [ ! -f "$SNAP_JSONL" ]; then
    rm -f "$LATEST"
    break
  fi

  AGE_MS=$(( NOW_TS - SNAP_TS ))
  SNAP_SIZE=$(stat -f%z "$SNAP_PATH" 2>/dev/null || stat -c%s "$SNAP_PATH" 2>/dev/null)
  JSONL_SIZE=$(stat -f%z "$SNAP_JSONL" 2>/dev/null || stat -c%s "$SNAP_JSONL" 2>/dev/null)

  # Overload signal: JSONL grew >100KB beyond snapshot, snapshot < 10 min old
  if [ "$AGE_MS" -lt 600000 ] && [ "$JSONL_SIZE" -gt $(( SNAP_SIZE + 100000 )) ]; then
    echo ""
    echo "  ⚡ session-snapshot: context overload detected"
    echo "  Session ${SNAP_SESSION:0:8}... crashed at $(( JSONL_SIZE / 1024 ))KB"
    echo "  Restoring from snapshot ($(( SNAP_SIZE / 1024 ))KB)..."
    echo ""

    # Replace crashed JSONL with snapshot
    cp "$SNAP_PATH" "$SNAP_JSONL"
    rm -f "$LATEST"

    # Read saved flags
    SAVED_FLAGS=()
    if [ -f "$FLAGS_FILE" ]; then
      while IFS= read -r flag; do
        [ -n "$flag" ] && SAVED_FLAGS+=("$flag")
      done < "$FLAGS_FILE"
    fi

    RESTORE_PROMPT="[Session restored from session-snapshot after context overload. Some recent context may be lost — call get_session_summary if artifacts-mcp is available.]"

    # Clear positional args for the restart loop
    set -- --resume "$SNAP_SESSION" "${SAVED_FLAGS[@]}" -p "$RESTORE_PROMPT"
    continue
  fi

  # Snapshot not needed for restore — clean up
  rm -f "$LATEST"
  break
done

rm -f "$FLAGS_FILE"
