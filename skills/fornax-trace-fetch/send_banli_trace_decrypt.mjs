#!/usr/bin/env node
import { spawnSync } from 'node:child_process';

const DEFAULT_CHAT_ID = 'oc_281c368b7b46b13b49acc96d0f650d70';
const DEFAULT_BANLI_OPEN_ID = 'ou_de6be1a2db0fe8694892cb9ec2491586';

function usage() {
  console.error(`Usage:
  send_banli_trace_decrypt.mjs <record-url> [options]

Options:
  --chat-id <oc_xxx>       Group chat ID, default trace解密专用群
  --banli-open-id <ou_xxx> Banli mention open ID
  --as <bot|user>          lark-cli identity, default bot
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
    if (arg === '--help') {
      args.help = true;
      continue;
    }
    const key = arg.slice(2);
    const value = argv[i + 1];
    if (!value || value.startsWith('--')) throw new Error(`missing value for --${key}`);
    args[key] = value;
    i += 1;
  }
  return args;
}

function recordIdFromUrl(url) {
  const match = String(url || '').match(/bpm\.bytedance\.net\/record\/(\d+)/);
  return match ? match[1] : '';
}

function safeError(text) {
  return String(text || '')
    .replace(/\beyJ[A-Za-z0-9._-]{20,}\b/g, '<jwt>')
    .replace(/\b(authorization)(\s*[:=]\s*)[^,\r\n]+/gi, (_match, key, sep) => `${key}${sep}<redacted>`)
    .replace(/\b(jwt|cookie|session|token|secret|access[_-]?key|ak|sk)(\s*[:=]\s*)[^,\s"'}]+/gi, (_match, key, sep) => `${key}${sep}<redacted>`)
    .slice(0, 1000);
}

function runJson(cmd, args) {
  const proc = spawnSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const text = `${proc.stdout || ''}\n${proc.stderr || ''}`.trim();
  let data = null;
  try {
    data = JSON.parse(text);
  } catch {
    for (const line of text.split(/\r?\n/).reverse()) {
      try {
        data = JSON.parse(line);
        break;
      } catch {
        // Try previous line.
      }
    }
  }
  if (proc.status !== 0) throw new Error(safeError(text || `${cmd} failed with ${proc.status}`));
  if (!data) throw new Error(`cannot parse JSON output from ${cmd}`);
  return data;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    return;
  }
  const recordUrl = args._[0] || '';
  if (!recordIdFromUrl(recordUrl)) {
    usage();
    throw new Error('first argument must be a BPM record URL');
  }
  const chatId = args['chat-id'] || DEFAULT_CHAT_ID;
  const banliOpenId = args['banli-open-id'] || DEFAULT_BANLI_OPEN_ID;
  const identity = args.as || 'bot';
  const recordId = recordIdFromUrl(recordUrl);
  const content = {
    text: `${recordUrl} <at user_id="${banliOpenId}">板栗</at>`,
  };
  const result = runJson('lark-cli', [
    'im',
    '+messages-send',
    '--chat-id',
    chatId,
    '--content',
    JSON.stringify(content),
    '--msg-type',
    'text',
    '--as',
    identity,
    '--idempotency-key',
    `fornax-decrypt-${recordId}-banli-group`,
  ]);
  console.log(JSON.stringify({
    ok: true,
    status: 'sent',
    chat_id: chatId,
    record_id: recordId,
    record_url: recordUrl,
    message_id: result?.data?.message_id || '',
    message_position: result?.data?.message_position || '',
  }, null, 2));
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
