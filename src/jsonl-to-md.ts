/**
 * JSONL → MD diff converter.
 * Converts Claude Code session JSONL to readable Markdown, block by block.
 * No AI involved — pure deterministic parsing.
 */
import { readFileSync, writeFileSync, mkdirSync, openSync, readSync, closeSync, statSync } from 'node:fs';
import { join, basename } from 'node:path';

interface ContentBlock {
  type: string;
  text?: string;
  name?: string;
  input?: Record<string, unknown>;
  content?: string | ContentBlock[];
  tool_use_id?: string;
}

interface Message {
  role: string;
  content: string | ContentBlock[];
}

interface JsonlLine {
  type: string;
  message?: Message;
  content?: string;
  uuid?: string;
  timestamp?: string;
  sessionId?: string;
}

function formatToolUse(block: ContentBlock): string {
  const name = block.name || 'Unknown';
  const input = block.input || {};

  switch (name) {
    case 'Bash': {
      const cmd = (input.command as string) || '';
      const desc = (input.description as string) || '';
      return `### Bash${desc ? ` — ${desc}` : ''}\n\`\`\`bash\n${cmd}\n\`\`\``;
    }
    case 'Read': {
      const path = (input.file_path as string) || '';
      return `### Read\n\`${path}\``;
    }
    case 'Write': {
      const path = (input.file_path as string) || '';
      const content = (input.content as string) || '';
      const lines = content.split('\n').length;
      return `### Write\n\`${path}\` (${lines} lines)`;
    }
    case 'Edit': {
      const path = (input.file_path as string) || '';
      const old_str = (input.old_string as string) || '';
      const new_str = (input.new_string as string) || '';
      return `### Edit\n\`${path}\`\n\`\`\`diff\n-${old_str.split('\n').join('\n-')}\n+${new_str.split('\n').join('\n+')}\n\`\`\``;
    }
    case 'Grep': {
      const pattern = (input.pattern as string) || '';
      const path = (input.path as string) || '';
      return `### Grep\n\`${pattern}\`${path ? ` in \`${path}\`` : ''}`;
    }
    case 'Glob': {
      const pattern = (input.pattern as string) || '';
      return `### Glob\n\`${pattern}\``;
    }
    case 'Agent': {
      const desc = (input.description as string) || (input.prompt as string)?.slice(0, 100) || '';
      return `### Agent\n${desc}`;
    }
    case 'TodoWrite': {
      const todos = input.todos;
      if (Array.isArray(todos)) {
        const items = todos.map((t: any) => `- [${t.status === 'completed' ? 'x' : ' '}] ${t.content}`).join('\n');
        return `### Todos\n${items}`;
      }
      return `### Todos\n(updated)`;
    }
    default: {
      // Generic tool
      const keys = Object.keys(input);
      const summary = keys.slice(0, 3).map(k => {
        const v = input[k];
        const str = typeof v === 'string' ? v : JSON.stringify(v);
        return `${k}: ${str.slice(0, 100)}`;
      }).join(', ');
      return `### ${name}\n${summary}`;
    }
  }
}

function formatToolResult(block: ContentBlock): string {
  const content = block.content;
  if (!content) return '';

  let text = '';
  if (typeof content === 'string') {
    text = content;
  } else if (Array.isArray(content)) {
    text = content
      .filter((c: ContentBlock) => c.type === 'text')
      .map((c: ContentBlock) => c.text || '')
      .join('\n');
  }

  if (!text) return '';

  // Truncate long results
  const lines = text.split('\n');
  if (lines.length > 20) {
    return `<details>\n<summary>${lines.length} lines</summary>\n\n\`\`\`\n${lines.slice(0, 10).join('\n')}\n... (${lines.length - 20} lines omitted)\n${lines.slice(-10).join('\n')}\n\`\`\`\n</details>`;
  }
  return `\`\`\`\n${text}\n\`\`\``;
}

export interface ConvertOptions {
  /** JSONL line offset — skip lines before this (for diff mode) */
  fromLine?: number;
  /** Stop at this line (exclusive) */
  toLine?: number;
  /** Include tool results (can be verbose) */
  includeResults?: boolean;
  /** Read last N lines only (fast tail mode — avoids loading full file) */
  tail?: number;
}

/**
 * Read last N lines from a file without loading the entire file.
 * For files < 1MB, reads the whole thing (fast enough).
 * For larger files, reads a tail chunk from the end.
 */
function readTailLines(filePath: string, n: number): { lines: string[]; totalLines: number; startLine: number } {
  const fileSize = statSync(filePath).size;

  // Small files: just read everything
  if (fileSize < 1_048_576) {
    const all = readFileSync(filePath, 'utf-8').split('\n').filter(Boolean);
    const start = Math.max(0, all.length - n);
    return { lines: all.slice(start), totalLines: all.length, startLine: start };
  }

  // Large files: read a chunk from the end
  // Average JSONL line ~2KB, so N*4KB should be generous
  const chunkSize = Math.min(fileSize, n * 4096);
  const buf = Buffer.alloc(chunkSize);
  const fd = openSync(filePath, 'r');
  try {
    readSync(fd, buf, 0, chunkSize, fileSize - chunkSize);
  } finally {
    closeSync(fd);
  }

  const chunk = buf.toString('utf-8');
  const chunkLines = chunk.split('\n').filter(Boolean);

  // First line in chunk is likely partial — drop it (unless we read from start)
  if (chunkSize < fileSize && chunkLines.length > 0) {
    chunkLines.shift();
  }

  // We don't know exact total lines without reading entire file.
  // Estimate from file size / average line size in our chunk.
  const avgLineSize = chunkSize / (chunkLines.length || 1);
  const estimatedTotal = Math.round(fileSize / avgLineSize);

  const tail = chunkLines.slice(-n);
  const startLine = Math.max(0, estimatedTotal - tail.length);

  return { lines: tail, totalLines: estimatedTotal, startLine };
}

