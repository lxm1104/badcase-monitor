#!/usr/bin/env node
import { spawnSync } from 'node:child_process';

function usage() {
  console.error(`Usage:
  wait_banli_done.mjs --chat-id <oc_xxx> [--record-url <url>|--record-id <id>] [options]

Options:
  --timeout-sec <n>      Total wait time, default 900
  --interval-sec <n>     Poll interval, default 10
  --after-position <n>   Only accept done after this message position
  --page-size <n>        Messages per poll, default 20
  --as <bot|user>        lark-cli identity, default bot
`);
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--help') {
      args.help = true;
      continue;
    }
    if (!arg.startsWith('--')) throw new Error(`unexpected argument ${arg}`);
    const key = arg.slice(2);
    const value = argv[i + 1];
    if (!value || value.startsWith('--')) throw new Error(`missing value for --${key}`);
    args[key] = value;
    i += 1;
  }
  return args;
}

// 只解析 stdout，不拼 stderr：lark-cli 的 warning（如 reactions_partial_failed）走 stderr，
// 拼进 JSON 解析会导致 "cannot parse JSON" 让 wait_banli 提前崩溃（板栗还没批就退出）。
function runJson(cmd, args) {
  const proc = spawnSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const stdout = (proc.stdout || '').trim();
  const stderr = (proc.stderr || '').trim();
  let data = null;
  try {
    data = JSON.parse(stdout);
  } catch {
    // stdout 不是整体 JSON（可能是多行混杂），逐行反向找第一个合法 JSON
    for (const line of stdout.split(/\r?\n/).reverse()) {
      try {
        data = JSON.parse(line);
        break;
      } catch {
        // Try previous line.
      }
    }
  }
  if (proc.status !== 0) throw new Error(safeError(stderr || stdout || `${cmd} failed with ${proc.status}`));
  if (!data) throw new Error(`cannot parse JSON output from ${cmd} (stderr: ${stderr.slice(0, 200)})`);
  return data;
}

function safeError(text) {
  return String(text || '')
    .replace(/\beyJ[A-Za-z0-9._-]{20,}\b/g, '<jwt>')
    .replace(/\b(authorization)(\s*[:=]\s*)[^,\r\n]+/gi, (_match, key, sep) => `${key}${sep}<redacted>`)
    .replace(/\b(jwt|cookie|session|token|secret|access[_-]?key|ak|sk)(\s*[:=]\s*)[^,\s"'}]+/gi, (_match, key, sep) => `${key}${sep}<redacted>`)
    .slice(0, 1000);
}

function ticketDone(recordId) {
  if (!recordId) return null;
  const data = runJson('bytedcli', ['--json', 'bpm', 'ticket', 'get', '--ticket-id', recordId]);
  const ticket = data?.data;
  if (!ticket) return null;
  const status = String(ticket.status || '');
  const finished = Number(ticket.finished || 0);
  if (status === 'failed' || status === 'rejected' || status === 'canceled' || finished === 2) {
    return {
      ok: false,
      status: 'bpm_not_approved',
      record_id: recordId,
      ticket_status: status,
      status_name: ticket.status_name || '',
      update_time: ticket.update_time || ticket.utime || '',
    };
  }
  if (status === 'done' || finished === 1) {
    return {
      ok: true,
      status: 'bpm_done',
      record_id: recordId,
      ticket_status: status,
      status_name: ticket.status_name || '',
      update_time: ticket.update_time || ticket.utime || '',
    };
  }
  return null;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function recordIdFromUrl(url) {
  const match = String(url || '').match(/bpm\.bytedance\.net\/record\/(\d+)/);
  return match ? match[1] : '';
}

function contentText(message) {
  const raw = message?.content;
  if (typeof raw !== 'string') return '';
  try {
    const parsed = JSON.parse(raw);
    return parsed.text || parsed.content || raw;
  } catch {
    return raw;
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    return;
  }
  if (!args['chat-id']) throw new Error('missing --chat-id');
  const recordId = args['record-id'] || recordIdFromUrl(args['record-url']);
  const timeoutSec = Number(args['timeout-sec'] || 900);
  const intervalSec = Number(args['interval-sec'] || 10);
  const pageSize = Number(args['page-size'] || 20);
  const identity = args.as || 'bot';
  let afterPosition = Number(args['after-position'] || 0);
  const deadline = Date.now() + timeoutSec * 1000;

  while (Date.now() < deadline) {
    // ticketDone 是主信号（BPM 工单状态）。它内部调 bytedcli，偶发失败时不应崩溃——
    // 返回 null 表示"本轮未确定"，下一轮重试即可。
    let doneByTicket = null;
    try {
      doneByTicket = ticketDone(recordId);
    } catch (e) {
      // bytedcli 查询偶发失败，跳过本轮靠下一轮重试
    }
    if (doneByTicket) {
      console.log(JSON.stringify(doneByTicket, null, 2));
      process.exit(doneByTicket.ok ? 0 : 2);
    }
    // lark-cli 查群消息是 BPM 工单状态的 fallback。它可能因 warning 混入输出等原因
    // 偶发解析失败——这种情况不应让整个等待崩溃（板栗可能还没批），跳过本轮继续轮询。
    let messages = [];
    try {
      const data = runJson('lark-cli', [
        'im',
        '+chat-messages-list',
        '--chat-id',
        args['chat-id'],
        '--format',
        'json',
        '--as',
        identity,
        '--page-size',
        String(pageSize),
      ]);
      messages = data?.data?.messages || [];
    } catch (e) {
      // fallback 查询失败，靠下一轮的 ticketDone（主信号）继续，不中断等待
    }
    if (recordId && !afterPosition) {
      const sent = messages.find((message) => contentText(message).includes(recordId));
      if (sent?.message_position) afterPosition = Number(sent.message_position);
    }
    const done = messages.find((message) => {
      const position = Number(message?.message_position || 0);
      if (afterPosition && position <= afterPosition) return false;
      return /\bdone\b/i.test(contentText(message));
    });
    if (done) {
      console.log(JSON.stringify({
        ok: true,
        status: 'done',
        record_id: recordId || '',
        after_position: afterPosition || '',
        message: {
          message_id: done.message_id,
          message_position: done.message_position,
          create_time: done.create_time,
          sender: done.sender?.name || done.sender?.id || '',
          matched_keyword: 'done',
        },
      }, null, 2));
      return;
    }
    await sleep(intervalSec * 1000);
  }
  console.log(JSON.stringify({
    ok: false,
    status: 'timeout',
    record_id: recordId || '',
    after_position: afterPosition || '',
  }, null, 2));
  process.exit(2);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
