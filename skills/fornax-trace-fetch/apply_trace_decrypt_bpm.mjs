#!/usr/bin/env node
import { spawnSync } from 'node:child_process';

const DEFAULT_WORKSPACE_ID = '7590084861042927618';
const DEFAULT_VALID_DAY = '29';
const DEFAULT_REASON = 'debug';
const DEFAULT_WORKFLOW_CONFIG_ID = 32544;
const DEFAULT_BPM_API_BASE = 'https://cloud.bytedance.net';

function usage() {
  console.error(`Usage:
  apply_trace_decrypt_bpm.mjs <trace-id|fornax-url> [options]

Options:
  --trace-id <id>              Explicit trace ID
  --workspace-id <id>          Workspace ID, default ${DEFAULT_WORKSPACE_ID}
  --valid-day <days>           Valid days, default ${DEFAULT_VALID_DAY}
  --reason <text>              Apply reason, default ${DEFAULT_REASON}
  --workflow-config-id <id>    Workflow config, default ${DEFAULT_WORKFLOW_CONFIG_ID}
  --bpm-api-base <url>         BPM API base, default ${DEFAULT_BPM_API_BASE}
  --dry-run                    Print payload without posting
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
    if (key === 'help' || key === 'dry-run') {
      args[key] = true;
      continue;
    }
    const value = argv[i + 1];
    if (!value || value.startsWith('--')) throw new Error(`missing value for --${key}`);
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
    if (tracePath) target.traceId = decodeURIComponent(tracePath[1]);
    if (url.searchParams.get('queryType') === 'trace_id' && url.searchParams.get('queryID')) {
      target.traceId = url.searchParams.get('queryID');
    }
    return target;
  } catch {
    target.traceId = raw;
    return target;
  }
}

function runJson(cmd, args) {
  const proc = spawnSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const text = `${proc.stdout || ''}\n${proc.stderr || ''}`.trim();
  let data = null;
  for (const line of text.split(/\r?\n/).reverse()) {
    try {
      data = JSON.parse(line);
      break;
    } catch {
      // Try previous line.
    }
  }
  if (proc.status !== 0) throw new Error(redact(text || `${cmd} failed with ${proc.status}`));
  if (!data) throw new Error(`cannot parse JSON output from ${cmd}`);
  return data;
}

function redact(text) {
  return String(text)
    .replace(/\beyJ[A-Za-z0-9._-]{20,}\b/g, '<jwt>')
    .replace(/\b(authorization)(\s*[:=]\s*)[^,\r\n]+/gi, (_match, key, sep) => `${key}${sep}<redacted>`)
    .replace(/\b(jwt|cookie|session|token|secret|access[_-]?key|ak|sk)(\s*[:=]\s*)[^,\s"'}]+/gi, (_match, key, sep) => `${key}${sep}<redacted>`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    return;
  }
  const target = parseTarget(args._[0] || '');
  if (args['trace-id']) target.traceId = args['trace-id'];
  if (!target.traceId) {
    usage();
    throw new Error('missing trace id');
  }
  const workspaceId = String(args['workspace-id'] || target.workspaceId || DEFAULT_WORKSPACE_ID);
  const validDay = String(args['valid-day'] || DEFAULT_VALID_DAY);
  const reason = String(args.reason || DEFAULT_REASON);
  const workflowConfigId = Number(args['workflow-config-id'] || DEFAULT_WORKFLOW_CONFIG_ID);
  const base = String(args['bpm-api-base'] || DEFAULT_BPM_API_BASE).replace(/\/+$/, '');
  const body = {
    workflow_config_id: workflowConfigId,
    config: {
      trace_id: target.traceId,
      workspace_id: workspaceId,
      valid_day: validDay,
      reasoning: reason,
    },
  };
  if (args['dry-run']) {
    console.log(JSON.stringify({ ok: true, status: 'dry_run', request: { url: `${base}/api/v1/bpm/api/inf/v1/workflow/record/`, body } }, null, 2));
    return;
  }

  const jwtData = runJson('bytedcli', ['--json', 'auth', 'get-bytecloud-jwt-token']);
  const jwt = jwtData?.data?.jwt || jwtData?.jwt;
  if (!jwt) throw new Error('bytedcli did not return a ByteCloud JWT');

  const response = await fetch(`${base}/api/v1/bpm/api/inf/v1/workflow/record/`, {
    method: 'POST',
    headers: {
      Accept: 'application/json, text/plain, */*',
      'Content-Type': 'application/json; charset=utf-8',
      'X-Jwt-Token': jwt,
      Origin: base,
      Referer: `${base}/`,
    },
    body: JSON.stringify(body),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || payload.code !== 0) {
    throw new Error(redact(JSON.stringify({ status: response.status, payload }).slice(0, 1000)));
  }
  const id = payload?.data?.id || payload?.data?.record_id;
  if (!id) throw new Error(`BPM response did not include record id: ${JSON.stringify(payload).slice(0, 500)}`);
  const recordUrl = `https://bpm.bytedance.net/record/${id}`;
  console.log(JSON.stringify({
    ok: true,
    status: 'submitted',
    record_id: String(id),
    record_url: recordUrl,
    data: {
      workflow_key: payload?.data?.workflow_key,
      workflow_name: payload?.data?.workflow_name,
      target_system: payload?.data?.target_system,
      status: payload?.data?.status,
    },
  }, null, 2));
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
