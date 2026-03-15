/**
 * JSONL → MD diff converter.
 * Converts Claude Code session JSONL to readable Markdown, block by block.
 * No AI involved — pure deterministic parsing.
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
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
}

export function convertJsonlToMd(jsonlPath: string, opts: ConvertOptions = {}): string {
  const { fromLine = 0, toLine = Infinity, includeResults = true } = opts;

  const raw = readFileSync(jsonlPath, 'utf-8');
  const lines = raw.split('\n').filter(Boolean);

  const blocks: string[] = [];
  const sessionId = '';
  let project = '';

  // Extract project name from path
  const dirName = basename(join(jsonlPath, '..'));
  const parts = dirName.split('-').filter(Boolean);
  project = parts[parts.length - 1] || 'unknown';

  // Frontmatter
  blocks.push(`---\nsession: ${basename(jsonlPath, '.jsonl')}\nproject: ${project}\njsonl_lines: ${fromLine}-${Math.min(toLine, lines.length)}\ntotal_lines: ${lines.length}\n---\n`);

  for (let i = fromLine; i < Math.min(toLine, lines.length); i++) {
    let parsed: JsonlLine;
    try {
      parsed = JSON.parse(lines[i]);
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
      blocks.push(`### ${role} [L:${i + 1}]\n${text}\n`);
      continue;
    }

    if (Array.isArray(content)) {
      for (const block of content) {
        switch (block.type) {
          case 'text':
            if (block.text) {
              const role = msg.role === 'user' ? 'User' : 'Assistant';
              blocks.push(`### ${role} [L:${i + 1}]\n${block.text}\n`);
            }
            break;
          case 'thinking':
            // Skip thinking blocks — internal
            break;
          case 'tool_use':
            blocks.push(`${formatToolUse(block)} [L:${i + 1}]\n`);
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

/** CLI: node --experimental-strip-types src/jsonl-to-md.ts <input.jsonl> [output.md] [--from N] [--to N] */
if (process.argv[1]?.endsWith('jsonl-to-md.ts')) {
  const args = process.argv.slice(2);
  const inputPath = args.find(a => !a.startsWith('--'));
  if (!inputPath) {
    console.error('Usage: jsonl-to-md.ts <input.jsonl> [output.md] [--from N] [--to N] [--no-results]');
    process.exit(1);
  }

  const outputPath = args.find((a, i) => i > 0 && !a.startsWith('--'));
  const fromLine = parseInt(args[args.indexOf('--from') + 1]) || 0;
  const toLine = parseInt(args[args.indexOf('--to') + 1]) || Infinity;
  const includeResults = !args.includes('--no-results');

  const md = convertJsonlToMd(inputPath, { fromLine, toLine, includeResults });

  if (outputPath) {
    writeFileSync(outputPath, md);
    console.log(`Wrote ${(md.length / 1024).toFixed(0)}KB to ${outputPath}`);
  } else {
    process.stdout.write(md);
  }
}
