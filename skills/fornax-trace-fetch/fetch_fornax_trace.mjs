#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const DEFAULT_WORKSPACE_ID = '7590084861042927618';
const DEFAULT_LAST_N_MINUTES = '43200';

function usage() {
  console.error(`Usage:
  fetch_fornax_trace.mjs <trace-id|log-id|fornax-url> [options]

Options:
  --trace-id <id>          Explicit trace ID
  --log-id <id>            Explicit log ID
  --workspace-id <id>      Fornax workspace ID, default ${DEFAULT_WORKSPACE_ID}
  --last-n-minutes <n>     Query time window, default ${DEFAULT_LAST_N_MINUTES}
  --since <iso>            Optional query start time
  --until <iso>            Optional query end time
  --out <dir>              Output directory
  --chunk-size <n>         Span detail chunk size, default 80
  --retries <n>            Detail chunk retries, default 3
`);
}

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) {
      args._.push(arg);
      continue;
    }
    const key = arg.slice(2);
    if (key === 'help') {
      args.help = true;
      continue;
    }
    const value = argv[i + 1];
    if (!value || value.startsWith('--')) {
      throw new Error(`missing value for --${key}`);
    }
    args[key] = value;
    i += 1;
  }
  return args;
}

function parseTarget(raw) {
  const target = { raw: raw || '' };
  if (!raw) return target;
  try {
    const url = new URL(raw);
    const spaceMatch = url.pathname.match(/\/space\/(\d+)\//);
    if (spaceMatch) target.workspaceId = spaceMatch[1];
    const tracePath = url.pathname.match(/\/analytics\/trace\/([^/?#]+)/);
    if (tracePath) {
      target.traceId = decodeURIComponent(tracePath[1]);
      return target;
    }
    const queryType = url.searchParams.get('queryType');
    const queryId = url.searchParams.get('queryID');
    if (queryType === 'trace_id' && queryId) target.traceId = queryId;
    if (queryType === 'log_id' && queryId) target.logId = queryId;
    return target;
  } catch {
    // Plain ID.
  }
  if (/^[0-9a-fA-F]{30,80}$/.test(raw)) {
    target.traceId = raw;
  } else {
    target.logId = raw;
  }
  return target;
}

function run(cmd, args, options = {}) {
  const proc = spawnSync(cmd, args, {
    stdio: options.stdio || ['ignore', 'pipe', 'pipe'],
    encoding: 'utf8',
  });
  if (proc.status !== 0) {
    const stderr = (proc.stderr || '').trim();
    const stdout = (proc.stdout || '').trim();
    throw new Error(`${cmd} ${args.join(' ')} failed (${proc.status})\n${stderr || stdout}`);
  }
  return proc;
}

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function runWithRetries(cmd, args, retries) {
  let lastError = null;
  for (let attempt = 1; attempt <= retries + 1; attempt += 1) {
    try {
      return run(cmd, args);
    } catch (error) {
      lastError = error;
      if (attempt > retries) break;
      console.error(`retry ${attempt}/${retries}: ${error.message.split('\n')[0]}`);
      sleepSync(Math.min(1000 * attempt, 5000));
    }
  }
  throw lastError;
}

// fornax-cli 输出 JSONL（每行一个 span），bytedcli fornax 输出 JSON 数组。
// 两种都要兼容：先试整体解析（数组），失败则按行解析（JSONL）。
function readJson(file) {
  const text = fs.readFileSync(file, 'utf8');
  try {
    return JSON.parse(text);
  } catch {
    return text.split('\n').filter((line) => line.trim()).map((line) => JSON.parse(line));
  }
}

function writeJson(file, data) {
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n');
}

function mkdirp(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function outputFile(outDir, key, suffix = '') {
  return path.join(outDir, `trace_${key}${suffix}.json`);
}

// fornax-cli 是 bytedcli fornax 子命令背后的独立二进制（~/.local/bin/fornax-cli），
// 命令参数与 bytedcli fornax trace get 完全兼容。在某些环境（如 launchd daemon）下
// bytedcli 的 fornax 子命令注册会失效（报 "unknown command 'trace'"），直接调
// fornax-cli 二进制更可靠。优先 fornax-cli，回退 bytedcli。
const FORNAX_CLI_BIN = (() => {
  const home = process.env.HOME || '';
  return home ? `${home}/.local/bin/fornax-cli` : 'fornax-cli';
})();
function fornaxCommand() {
  // 检测 fornax-cli 二进制是否存在
  try {
    if (fs.existsSync(FORNAX_CLI_BIN) && fs.accessSync(FORNAX_CLI_BIN, fs.constants.X_OK) === undefined) {
      return { cmd: FORNAX_CLI_BIN, prefix: [] };
    }
  } catch { /* ignore */ }
  return { cmd: 'bytedcli', prefix: ['fornax'] };
}

function bytedcliBaseArgs(target, workspaceId, args) {
  const { prefix } = fornaxCommand();
  const cmdArgs = [...prefix, 'trace', 'get'];
  if (target.traceId) cmdArgs.push('--trace-id', target.traceId);
  if (target.logId) cmdArgs.push('--log-id', target.logId);
  cmdArgs.push('--workspace-id', workspaceId);
  if (args.since && args.until) {
    cmdArgs.push('--since', args.since, '--until', args.until);
  } else if (args['last-n-minutes']) {
    cmdArgs.push('--last-n-minutes', String(args['last-n-minutes']));
  }
  return cmdArgs;
}

function parseEncrypt(value) {
  if (!value || typeof value !== 'string') return null;
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function inputLen(span, field) {
  const value = span?.[field];
  if (value == null) return 0;
  if (typeof value === 'string') return value.length;
  return JSON.stringify(value).length;
}

function summarize(details) {
  const stats = {
    total_spans: details.length,
    encrypted_tag_spans: 0,
    decrypt_success_true: 0,
    decrypt_success_false: 0,
    decrypt_success_unknown: 0,
  };
  for (const span of details) {
    const enc = parseEncrypt(span?.system_tags?.reserved_encrypt);
    if (!enc) {
      stats.decrypt_success_unknown += 1;
      continue;
    }
    stats.encrypted_tag_spans += 1;
    if (enc.decrypt_success === true) stats.decrypt_success_true += 1;
    else if (enc.decrypt_success === false) stats.decrypt_success_false += 1;
    else stats.decrypt_success_unknown += 1;
  }
  return stats;
}

function buildDepths(spans) {
  const byId = new Map(spans.map((span) => [String(span.span_id), span]));
  const memo = new Map();
  function depthOf(span) {
    const id = String(span.span_id || '');
    if (memo.has(id)) return memo.get(id);
    const parent = String(span.parent_id || span.parent_span_id || '');
    if (!parent || parent === '0' || !byId.has(parent)) {
      memo.set(id, 0);
      return 0;
    }
    const depth = depthOf(byId.get(parent)) + 1;
    memo.set(id, depth);
    return depth;
  }
  for (const span of spans) depthOf(span);
  return memo;
}

function tsvEscape(value) {
  return String(value ?? '').replace(/\t/g, ' ').replace(/\r?\n/g, ' ');
}

function writeSummary(file, spans) {
  const depths = buildDepths(spans);
  const rows = [[
    'depth',
    'span_id',
    'parent_id',
    'span_name',
    'span_type',
    'duration',
    'status',
    'status_code',
    'input_len',
    'output_len',
    'decrypt_success',
  ]];
  for (const span of spans) {
    const enc = parseEncrypt(span?.system_tags?.reserved_encrypt);
    rows.push([
      depths.get(String(span.span_id)) ?? 0,
      span.span_id || '',
      span.parent_id || span.parent_span_id || '',
      span.span_name || '',
      span.span_type || span.type || '',
      span.duration ?? '',
      span.status ?? '',
      span.status_code ?? '',
      inputLen(span, 'input'),
      inputLen(span, 'output'),
      enc ? String(enc.decrypt_success) : '',
    ]);
  }
  fs.writeFileSync(file, rows.map((row) => row.map(tsvEscape).join('\t')).join('\n') + '\n');
}

function uniqueBySpanId(spans) {
  const out = [];
  const seen = new Set();
  for (const span of spans) {
    const key = String(span.span_id || `${span.trace_id}:${out.length}`);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(span);
  }
  return out;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    return;
  }
  const raw = args._[0] || '';
  const parsed = parseTarget(raw);
  if (args['trace-id']) parsed.traceId = args['trace-id'];
  if (args['log-id']) parsed.logId = args['log-id'];
  if (!parsed.traceId && !parsed.logId) {
    usage();
    throw new Error('missing trace/log target');
  }
  if (parsed.traceId && parsed.logId) throw new Error('trace-id and log-id are mutually exclusive');

  const workspaceId = String(args['workspace-id'] || parsed.workspaceId || DEFAULT_WORKSPACE_ID);
  args['last-n-minutes'] = args['last-n-minutes'] || DEFAULT_LAST_N_MINUTES;
  const key = parsed.traceId || parsed.logId;
  const outDir = path.resolve(args.out || path.join('/tmp', `fornax-trace-${key}-${Date.now()}`));
  mkdirp(outDir);

  const fornaxCmd = fornaxCommand().cmd;
  const treeArgs = bytedcliBaseArgs(parsed, workspaceId, args).concat(['--tree', '-o', outDir]);
  run(fornaxCmd, treeArgs);
  const treeFile = outputFile(outDir, key, '_tree');
  const tree = readJson(treeFile);
  const spans = Array.isArray(tree) ? tree : [];
  const spanIds = spans.map((span) => span.span_id).filter(Boolean);
  fs.copyFileSync(treeFile, path.join(outDir, 'trace_tree.json'));

  const chunkSize = Math.max(1, Number(args['chunk-size'] || 80));
  const retries = Math.max(0, Number(args.retries || 3));
  const detailChunks = [];
  const chunksDir = path.join(outDir, 'chunks');
  mkdirp(chunksDir);
  for (let i = 0; i < spanIds.length; i += chunkSize) {
    const chunk = spanIds.slice(i, i + chunkSize);
    const chunkDir = path.join(chunksDir, `chunk_${String(i / chunkSize + 1).padStart(3, '0')}`);
    mkdirp(chunkDir);
    const detailArgs = bytedcliBaseArgs(parsed, workspaceId, args).concat([
      '--span-id',
      chunk.join(','),
      '-o',
      chunkDir,
    ]);
    runWithRetries(fornaxCmd, detailArgs, retries);
    const detailFile = outputFile(chunkDir, key);
    const detailData = readJson(detailFile);
    if (Array.isArray(detailData)) detailChunks.push(...detailData);
  }
  const details = uniqueBySpanId(detailChunks);
  const detailOut = path.join(outDir, 'trace_details.json');
  writeJson(detailOut, details);
  const summaryOut = path.join(outDir, 'span_summary.tsv');
  writeSummary(summaryOut, details.length ? details : spans);

  const metadata = {
    target: {
      raw,
      trace_id: parsed.traceId || '',
      log_id: parsed.logId || '',
      workspace_id: workspaceId,
    },
    counts: {
      tree_spans: spans.length,
      detail_spans: details.length,
    },
    decrypt: summarize(details),
    files: {
      out_dir: outDir,
      trace_tree: path.join(outDir, 'trace_tree.json'),
      trace_details: detailOut,
      span_summary: summaryOut,
      metadata: path.join(outDir, 'metadata.json'),
    },
  };
  writeJson(metadata.files.metadata, metadata);
  console.log(JSON.stringify(metadata, null, 2));
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
