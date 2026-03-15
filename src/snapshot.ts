/**
 * Rolling JSONL snapshot — saves a byte-perfect copy of the session JSONL
 * periodically, so if context overload kills the session, we can restore.
 * Also generates incremental MD diffs for the archive.
 *
 * This is both a standalone module AND a claude-hooks plugin.
 */
import { appendFileSync, copyFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import { findSessionJsonl, paths } from './claude-paths.ts';
import { convertJsonlToMd } from './jsonl-to-md.ts';

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
  lastConvertedLine: number;
  sessionId: string;
}

/**
 * Extract a short project name from the JSONL path.
 * Path looks like: ~/.claude/projects/-Users-vova-Documents-GitHub-myproject/abc.jsonl
 * → "myproject"
 */
function projectNameFromPath(jsonlPath: string): string {
  const dirName = basename(join(jsonlPath, '..'));
  const parts = dirName.split('-').filter(Boolean);
  return parts[parts.length - 1] || 'unknown';
}

/**
 * Generate an incremental MD diff for new JSONL lines since last snapshot.
 * Writes to archive/{project}-{shortId}/NNN.md
 */
function archiveMdDiff(jsonlPath: string, sessionId: string, state: SnapshotState): void {
  try {
    const project = projectNameFromPath(jsonlPath);
    const shortId = sessionId.slice(0, 8);
    const sessionDir = join(paths.archiveDir, `${project}-${shortId}`);
    mkdirSync(sessionDir, { recursive: true });

    const fromLine = state.lastConvertedLine;
    const md = convertJsonlToMd(jsonlPath, { fromLine });

    // Don't write empty diffs
    if (md.split('\n').length <= 7) return; // frontmatter only

    const chunkNum = String(state.snapshotCount).padStart(3, '0');
    const mdPath = join(sessionDir, `${chunkNum}.md`);
    writeFileSync(mdPath, md);

    log(`MD diff ${chunkNum} written (from L:${fromLine}) → ${mdPath}`);
  } catch (err: any) {
    log(`MD diff error: ${err.message}`);
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
    let state: SnapshotState = { lastSnapshotSize: 0, snapshotCount: 0, lastConvertedLine: 0, sessionId };
    try { state = JSON.parse(readFileSync(stateFile, 'utf-8')); } catch {}

    if (fileSize - state.lastSnapshotSize < SNAPSHOT_INTERVAL) return false;

    // Rolling: overwrite previous snapshot (byte-perfect copy)
    const snapshotPath = join(paths.snapshotsDir, `${sessionId}.jsonl`);
    copyFileSync(jsonlPath, snapshotPath);

    // Count current lines for MD diff tracking
    const totalLines = readFileSync(jsonlPath, 'utf-8').split('\n').filter(Boolean).length;

    // Generate MD diff before updating state
    archiveMdDiff(jsonlPath, sessionId, state);

    state.lastSnapshotSize = fileSize;
    state.snapshotCount++;
    state.lastConvertedLine = totalLines;
    writeFileSync(stateFile, JSON.stringify(state));

    // Write latest.json for wrapper auto-restore
    writeFileSync(join(paths.snapshotsDir, 'latest.json'), JSON.stringify({
      sessionId,
      snapshotPath,
      jsonlPath,
      snapshotSize: fileSize,
      timestamp: Date.now(),
    }));

    log(`Snapshot #${state.snapshotCount} saved (JSONL: ${(fileSize / 1024).toFixed(0)}KB, MD diff L:${state.lastConvertedLine})`);
    return true;
  } catch (err: any) {
    log(`Snapshot error: ${err.message}`);
    return false;
  }
}

/** claude-hooks plugin interface */
export default {
  name: 'session-snapshot',
  version: '0.2.0',
  run(input: { session_id: string; hook_event_name: string }) {
    if (!input.session_id) return;
    // Only snapshot on PostToolUse (most frequent, gives best granularity)
    if (input.hook_event_name !== 'PostToolUse') return;
    maybeSnapshot(input.session_id);
  },
};
