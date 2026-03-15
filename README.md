# session-snapshot

Rolling JSONL snapshots for Claude Code sessions with automatic restore after context overload.

## Problem

When a Claude Code session hits context limits, the session crashes and all conversation context is lost. You have to start from scratch.

## Solution

**session-snapshot** does two things:

1. **Saves snapshots** — a Claude Code hook that periodically copies the session JSONL file (every ~80KB of growth, once the session exceeds ~200KB). One rolling snapshot per session, always up to date.

2. **Archives sessions** — every snapshot is also saved to an archive directory that Claude Code won't clean up. Configurable — point it at Google Drive, Dropbox, or any shared folder.

3. **Auto-restores** — detects context overload when Claude exits and automatically restores the session from the last snapshot, resuming where you left off.

## Components

The tool has 4 parts: a hook, a wrapper, a path resolver, and a CLI.

### 1. Snapshot hook (`src/snapshot.ts`)

A [Claude Code hook](https://docs.anthropic.com/en/docs/claude-code/hooks) that runs on every `PostToolUse` event. After each tool call, it checks whether the session JSONL has grown enough to warrant a new snapshot.

**How it decides to snapshot:**
- Ignores sessions under 200KB (~50K tokens) — too small to worry about
- After reaching 200KB, snapshots every ~80KB of growth (~20K tokens worth)
- Rolling strategy: one snapshot per session, each new one overwrites the previous

**What it produces:**
- `~/.config/session-snapshot/snapshots/{sessionId}.jsonl` — byte-perfect copy of the session JSONL
- `~/.config/session-snapshot/snapshots/{sessionId}.state.json` — tracks snapshot count and last size
- `~/.config/session-snapshot/snapshots/latest.json` — pointer to the most recent snapshot (session ID, paths, timestamp) used by the wrapper

**Hook interface:** Exports a default object with `name`, `version`, and `run(input)`. Claude Code calls `run()` with `{ session_id, hook_event_name }` — the hook only acts on `PostToolUse`.

### 2. Auto-restore wrapper (`bin/cclaude.sh`)

A bash wrapper around `claude` that adds crash recovery. After install, `claude` is aliased to the wrapper transparently — no need to change how you launch Claude.

**How auto-restore works:**
1. Runs `claude` with your arguments
2. When `claude` exits, checks `latest.json` for a recent snapshot
3. Detects context overload if **both** conditions are met:
   - Snapshot is less than 10 minutes old
   - Session JSONL grew more than 100KB beyond the snapshot (sign of compaction/overflow)
4. If overload detected: replaces the crashed JSONL with the snapshot copy
5. Restarts `claude --resume {sessionId}` with a prompt telling the model that context was restored
6. Loops back to step 2

**Flag preservation:** Remembers flags like `--dangerously-skip-permissions`, `--verbose`, `--debug` across restarts.

### 3. Path resolver (`src/claude-paths.ts`)

Claude Code stores session JSONLs in `~/.claude/projects/{project-hash}/{sessionId}.jsonl`, but the hook only receives a session ID — not the full path. This module finds the JSONL by scanning all project directories.

- Scans `~/.claude/projects/` subdirectories for a matching `{sessionId}.jsonl`
- Caches successful lookups in `~/.config/session-snapshot/path-cache.json` (up to 50 entries)
- Cache is checked first; if the file no longer exists, the entry is evicted and a fresh scan runs

### 4. CLI (`bin/cli.sh`)

Management commands:

| Command | What it does |
|---------|-------------|
| `install` | Registers the hook + installs the `cclaude` wrapper |
| `uninstall` | Removes the hook registration + wrapper |
| `status` | Shows whether the hook is active, wrapper is in PATH, lists snapshots |
| `clean` | Deletes all snapshot files |
| `test` | Runs self-checks (plugin loads, modules import, paths resolve) |

**Install modes:** If [claude-hooks](https://github.com/anthropics/claude-code-hooks) plugin directory exists (`~/.config/claude-hooks/plugins/`), the hook is symlinked there. Otherwise, it registers directly in `~/.claude/settings.json` under `hooks.PostToolUse`.

```
┌─────────────┐     PostToolUse hook      ┌──────────────────┐
│ Claude Code  │ ──────────────────────►  │  snapshot.ts      │
│  (session)   │                          │  copies JSONL     │
└──────┬──────┘                          │  every ~80KB      │
       │                                  └────────┬─────────┘
       │ exits                                     │
       ▼                                           ▼
┌─────────────┐     detects overload     ┌──────────────────┐
│  cclaude.sh  │ ◄────────────────────── │  snapshots/       │
│  (wrapper)   │     restores JSONL      │  latest.json      │
└─────────────┘                          └──────────────────┘
```

## Install

Requires **Node.js 22+**.

```bash
git clone https://github.com/Chill-AI-Space/session-snapshot.git
cd session-snapshot
./bin/cli.sh install
```

This will:
- Register `snapshot.ts` as a `PostToolUse` hook (via claude-hooks plugin dir or directly in `~/.claude/settings.json`)
- Install the `cclaude` wrapper to `~/.local/bin/`
- Add a shell function so `claude` routes through the wrapper transparently
- Create a default archive directory at `~/.config/session-snapshot/archive/`

## Usage

Just use `claude` as you always do:

```bash
claude --dangerously-skip-permissions
```

That's it. Snapshots and archiving happen automatically in the background. If context overload occurs, the session is restored automatically.

## CLI commands

```bash
session-snapshot install                           # Install plugin + wrapper + shell alias
session-snapshot uninstall                         # Remove everything
session-snapshot status                            # Show snapshot & archive info
session-snapshot clean                             # Remove all snapshots
session-snapshot config                            # Show current config
session-snapshot config archiveDir ~/Google\ Drive/sessions   # Change archive location
session-snapshot test                              # Run self-test
```

## File layout

```
session-snapshot/
  src/
    snapshot.ts         # Hook plugin — creates rolling JSONL snapshots
    claude-paths.ts     # Finds session JSONL files across project dirs
  bin/
    cclaude.sh          # Wrapper — auto-restore loop around claude
    cli.sh              # CLI for install/uninstall/status/clean/test

~/.config/session-snapshot/
  config.json                   # Settings (archiveDir, etc.)
  snapshots/
    {sessionId}.jsonl           # Rolling snapshot (overwritten each time)
    {sessionId}.state.json      # Rolling state (count, last size)
    latest.json                 # Pointer for wrapper auto-restore
  archive/
    {project}-{shortId}.jsonl   # Permanent session archive
  path-cache.json               # Cached session ID -> JSONL path mappings
  logs/
    snapshot.log                # Debug log (when enabled)
```

## Configuration

Config file: `~/.config/session-snapshot/config.json`

```json
{
  "archiveDir": "~/.config/session-snapshot/archive"
}
```

Change the archive location (e.g. to a Google Drive sync folder):

```bash
session-snapshot config archiveDir ~/Google\ Drive/claude-sessions
```

Environment variables:

- `SESSION_SNAPSHOT_DEBUG=1` — enable debug logging to `~/.config/session-snapshot/logs/snapshot.log`

Tunable constants in `src/snapshot.ts`:

- `SNAPSHOT_INTERVAL` (default: 80,000 bytes) — JSONL growth between snapshots
- `SNAPSHOT_MIN_SIZE` (default: 200,000 bytes) — minimum session size before snapshotting starts

## Uninstall

```bash
session-snapshot uninstall
# To remove snapshots too:
rm -rf ~/.config/session-snapshot
```

## License

MIT
