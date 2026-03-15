/**
 * Claude Code path discovery — finds session JSONLs on any machine.
 * Scans ~/.claude/projects/ directories, caches successful lookups.
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const HOME = process.env.HOME || process.env.USERPROFILE || '/tmp';
const CONFIG_DIR = join(HOME, '.config', 'session-snapshot');
const CONFIG_FILE = join(CONFIG_DIR, 'config.json');

export interface Config {
  archiveDir: string;
}

function loadConfig(): Config {
  const defaults: Config = {
    archiveDir: join(CONFIG_DIR, 'archive'),
  };
  try {
    const raw = JSON.parse(readFileSync(CONFIG_FILE, 'utf-8'));
    return { ...defaults, ...raw };
  } catch {
    return defaults;
  }
}

export function saveConfig(config: Partial<Config>): void {
  mkdirSync(CONFIG_DIR, { recursive: true });
  let existing: Record<string, unknown> = {};
  try { existing = JSON.parse(readFileSync(CONFIG_FILE, 'utf-8')); } catch {}
  writeFileSync(CONFIG_FILE, JSON.stringify({ ...existing, ...config }, null, 2) + '\n');
}

export const config = loadConfig();

export const paths = {
  home: HOME,
  projectsDir: join(HOME, '.claude', 'projects'),
  configDir: CONFIG_DIR,
  configFile: CONFIG_FILE,
  snapshotsDir: join(CONFIG_DIR, 'snapshots'),
  archiveDir: config.archiveDir,
  logsDir: join(CONFIG_DIR, 'logs'),
  cacheFile: join(CONFIG_DIR, 'path-cache.json'),
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
