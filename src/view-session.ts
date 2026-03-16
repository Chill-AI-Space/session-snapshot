/**
 * Smart session viewer — reads cached MD if available, appends new lines, outputs everything.
 *
 * Usage: node --experimental-strip-types src/view-session.ts <sessionId> <jsonlPath> [--no-results]
 *
 * Flow:
 * 1. Check md/{sessionId}.md — if exists, read it
 * 2. Check state.lastConvertedLine — if JSONL has grown, convert new lines and append
 * 3. Output the full MD to stdout
 *
 * Shares state with snapshot hook — whoever converts first advances lastConvertedLine.
 */
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { paths } from './claude-paths.ts';
import { convertJsonlToMd } from './jsonl-to-md.ts';
import { readState, writeState, appendMd } from './snapshot.ts';

const sessionId = process.argv[2];
const jsonlPath = process.argv[3];
const noResults = process.argv.includes('--no-results');

if (!sessionId || !jsonlPath) {
  console.error('Usage: view-session.ts <sessionId> <jsonlPath> [--no-results]');
  process.exit(1);
}

const mdPath = join(paths.mdDir, `${sessionId}.md`);
const state = readState(sessionId);
const hasCachedMd = existsSync(mdPath);

// If state has lastConvertedLine but no cached MD file, reset — likely migration from old format
if (!hasCachedMd && state.lastConvertedLine > 0) {
  state.lastConvertedLine = 0;
}

// Count current JSONL lines
const totalLines = readFileSync(jsonlPath, 'utf-8').split('\n').filter(Boolean).length;
const hasNewLines = totalLines > state.lastConvertedLine;

if (hasCachedMd && !hasNewLines) {
  // Cache is up to date — just output it
  process.stdout.write(readFileSync(mdPath, 'utf-8'));
} else if (hasCachedMd && hasNewLines) {
  // Cache exists but JSONL has grown — append new lines, then output
  appendMd(jsonlPath, sessionId, state);
  state.lastConvertedLine = totalLines;
  writeState(state);
  process.stdout.write(readFileSync(mdPath, 'utf-8'));
} else {
  // No cache — generate full MD from scratch, save, output
  appendMd(jsonlPath, sessionId, state);
  state.lastConvertedLine = totalLines;
  writeState(state);
  if (existsSync(mdPath)) {
    process.stdout.write(readFileSync(mdPath, 'utf-8'));
  } else {
    // appendMd skipped (session too small) — convert directly
    process.stdout.write(convertJsonlToMd(jsonlPath, { includeResults: !noResults }));
  }
}
