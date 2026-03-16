/**
 * Rolling JSONL snapshot + incremental MD generation.
 *
 * Two independent jobs on each trigger:
 * 1. JSONL backup — byte-perfect copy for crash recovery (rolling, one per session)
 * 2. MD append — converts new JSONL lines to Markdown, appends to md/{sessionId}.md
 *
 * Both share `lastConvertedLine` in state — the `view` command can also advance it,
 * so neither duplicates work.
 *
 * This is both a standalone module AND a claude-hooks plugin.
 */
import { appendFileSync, copyFileSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { findSessionJsonl, paths } from './claude-paths.ts';
import { convertJsonlToMd } from './jsonl-to-md.ts';

const DEBUG = process.env.SESSION_SNAPSHOT_DEBUG === '1' || process.env.CLAUDE_HOOKS_DEBUG === '1';
const LOG_FILE = join(paths.logsDir, 'snapshot.log');

// Snapshot every ~80K of JSONL growth (~20K tokens)
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

export interface SnapshotState {
  sessionId: string;
  lastSnapshotSize: number;
  snapshotCount: number;
  lastConvertedLine: number;
}

/** Read state for a session. Shared between hook and view. */
export function readState(sessionId: string): SnapshotState {
  const stateFile = join(paths.snapshotsDir, `${sessionId}.state.json`);
  try {
    return JSON.parse(readFileSync(stateFile, 'utf-8'));
  } catch {
    return { sessionId, lastSnapshotSize: 0, snapshotCount: 0, lastConvertedLine: 0 };
  }
}

/** Write state for a session. */
export function writeState(state: SnapshotState): void {
  const stateFile = join(paths.snapshotsDir, `${state.sessionId}.state.json`);
  mkdirSync(paths.snapshotsDir, { recursive: true });
  writeFileSync(stateFile, JSON.stringify(state));
}

/**
 * Append new JSONL lines as MD to the session's MD file.
 * Returns the number of new lines converted, or 0 if nothing new.
 */
export function appendMd(jsonlPath: string, sessionId: string, state: SnapshotState): number {
  try {
    mkdirSync(paths.mdDir, { recursive: true });

    const fromLine = state.lastConvertedLine;
    const md = convertJsonlToMd(jsonlPath, { fromLine, includeResults: true });

    // Skip if only frontmatter (no real content)
    if (md.split('\n').length <= 7) return 0;

    const mdPath = join(paths.mdDir, `${sessionId}.md`);

    if (fromLine === 0) {
      // First write — include frontmatter
      writeFileSync(mdPath, md);
    } else {
      // Append — strip frontmatter from new chunk
      const lines = md.split('\n');
      const fmEnd = lines.indexOf('---', 1);
      const body = lines.slice(fmEnd + 1).join('\n');
      if (body.trim()) {
        appendFileSync(mdPath, '\n' + body);
      } else {
        return 0;
      }
    }

    // Count lines we just converted
    const totalLines = readFileSync(jsonlPath, 'utf-8').split('\n').filter(Boolean).length;
    const newLines = totalLines - fromLine;

    log(`MD appended (L:${fromLine}→${totalLines}) → ${mdPath}`);
    return newLines;
  } catch (err: any) {
    log(`MD append error: ${err.message}`);
    return 0;
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

    const state = readState(sessionId);

    if (fileSize - state.lastSnapshotSize < SNAPSHOT_INTERVAL) return false;

    // 1. JSONL backup (rolling — overwrites previous)
    const snapshotPath = join(paths.snapshotsDir, `${sessionId}.jsonl`);
    copyFileSync(jsonlPath, snapshotPath);

    // 2. MD append (incremental)
    appendMd(jsonlPath, sessionId, state);

    // 3. Update shared state
    const totalLines = readFileSync(jsonlPath, 'utf-8').split('\n').filter(Boolean).length;
    state.lastSnapshotSize = fileSize;
    state.snapshotCount++;
    state.lastConvertedLine = totalLines;
    writeState(state);

    // 4. Latest pointer for wrapper auto-restore
    writeFileSync(join(paths.snapshotsDir, 'latest.json'), JSON.stringify({
      sessionId, snapshotPath, jsonlPath,
      snapshotSize: fileSize,
      timestamp: Date.now(),
    }));

    log(`Snapshot #${state.snapshotCount} (${(fileSize / 1024).toFixed(0)}KB, MD L:${totalLines})`);
    return true;
  } catch (err: any) {
    log(`Snapshot error: ${err.message}`);
    return false;
  }
}

/** claude-hooks plugin interface */
export default {
  name: 'session-snapshot',
  version: '0.3.0',
  run(input: { session_id: string; hook_event_name: string }) {
    if (!input.session_id) return;
    if (input.hook_event_name !== 'PostToolUse') return;
    maybeSnapshot(input.session_id);
  },
};
