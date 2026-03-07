/**
 * Claude Code path discovery — finds session JSONLs on any machine.
 * Scans ~/.claude/projects/ directories, caches successful lookups.
 */
import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const HOME = process.env.HOME || process.env.USERPROFILE || '/tmp';

export const paths = {
  home: HOME,
  projectsDir: join(HOME, '.claude', 'projects'),
  configDir: join(HOME, '.config', 'session-snapshot'),
  snapshotsDir: join(HOME, '.config', 'session-snapshot', 'snapshots'),
  logsDir: join(HOME, '.config', 'session-snapshot', 'logs'),
  cacheFile: join(HOME, '.config', 'session-snapshot', 'path-cache.json'),
} as const;

type PathCache = Record<string, string>;
let memCache: PathCache | null = null;

function loadCache(): PathCache {
  if (memCache) return memCache;
  try { memCache = JSON.parse(readFileSync(paths.cacheFile, 'utf-8')); }
  catch { memCache = {}; }
  return memCache!;
}

function saveCache(cache: PathCache): void {
  memCache = cache;
  try {
    mkdirSync(paths.configDir, { recursive: true });
    writeFileSync(paths.cacheFile, JSON.stringify(cache));
  } catch {}
}

/** Find a session JSONL by session ID — scans all project dirs, caches result. */
export function findSessionJsonl(sessionId: string): string | null {
  // Check cache first
  const cache = loadCache();
  if (cache[sessionId]) {
    try { statSync(cache[sessionId]); return cache[sessionId]; }
    catch { delete cache[sessionId]; saveCache(cache); }
  }

  const jsonlName = `${sessionId}.jsonl`;
  try {
    const dirs = readdirSync(paths.projectsDir);
    for (const dir of dirs) {
      const candidate = join(paths.projectsDir, dir, jsonlName);
      try {
        statSync(candidate);
        // Cache for next time
        cache[sessionId] = candidate;
        const keys = Object.keys(cache);
        if (keys.length > 50) delete cache[keys[0]];
        saveCache(cache);
        return candidate;
      } catch {}
    }
  } catch {}
  return null;
}
