/**
 * Rolling JSONL snapshot — saves a byte-perfect copy of the session JSONL
 * periodically, so if context overload kills the session, we can restore.
 *
 * This is both a standalone module AND a claude-hooks plugin.
 */
import { appendFileSync, copyFileSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import { findSessionJsonl, paths } from './claude-paths.ts';

const DEBUG = process.env.SESSION_SNAPSHOT_DEBUG === '1' || process.env.CLAUDE_HOOKS_DEBUG === '1';
const LOG_FILE = join(paths.logsDir, 'snapshot.log');

// Snapshot every ~80K chars of JSONL growth (~20K tokens buffer)
const SNAPSHOT_INTERVAL = 80_000;
// Don't snapshot tiny sessions
const SNAPSHOT_MIN_SIZE = 200_000; // ~50K tokens

function log(msg: string): void {
  if (!DEBUG) return;
  try {
    mkdirSync(paths.logsDir, { recursive: true });
    appendFileSync(LOG_FILE, `[${new Date().toISOString()}] ${msg}\n`);
  } catch {}
}

interface SnapshotState {
  lastSnapshotSize: number;
  snapshotCount: number;
  sessionId: string;
}

/**
 * Extract a short project name from the JSONL path.
 * Path looks like: ~/.claude/projects/-Users-vova-Documents-GitHub-myproject/abc.jsonl
 * → "myproject"
 */
function projectNameFromPath(jsonlPath: string): string {
  // Parent dir name is the hashed project path
  const dirName = basename(join(jsonlPath, '..'));
  // Take last segment (after last dash that follows a known separator)
  const parts = dirName.split('-').filter(Boolean);
  return parts[parts.length - 1] || 'unknown';
}

function archiveSnapshot(jsonlPath: string, sessionId: string): void {
  try {
    mkdirSync(paths.archiveDir, { recursive: true });
    const project = projectNameFromPath(jsonlPath);
    const shortId = sessionId.slice(0, 8);
    const archivePath = join(paths.archiveDir, `${project}-${shortId}.jsonl`);
    copyFileSync(jsonlPath, archivePath);
    log(`Archived to ${archivePath}`);
  } catch (err: any) {
    log(`Archive error: ${err.message}`);
  }
}

export function maybeSnapshot(sessionId: string): boolean {
  try {
    mkdirSync(paths.snapshotsDir, { recursive: true });

    const jsonlPath = findSessionJsonl(sessionId);
    if (!jsonlPath) {
      log(`No JSONL found for session ${sessionId.slice(0, 8)}`);
      return false;
    }

    const fileSize = statSync(jsonlPath).size;
    if (fileSize < SNAPSHOT_MIN_SIZE) return false;

    // Read rolling state
    const stateFile = join(paths.snapshotsDir, `${sessionId}.state.json`);
    let state: SnapshotState = { lastSnapshotSize: 0, snapshotCount: 0, sessionId };
    try { state = JSON.parse(readFileSync(stateFile, 'utf-8')); } catch {}

    if (fileSize - state.lastSnapshotSize < SNAPSHOT_INTERVAL) return false;

    // Rolling: overwrite previous snapshot (byte-perfect copy)
    const snapshotPath = join(paths.snapshotsDir, `${sessionId}.jsonl`);
    copyFileSync(jsonlPath, snapshotPath);

    state.lastSnapshotSize = fileSize;
    state.snapshotCount++;
    writeFileSync(stateFile, JSON.stringify(state));

    // Write latest.json for wrapper auto-restore
    writeFileSync(join(paths.snapshotsDir, 'latest.json'), JSON.stringify({
      sessionId,
      snapshotPath,
      jsonlPath,
      snapshotSize: fileSize,
      timestamp: Date.now(),
    }));

    // Archive: copy to archive dir (survives Claude Code cleanup)
    archiveSnapshot(jsonlPath, sessionId);

    log(`Snapshot #${state.snapshotCount} saved (JSONL: ${(fileSize / 1024).toFixed(0)}KB)`);
    return true;
  } catch (err: any) {
    log(`Snapshot error: ${err.message}`);
    return false;
  }
}

/** claude-hooks plugin interface */
export default {
  name: 'session-snapshot',
  version: '0.1.0',
  run(input: { session_id: string; hook_event_name: string }) {
    if (!input.session_id) return;
    // Only snapshot on PostToolUse (most frequent, gives best granularity)
    if (input.hook_event_name !== 'PostToolUse') return;
    maybeSnapshot(input.session_id);
  },
};