/**
 * Extract a human-readable project name from a Claude JSONL path.
 * ~/.claude/projects/-Users-vova-Documents-GitHub-session-snapshot/abc.jsonl → "session-snapshot"
 */
export function extractProjectName(jsonlPath: string): string {
  const dirName = basename(join(jsonlPath, '..'));
  // Match after common prefixes: GitHub-, Documents-, projects-
  const match = dirName.match(/GitHub-(.+)$/) || dirName.match(/Documents-(.+)$/) || dirName.match(/projects-(.+)$/);
  if (match) return match[1];
  // Fallback: last segment
  const parts = dirName.split('-').filter(Boolean);
  return parts[parts.length - 1] || 'unknown';
}

export function convertJsonlToMd(jsonlPath: string, opts: ConvertOptions = {}): string {
  const { fromLine = 0, toLine = Infinity, includeResults = true, tail } = opts;

  let lines: string[];
  let totalLines: number;
  let effectiveFrom: number;
  let effectiveTo: number;

  if (tail) {
    // Fast tail mode
    const result = readTailLines(jsonlPath, tail);
    lines = result.lines;
    totalLines = result.totalLines;
    effectiveFrom = result.startLine;
    effectiveTo = result.startLine + lines.length;
  } else {
    // Full read mode
    const raw = readFileSync(jsonlPath, 'utf-8');
    lines = raw.split('\n').filter(Boolean);
    totalLines = lines.length;
    effectiveFrom = fromLine;
    effectiveTo = Math.min(toLine, lines.length);
    lines = lines.slice(effectiveFrom, effectiveTo);
  }

  const blocks: string[] = [];
  const sessionId = basename(jsonlPath, '.jsonl');
  const project = extractProjectName(jsonlPath);

  // Frontmatter
  blocks.push(`---\nsession: ${sessionId}\nproject: ${project}\njsonl_lines: ${effectiveFrom}-${effectiveTo}\ntotal_lines: ${totalLines}\n---\n`);

  for (let idx = 0; idx < lines.length; idx++) {
    const lineNum = effectiveFrom + idx + 1; // 1-based line number in original file
    let parsed: JsonlLine;
    try {
      parsed = JSON.parse(lines[idx]);
    } catch {
      continue;
    }

    // Skip internal ops
    if (parsed.type === 'queue-operation' || parsed.type === 'progress') continue;

    const msg = parsed.message;
    if (!msg) continue;

    const content = msg.content;
    if (!content) continue;

    if (typeof content === 'string') {
      // Plain text message
      const role = msg.role === 'user' ? 'User' : 'Assistant';
      // Truncate very long text (e.g. injected context)
      const text = content.length > 2000 ? content.slice(0, 2000) + '\n\n... (truncated)' : content;
      blocks.push(`### ${role} [L:${lineNum}]\n${text}\n`);
      continue;
    }

    if (Array.isArray(content)) {
      for (const block of content) {
        switch (block.type) {
          case 'text':
            if (block.text) {
              const role = msg.role === 'user' ? 'User' : 'Assistant';
              blocks.push(`### ${role} [L:${lineNum}]\n${block.text}\n`);
            }
            break;
          case 'thinking':
            // Skip thinking blocks — internal
            break;
          case 'tool_use':
            blocks.push(`${formatToolUse(block)} [L:${lineNum}]\n`);
            break;
          case 'tool_result':
            if (includeResults) {
              const result = formatToolResult(block);
              if (result) blocks.push(`${result}\n`);
            }
            break;
        }
      }
    }
  }

  return blocks.join('\n');
}

/** CLI: node --experimental-strip-types src/jsonl-to-md.ts <input.jsonl> [output.md] [--from N] [--to N] [--tail N] */
if (process.argv[1]?.endsWith('jsonl-to-md.ts')) {
  const args = process.argv.slice(2);

  // Separate positional args from flags
  const positional: string[] = [];
  const flags: Record<string, string> = {};
  const boolFlags = new Set<string>();

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--no-results') {
      boolFlags.add('no-results');
    } else if (args[i].startsWith('--') && i + 1 < args.length) {
      flags[args[i].slice(2)] = args[i + 1];
      i++; // skip value
    } else if (!args[i].startsWith('--')) {
      positional.push(args[i]);
    }
  }

  const inputPath = positional[0];
  if (!inputPath) {
    console.error('Usage: jsonl-to-md.ts <input.jsonl> [output.md] [--from N] [--to N] [--tail N] [--no-results]');
    process.exit(1);
  }

  const outputPath = positional[1];
  const fromLine = parseInt(flags.from) || 0;
  const toLine = parseInt(flags.to) || Infinity;
  const tail = parseInt(flags.tail) || undefined;
  const includeResults = !boolFlags.has('no-results');

  const md = convertJsonlToMd(inputPath, { fromLine, toLine, tail, includeResults });

  if (outputPath) {
    writeFileSync(outputPath, md);
    console.log(`Wrote ${(md.length / 1024).toFixed(0)}KB to ${outputPath}`);
  } else {
    process.stdout.write(md);
  }
}
