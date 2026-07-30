#!/usr/bin/env bash
# Badcase 群事件订阅常驻分析 Daemon（含 autofix 自动修复）
#
# 通过 lark-cli event consume（WebSocket 长连接）实时接收 badcase 群所有新消息，
# 自动抽取消息中的日志 ID（run_log_id），跑完整链路：
#   抽 ID → 查 trace_id → 抓 trace → 解密（全自动 @板栗）→ LLM 根因分析 → bot 自动回复到 thread
#
# autofix 自动修复模块（在本结论帖发出后自动启动，状态机见脚本中段）：
#   结论帖 → 独立复核根因(复用 trace 缓存) → 评估复杂度 →
#   简单可自动改(≤3文件无外部库)则发修改计划到 thread → 等刘昕明显式同意 →
#   zcode 全自动切 develop → 改 → 提 MR → 把 MR 链接发回 thread 请人 review。
#   审批复用本主循环（刘昕明回复即推进），72h 超时挂起。thread 内讨论作为修改依据。
#
# 与 feishu_feedback_monitor.sh 的根本差异：
#   - 那是「轮询 one-shot」（StartInterval 触发，每次拉增量后退出）
#   - 本脚本是「事件订阅长连接」（event consume 常驻，实时推送）
#   因此 launchd 必须用 KeepAlive=true + RunAtLoad=true（无 StartInterval），见配套 plist。
#
# 用法：
#   ./badcase_event_monitor.sh                  # 常驻消费事件（正式运行）
#   ./badcase_event_monitor.sh --once <om_xxx>  # 调试：只处理一条已知 message_id（需能从事件或拉取取到）
#   ./badcase_event_monitor.sh --once <om_xxx> --log-id <id>  # 历史合并转发正文已过期时，用已核验 ID 重放
#   ./badcase_event_monitor.sh --dry-reply      # 全链路跑但不实际回复（回复前 dry-run）
#   ./badcase_event_monitor.sh --once-autofix <task_id> [review|execute]  # 调试：重放某 autofix 任务阶段
set -euo pipefail
# trace、模型临时响应和幂等账本都只允许当前用户访问；子进程继承该 umask。
umask 077

# macOS bash 3.2 在 C/POSIX locale 下会把紧跟变量的 UTF-8 多字节字符吸进变量名，
# 导致 "unbound variable" 崩溃（badcase 消息含大量中文）。强制 UTF-8 locale。
if locale -a 2>/dev/null | grep -qi '^en_US\.UTF-8$\|^en_US.UTF-8$'; then
  export LC_ALL=en_US.UTF-8
elif locale -a 2>/dev/null | grep -qi 'UTF-8'; then
  export LC_ALL="$(locale -a 2>/dev/null | grep -i 'UTF-8' | head -1)"
fi

# ============ 可配置项 ============
# 敏感配置从 ~/.badcase_event_env 读取（set -a 导出），避免在 plist 明文带 key。
ENV_FILE="${BADCASE_ENV_FILE:-$HOME/.badcase_event_env}"
[[ -f "$ENV_FILE" ]] && set -a && . "$ENV_FILE" && set +a

# Badcase 群：「【 Badcase 】Chatbot badcase 收集跟进群」，THREAD 话题群
CHAT_ID="${BADCASE_CHAT_ID:-oc_d7a5dad130014974a65baf2b40e65ce5}"
STATE_DIR="${BADCASE_STATE_DIR:-$HOME/.badcase_event_state}"

# 所有依赖脚本都放在 DAEMON_ROOT 下（working-workspace，不受 git 仓库分支切换影响）。
# 用脚本自身位置推导 DAEMON_ROOT，这样整个目录可整体移动；也可被环境变量覆盖。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_ROOT="${BADCASE_DAEMON_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# fornax-trace-fetch 脚本目录（trace 抓取 + 解密 BPM 全流程）
FORNAX_SCRIPTS="$DAEMON_ROOT/skills/fornax-trace-fetch"
# run_log_id → trace_id 查找脚本
FIND_RUNLOG="$DAEMON_ROOT/scripts/find-runlog-log.sh"
# trace-decrypt-analyze skill 完整方法论（注入 LLM 分析 prompt，保证 daemon 分析质量
# 与人肉跑 skill 一致：B1-B6 核对、工具谎报成功识别、问题 span I/O 原文呈现、根因归类等）。
# 默认读 ~/.agents 下的 skill（用户的唯一维护源，改了自动生效，无需手动同步副本）；
# 不可用时回退到 DAEMON_ROOT 下的离线副本。可用 TRACE_ANALYZE_SKILL 环境变量强制覆盖。
if [[ -z "${TRACE_ANALYZE_SKILL:-}" ]]; then
  if [[ -f "$HOME/.agents/skills/trace-decrypt-analyze/SKILL.md" ]]; then
    TRACE_ANALYZE_SKILL="$HOME/.agents/skills/trace-decrypt-analyze/SKILL.md"
  else
    TRACE_ANALYZE_SKILL="$DAEMON_ROOT/skills/trace-decrypt-analyze/SKILL.md"
  fi
fi
# ZCode 分析会话的工作目录（决定分析时可访问的代码上下文，指向 chatbot 仓库）。
# 仅用于 --cwd，不用于定位依赖脚本（那些都在 DAEMON_ROOT 下）。
REPO_ROOT="${BADCASE_REPO_ROOT:-/Users/xinming/MyProject/bitable-chatbot}"

# Fornax 工作区（chatbot 团队加密空间）
FORNAX_WORKSPACE_ID="${FORNAX_WORKSPACE_ID:-7590084861042927618}"
# trace 解密专用群（@板栗 用）
DECRYPT_CHAT_ID="${DECRYPT_CHAT_ID:-oc_281c368b7b46b13b49acc96d0f650d70}"

# ZCode headless 分析会话三件套（同 feishu_feedback_monitor，避免继承 ZCode app 注入的错误 ZCODE_BASE_URL）
ZCODE_CJS="${ZCODE_CJS:-/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs}"
BIGMODEL_MODEL="${BIGMODEL_MODEL:-bigmodel-coding-plan/glm-5.1}"
BIGMODEL_BASE_URL="${BIGMODEL_BASE_URL:-https://open.bigmodel.cn/api/anthropic}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:?需要设置 ANTHROPIC_API_KEY（写入 ~/.badcase_event_env）}"
export ZCODE_MODEL="$BIGMODEL_MODEL"
export ZCODE_BASE_URL="$BIGMODEL_BASE_URL"
# 单条 case 从开始处理到最终分析的总预算为 1 小时。阶段调查先尽快形成可见进展，
# 深度复核允许长时间运行；所有重试和退避都受同一个绝对截止时间约束。
ANALYSIS_TOTAL_TIMEOUT="${ANALYSIS_TOTAL_TIMEOUT:-3600}"
ANALYSIS_PRELIMINARY_TIMEOUT="${ANALYSIS_PRELIMINARY_TIMEOUT:-600}"
ANALYSIS_PRELIMINARY_ATTEMPT_TIMEOUT="${ANALYSIS_PRELIMINARY_ATTEMPT_TIMEOUT:-420}"
ANALYSIS_DEEP_ATTEMPT_TIMEOUT="${ANALYSIS_DEEP_ATTEMPT_TIMEOUT:-900}"
ANALYSIS_EVIDENCE_ROUND_TIMEOUT="${ANALYSIS_EVIDENCE_ROUND_TIMEOUT:-1200}"
ANALYSIS_MAX_EVIDENCE_ROUNDS="${ANALYSIS_MAX_EVIDENCE_ROUNDS:-4}"
ANALYSIS_MAX_EVIDENCE_SPANS="${ANALYSIS_MAX_EVIDENCE_SPANS:-12}"
ANALYSIS_CATALOG_PREVIEW_CHARS="${ANALYSIS_CATALOG_PREVIEW_CHARS:-1500}"
ANALYSIS_PROGRESS_INTERVAL="${ANALYSIS_PROGRESS_INTERVAL:-900}"
ANALYSIS_POLL_INTERVAL="${ANALYSIS_POLL_INTERVAL:-15}"
ZCODE_MAX_RETRY="${ZCODE_MAX_RETRY:-8}"
ZCODE_RETRY_BACKOFF="${ZCODE_RETRY_BACKOFF:-30}"
LARK_SEND_MAX_RETRY="${LARK_SEND_MAX_RETRY:-3}"
LARK_SEND_RETRY_BACKOFF="${LARK_SEND_RETRY_BACKOFF:-10}"

LOG_FILE="${BADCASE_MONITOR_LOG:-$STATE_DIR/monitor.log}"
PROCESSED_FILE="${PROCESSED_FILE:-$STATE_DIR/processed_events.txt}"   # message_id 幂等账本
PID_FILE="$STATE_DIR/badcase_event_monitor.pid"

# consume 安全上限：到达后退出，由 launchd KeepAlive 重启。
# 避免长连接进程内存/句柄长期累积；同时规避 launchd StandardInput=null 的 stdin EOF 陷阱。
CONSUME_MAX_EVENTS="${CONSUME_MAX_EVENTS:-1000}"
# 单次 trace 解密等待板栗审批的最长时间（秒）
DECRYPT_WAIT_TIMEOUT="${DECRYPT_WAIT_TIMEOUT:-900}"

# ============ autofix 自动修复模块配置 ============
# 在结论帖发出后，独立复核根因、评估复杂度，对「简单可自动改」的 case 给出修改计划，
# 等刘昕明显式同意后由 zcode headless 全自动切 develop → 改 → 提 MR。详见下方状态机。
AUTOFIX_ENABLED="${AUTOFIX_ENABLED:-1}"
# 审批人（刘昕明）的飞书 open_id（ou_xxx）。留空则启动时从本机登录者身份自动取。
AUTOFIX_REVIEWER_OPEN_ID="${AUTOFIX_REVIEWER_OPEN_ID:-}"
# 审批等待时长（秒）：发出修改计划后多久没等到同意就挂起。默认 72 小时。
AUTOFIX_APPROVAL_TIMEOUT="${AUTOFIX_APPROVAL_TIMEOUT:-259200}"
# 可自动修复的文件数上限：超过即判为 MANUAL（转人工）。
AUTOFIX_MAX_FILES="${AUTOFIX_MAX_FILES:-3}"
# review（独立复核+复杂度评估）阶段总预算（秒）
AUTOFIX_REVIEW_TIMEOUT="${AUTOFIX_REVIEW_TIMEOUT:-1200}"
# review 单轮 zcode 超时上限（秒）
AUTOFIX_REVIEW_ATTEMPT_TIMEOUT="${AUTOFIX_REVIEW_ATTEMPT_TIMEOUT:-900}"
# 执行（改码+提MR）阶段总预算（秒）
AUTOFIX_EXECUTE_TIMEOUT="${AUTOFIX_EXECUTE_TIMEOUT:-1800}"
# 执行阶段单轮 zcode 超时上限（秒）
AUTOFIX_EXECUTE_ATTEMPT_TIMEOUT="${AUTOFIX_EXECUTE_ATTEMPT_TIMEOUT:-1500}"
# 任务持久化目录与结论帖幂等账本
AUTOFIX_TASKS_DIR="${AUTOFIX_TASKS_DIR:-$STATE_DIR/autofix_tasks}"
AUTOFIX_CONCLUSIONS_FILE="${AUTOFIX_CONCLUSIONS_FILE:-$STATE_DIR/autofix_processed_conclusions.txt}"
# autofix 方法论 prompt（注入 zcode）
AUTOFIX_REVIEW_SKILL="${AUTOFIX_REVIEW_SKILL:-$DAEMON_ROOT/skills/autofix-review/SKILL.md}"
AUTOFIX_EXECUTE_SKILL="${AUTOFIX_EXECUTE_SKILL:-$DAEMON_ROOT/skills/autofix-execute/SKILL.md}"
# ============ autofix 配置结束 ============
# 后台分析并发上限：同一时刻最多并行分析多少条消息（防并发抢爆 bigmodel 配额）。
# 超出的消息在主循环里暂存，待有空位再派活（任务文件保留，不会丢）。
MAX_CONCURRENT_ANALYSIS="${MAX_CONCURRENT_ANALYSIS:-3}"
# 分析任务持久化目录（用于后台化派活 + kill 后启动恢复，见 process_event / 启动恢复逻辑）
ANALYSIS_TASKS_DIR="${ANALYSIS_TASKS_DIR:-$STATE_DIR/analysis_tasks}"
# ============ 配置结束 ============

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" "$STATE_DIR/traces" "$AUTOFIX_TASKS_DIR" "$ANALYSIS_TASKS_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true
touch "$PROCESSED_FILE" "$AUTOFIX_CONCLUSIONS_FILE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2; }
die() { log "ERROR: $*"; exit 1; }

# 依赖检查
command -v lark-cli >/dev/null || die "lark-cli 不在 PATH"
command -v jq >/dev/null || die "jq 不在 PATH"
command -v node >/dev/null || die "node 不在 PATH"
command -v bytedcli >/dev/null || die "bytedcli 不在 PATH"
command -v python3 >/dev/null || die "python3 不在 PATH"
command -v uuidgen >/dev/null || die "uuidgen 不在 PATH"
[[ -f "$ZCODE_CJS" ]] || die "ZCode CLI 不存在: $ZCODE_CJS"
[[ -d "$FORNAX_SCRIPTS" ]] || die "fornax-trace-fetch 脚本目录不存在: $FORNAX_SCRIPTS"
[[ -f "$FIND_RUNLOG" ]] || die "find-runlog-log.sh 不存在: $FIND_RUNLOG"
[[ -f "$TRACE_ANALYZE_SKILL" ]] || die "trace-decrypt-analyze SKILL.md 不存在: $TRACE_ANALYZE_SKILL"
# autofix 模块依赖（仅在启用时强校验，避免禁用 autofix 时因缺 git/go/SKILL 阻止 daemon 启动）
if [[ "$AUTOFIX_ENABLED" == "1" ]]; then
  command -v git >/dev/null || die "autofix 启用：git 不在 PATH"
  command -v go >/dev/null || die "autofix 启用：go 不在 PATH"
  [[ -f "$AUTOFIX_REVIEW_SKILL" ]] || die "autofix 启用：autofix-review SKILL.md 不存在: $AUTOFIX_REVIEW_SKILL"
  [[ -f "$AUTOFIX_EXECUTE_SKILL" ]] || die "autofix 启用：autofix-execute SKILL.md 不存在: $AUTOFIX_EXECUTE_SKILL"
  # 审批人 open_id（刘昕明）：留空时从本机登录者自动取（本机登录者即「我」）。
  if [[ -z "$AUTOFIX_REVIEWER_OPEN_ID" ]]; then
    AUTOFIX_REVIEWER_OPEN_ID=$(LARKSUITE_CLI_NO_UPDATE_NOTIFIER=1 LARKSUITE_CLI_NO_SKILLS_NOTIFIER=1 \
      lark-cli auth status --json --verify 2>/dev/null \
      | jq -r '.identities.user.openId // empty' 2>/dev/null || true)
    if [[ -z "$AUTOFIX_REVIEWER_OPEN_ID" ]]; then
      die "autofix 启用：无法自动取审批人 open_id，请在 ~/.badcase_event_env 设置 AUTOFIX_REVIEWER_OPEN_ID"
    fi
    log "autofix 审批人 open_id 取自本机登录者: $AUTOFIX_REVIEWER_OPEN_ID"
  fi
fi

# 单实例锁（仅常驻 consume 模式需要）：两个 consumer 订阅同一 EventKey 会报
# "subscription already exists" 并重复投递。--once / --once-autofix 不启动 consume，
# 不需要锁，可与常驻 daemon 同时运行（补跑/调试无需停 daemon）。
# macOS 无 flock，用自带的 shlock（原子写 pid 文件；若文件已存在且 pid 存活则失败）。
acquire_singleton_lock() {
  # 先清理上一轮残留的空/孤儿 pid 文件：若 pid 不在运行就删，避免误判。
  if [[ -f "$PID_FILE" ]]; then
    local old_pid
    old_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [[ -z "$old_pid" ]] || ! kill -0 "$old_pid" 2>/dev/null; then
      rm -f "$PID_FILE"
    fi
  fi
  if ! shlock -p $$ -f "$PID_FILE"; then
    die "另一个常驻实例正在运行 (pid=$(cat "$PID_FILE" 2>/dev/null))。如确认无残留：rm $PID_FILE。补跑/调试请用 --once/--once-autofix，无需停 daemon。"
  fi
  trap 'rm -f "$PID_FILE"' EXIT
}

# ---- 参数解析（在锁之前，便于根据模式决定是否拿锁）----
DRY_REPLY=0
ONLY_MSG_ID=""
FORCED_LOG_ID=""
ONLY_AUTOFIX_TASK_ID=""
ONLY_AUTOFIX_PHASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-reply) DRY_REPLY=1; shift ;;
    --once) ONLY_MSG_ID="${2:-}"; shift 2 ;;
    --log-id) FORCED_LOG_ID="${2:-}"; shift 2 ;;
    # 调试：单任务重放 autofix 的某个阶段。phase ∈ review|execute
    --once-autofix) ONLY_AUTOFIX_TASK_ID="${2:-}"; ONLY_AUTOFIX_PHASE="${3:-review}"; shift 3 ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done
if [[ -n "$FORCED_LOG_ID" ]]; then
  [[ -n "$ONLY_MSG_ID" ]] || die "--log-id 仅可与 --once 一起使用"
  [[ "$FORCED_LOG_ID" =~ ^[0-9]{15,20}$ ]] || die "--log-id 格式无效: $FORCED_LOG_ID"
fi

# ---- 工具函数 ----

# 调 ZCode headless 跑独立分析会话，返回 response 文本。函数使用子 shell，确保
# daemon 被停止时能回收当前 timeout/ZCode 进程，不覆盖主进程的清理 trap。
# $1=prompt $2=绝对截止时间(epoch) $3=单轮超时上限
# $4=进度回复目标消息(可空) $5=阶段名称 $6=首次进度通知时间(epoch)
# $7=可选本地证据附件路径（ZCode --attach）
run_zcode_session() (
  local prompt="$1"
  local deadline_epoch="$2"
  local attempt_timeout_cap="$3"
  local progress_msg_id="${4:-}"
  local progress_stage="${5:-深度分析}"
  local next_progress_epoch="${6:-0}"
  local attachment_path="${7:-}"
  local tmp="$STATE_DIR/zcode_$$.json"
  local err="$STATE_DIR/zcode_$$.err"
  local attempt=0 response="" zcode_pid=""
  cleanup_zcode_session() {
    if [[ -n "$zcode_pid" ]] && kill -0 "$zcode_pid" 2>/dev/null; then
      kill -TERM "$zcode_pid" 2>/dev/null || true
    fi
    rm -f "$tmp" "$err"
  }
  trap cleanup_zcode_session EXIT
  trap 'exit 143' INT TERM

  while (( attempt < ZCODE_MAX_RETRY )); do
    local now remaining attempt_timeout
    now=$(date +%s)
    remaining=$(( deadline_epoch - now ))
    (( remaining > 0 )) || break
    attempt_timeout="$remaining"
    if (( attempt_timeout_cap > 0 && attempt_timeout > attempt_timeout_cap )); then
      attempt_timeout="$attempt_timeout_cap"
    fi
    attempt=$((attempt + 1))
    local rc=0
    : >"$tmp"
    : >"$err"
    local -a zcode_args
    zcode_args=(--prompt "$prompt" --json --cwd "$REPO_ROOT")
    [[ -n "$attachment_path" ]] && zcode_args+=(--attach "$attachment_path")
    ZCODE_MODEL="$ZCODE_MODEL" \
    ZCODE_BASE_URL="$ZCODE_BASE_URL" \
    ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    timeout "$attempt_timeout" node "$ZCODE_CJS" \
      "${zcode_args[@]}" >"$tmp" 2>"$err" &
    zcode_pid=$!

    # ZCode 的 --json 只在会话结束后给最终响应；长会话期间按固定间隔发送安全心跳，
    # 不伪造尚未形成的调查结论。阶段结论由外层在本会话成功后单独发送。
    while kill -0 "$zcode_pid" 2>/dev/null; do
      local zstate
      zstate=$(ps -p "$zcode_pid" -o state= 2>/dev/null | tr -d ' ' || true)
      [[ -z "$zstate" || "$zstate" == Z* ]] && break
      sleep "$ANALYSIS_POLL_INTERVAL"
      now=$(date +%s)
      if [[ -n "$progress_msg_id" ]] && (( next_progress_epoch > 0 && now >= next_progress_epoch && now < deadline_epoch )); then
        reply_thread_progress "$progress_msg_id" "**[自动分析·进度]** 当前仍在${progress_stage}，模型会话第 ${attempt} 轮运行中；尚未形成可稳定发布的新结论，继续调查。" \
          "hb${next_progress_epoch}" || \
          log "${progress_stage}进度通知发送失败，分析继续"
        while (( next_progress_epoch <= now )); do
          next_progress_epoch=$(( next_progress_epoch + ANALYSIS_PROGRESS_INTERVAL ))
        done
      fi
    done
    wait "$zcode_pid" || rc=$?
    zcode_pid=""
    local out_size=0; [[ -f "$tmp" ]] && out_size=$(wc -c < "$tmp" | tr -d ' ')
    if (( rc == 0 )) && (( out_size > 0 )); then
      response=$(jq -r '.response // empty' "$tmp" 2>/dev/null || true)
      [[ -n "$response" ]] && break
    fi
    # 不把模型 stderr/响应原文写入日志，其中可能包含 prompt、用户输入或工具结果。
    local error_kind="unknown"
    if (( rc == 124 )); then
      error_kind="analysis_timeout"
    elif grep -qE '1305|overloaded_error|访问量过大' "$tmp" "$err" 2>/dev/null; then
      error_kind="rate_limited"
    elif grep -qE 'ConnectTimeoutError|UND_ERR_CONNECT_TIMEOUT|ECONNRESET|ETIMEDOUT|isRetryable: true' \
      "$tmp" "$err" 2>/dev/null; then
      error_kind="network_retryable"
    fi
    log "ZCode 会话第 ${attempt}/${ZCODE_MAX_RETRY} 次失败 rc=${rc} outSize=${out_size} kind=${error_kind}"
    local retryable=1
    if grep -qE 'authentication_error|invalid_api_key|permission_denied|invalid_request_error|HTTP[^0-9]*40[013]' \
      "$tmp" "$err" 2>/dev/null; then
      retryable=0
    fi
    now=$(date +%s)
    remaining=$(( deadline_epoch - now ))
    if (( retryable == 1 && attempt < ZCODE_MAX_RETRY && remaining > 0 )); then
      local backoff=$(( attempt * ZCODE_RETRY_BACKOFF ))
      (( backoff > 120 )) && backoff=120
      (( backoff >= remaining )) && break
      log "模型会话可重试故障，${backoff}s 后发起第 $((attempt + 1)) 轮（本阶段剩余 ${remaining}s）"
      sleep "$backoff"
      continue
    fi
    break
  done
  echo "$response"
)

# 从文本中抽取日志 ID。优先结构化关键词，兜底裸 19 位数字（7 开头）。
# 输出：每行一个 ID（去重）。
# $1 = 待抽取文本
extract_log_ids() {
  local text="$1"
  # 结构化关键词：日志ID / run_log_id / trace_id 后跟数字（15-20 位）
  echo "$text" | grep -oE '(日志\s*[iI][dD]|run[_-]?log[_-]?[iI][dD]|log[_-]?[iI][dD]|trace[_-]?[iI][dD])[:：\s]*[0-9]{15,20}' \
    | grep -oE '[0-9]{15,20}' 2>/dev/null || true
  # 兜底：裸 19 位数字（7 开头，run_log_id 典型形态）。但 uid/user_id 也是相同
  # 形态，若原文已明确标注为用户 ID，必须排除，避免误查 trace 并发送误导评论。
  local candidate
  echo "$text" | grep -oE '\b7[0-9]{18}\b' 2>/dev/null | while IFS= read -r candidate; do
    if echo "$text" | grep -qiE "(uid|user[_ -]?[iI][dD]|用户[[:space:]]*[iI][dD])[:：[:space:]]*${candidate}"; then
      continue
    fi
    echo "$candidate"
  done || true
}

# 从合并转发正文里提取最早的 ISO8601 时间戳，作为原始 run 的时间参考点。
# 合并转发格式：[2026-07-18T09:18:03+08:00] 发送者: 内容
# 这些时间戳是原始消息的发送时间，日志 ID 也来自这些原始消息，用最早时间查日志比用当前时间精准。
# $1 = 文本；stdout 输出最早的 ISO8601 时间戳（带时区），无则空。
extract_earliest_timestamp() {
  local text="$1"
  # 提取所有 ISO8601 时间戳，排序取最早
  echo "$text" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}' | sort | head -1
}

# mget 对合并转发只返回占位符，需要从群消息列表取展开后的正文。消息可能已经被
# 新消息挤出第一页，因此按 50 条/页向前翻页精确查 message_id，最多查 500 条。
# stdout 仅返回目标消息正文；网络失败或未找到时返回非 0，调用方不得标记已处理。
fetch_full_message_content() {
  local msg_id="$1" page_token="" page=0 response found has_more
  while (( page < 10 )); do
    page=$((page + 1))
    local -a args
    args=(im +chat-messages-list --chat-id "$CHAT_ID" --as user --order desc \
      --page-size 50 --no-reactions --format json)
    [[ -n "$page_token" ]] && args+=(--page-token "$page_token")
    response=$(lark-cli "${args[@]}" 2>>"$LOG_FILE") || return 1
    found=$(echo "$response" | jq -r --arg mid "$msg_id" \
      '[.data.messages[]? | select(.message_id==$mid)][0].content // empty' 2>/dev/null)
    if [[ -n "$found" ]]; then
      echo "$found"
      return 0
    fi
    has_more=$(echo "$response" | jq -r '.data.has_more // false' 2>/dev/null)
    page_token=$(echo "$response" | jq -r '.data.page_token // empty' 2>/dev/null)
    [[ "$has_more" != "true" || -z "$page_token" ]] && break
  done
  return 1
}

# 为第一轮候选定位生成全 span 目录：保留调用树、状态、长度，并给每个 span 一小段
# input/output 预览。它足以让模型点名 span_id，但不会把数 MB trace 全量塞进 prompt。
build_trace_catalog() {
  local trace_details_file="$1"
  jq -c --argjson preview "$ANALYSIS_CATALOG_PREVIEW_CHARS" '
    def short($n):
      (tostring) as $s |
      if ($s | length) > $n then ($s[0:$n] + "…<preview_truncated>") else $s end;
    .[] | {
      span_id, parent_id, span_type, span_name, status, duration, started_at,
      input_len: ((.input // "") | tostring | length),
      output_len: ((.output // "") | tostring | length),
      input_preview: ((.input // "") | short($preview)),
      output_preview: ((.output // "") | short($preview))
    }
  ' "$trace_details_file" 2>/dev/null
}

# 从模型控制行里提取 16 位 span_id，并与本地 trace 做交集，防止模型编造 ID。
# $1=response $2=marker $3=trace_details.json
extract_marker_span_ids() {
  local response="$1" marker="$2" trace_details_file="$3" marker_lines id
  marker_lines=$(printf '%s\n' "$response" | grep -i "$marker" || true)
  [[ -n "$marker_lines" ]] || return 0
  printf '%s\n' "$marker_lines" | grep -oE '\b[0-9a-fA-F]{16}\b' 2>/dev/null | \
    tr '[:upper:]' '[:lower:]' | while IFS= read -r id; do
      jq -e --arg id "$id" 'any(.[]; ((.span_id // "") | ascii_downcase) == $id)' \
        "$trace_details_file" >/dev/null 2>&1 && echo "$id"
    done | awk '!seen[$0]++'
}

# 当模型漏写候选控制行时，从正文引用过的真实 span_id 回收候选。
extract_any_known_span_ids() {
  local response="$1" trace_details_file="$2" id
  printf '%s\n' "$response" | grep -oE '\b[0-9a-fA-F]{16}\b' 2>/dev/null | \
    tr '[:upper:]' '[:lower:]' | while IFS= read -r id; do
      jq -e --arg id "$id" 'any(.[]; ((.span_id // "") | ascii_downcase) == $id)' \
        "$trace_details_file" >/dev/null 2>&1 && echo "$id"
    done | awk '!seen[$0]++'
}

# 最后兜底：优先 tool/agent/异常 span，并补最后一个 model span，保证深度轮至少有证据。
default_candidate_span_ids() {
  local trace_details_file="$1"
  jq -r '
    ([.[] | select(.span_type == "tool" or .span_type == "agent" or .status != "success")] +
     (([.[] | select(.span_type == "model")]) as $m | if ($m|length)>0 then [$m[-1]] else [] end))
    | unique_by(.span_id) | .[].span_id
  ' "$trace_details_file" 2>/dev/null
}

# 合并 span_id 列表并限制证据规模。两个参数均为换行分隔字符串。
merge_span_ids() {
  local current_ids="$1" new_ids="$2"
  printf '%s\n%s\n' "$current_ids" "$new_ids" | awk 'NF && !seen[$0]++' | \
    head -n "$ANALYSIS_MAX_EVIDENCE_SPANS"
}

# 生成只包含候选 span 的完整证据包。input/output 不截断，通过 ZCode --attach 提供；
# bundle 不进入日志，并在当前分析结束后删除。
build_trace_evidence_bundle() {
  local trace_details_file="$1" selected_ids="$2" bundle_file="$3" ids_json
  ids_json=$(printf '%s\n' "$selected_ids" | jq -R 'select(length > 0)' | jq -s '.')
  [[ "$ids_json" != "[]" ]] || return 1
  jq --argjson ids "$ids_json" '
    [.[] | select(.span_id as $sid | $ids | index($sid)) | {
      span_id, parent_id, span_type, span_name, status, duration, started_at, input, output
    }]
  ' "$trace_details_file" >"$bundle_file"
  chmod 600 "$bundle_file" 2>/dev/null || true
  jq -e 'length > 0' "$bundle_file" >/dev/null 2>&1
}

# 机器控制行只用于 daemon 编排，不展示到 badcase 群。
strip_analysis_control_lines() {
  sed -E '/CANDIDATE_SPAN_IDS|EVIDENCE_STATUS|ADDITIONAL_SPAN_IDS/d'
}

# 幂等：检查 message_id 是否已处理过。$1=msg_id
is_processed() { grep -qxF "$1" "$PROCESSED_FILE" 2>/dev/null; }
mark_processed() { echo "$1" >>"$PROCESSED_FILE"; }

# 用裸数字在日志里搜，如果它是 StepID 则从同一行抽真正的 RunLogID。
# 高频误用：用户从 CCM 页面复制的是「步骤 ID」(StepID) 而非「日志 ID」(RunLogID)，
# 两者格式相似（都是 19 位 7 开头），用户无法区分。回退裸搜命中行里有
# "RunLogID":"...","StepID":"..."，可据此纠错。
# $1 = 用户提供的 id
# $2 = time_anchor_iso（可空）：原始消息最早 ISO8601 时间戳，用于精准定位查询窗口；
#      传入则以该时间为中心开 [-1d, +6h] 窗口；为空则回退 [now-7d, now]。
# stdout 输出纠错后的 RunLogID（可能多个，去重），查不到则空。
resolve_stepid_to_runlogid() {
  local raw_id="$1"
  local time_anchor_iso="${2:-}"
  # 查询窗口：有原始消息时间参考时以该时间为中心开 [-1d, +6h]（run 可能在报 case 后才落库）；
  # 无则回退 [now-7d, now]（日志系统上限）。
  local start_iso end_iso
  if [[ -n "$time_anchor_iso" ]]; then
    read -r start_iso end_iso < <(python3 -c "
from datetime import datetime,timedelta
anchor=datetime.fromisoformat('$time_anchor_iso')
print((anchor-timedelta(days=1)).strftime('%Y-%m-%dT%H:%M:%SZ'), (anchor+timedelta(hours=6)).strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>>"$LOG_FILE") || {
      # python3 解析失败（时间格式异常）→ 回退默认窗口
      start_iso=$(python3 -c 'from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
      end_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    }
  else
    start_iso=$(python3 -c 'from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
    end_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  fi
  local log_file
  log_file=$(timeout 120 bytedcli log search-psm-log \
    --psm "bitable.ai.chatbot" --vregion "China-North" \
    --start "$start_iso" \
    --end "$end_iso" \
    --keyword "$raw_id" \
    --max-logs 200 --limit 30 --poll-timeout 60 --output file 2>>"$LOG_FILE" \
    | awk -F': ' '/Log output file:/ {print $2}' | tail -1)
  [[ -z "$log_file" || ! -f "$log_file" ]] && return 1
  # 从命中行抽 RunLogID（JSON 字段 "RunLogID":"<数字>"），排除与输入相同的（那就是真 RunLogID 不需纠错）
  grep -oE '"RunLogID":"[0-9]+"' "$log_file" 2>/dev/null \
    | grep -oE '[0-9]+' | sort -u | grep -vx "$raw_id" || true
}

# run_log_id → trace_id。复用 find-runlog-log.sh。
# 时间窗口策略：
#   - 若有原始消息时间参考（time_anchor_iso）：算 anchor→now 的小时差 + 6h 缓冲作为单一精准窗口，
#     不再渐进（窗口已根据原始 run 时间精准覆盖）。
#   - 无时间参考：保持渐进 6h → 72h → 168h（命中即停，避免老 case 每次跑满 7 天）。
# badcase 群多为合并转发，原始 run 可能发生在转发前几小时甚至几天；用原始消息最早时间比当前时间精准。
# 输出：每行一个 trace_id（去重空值）。
# $1 = run_log_id
# $2 = time_anchor_iso（可空）：原始消息最早 ISO8601 时间戳，作为日志查询窗口参考点。
resolve_trace_ids() {
  local run_log_id="$1"
  local time_anchor_iso="${2:-}"
  local trace_ids=""
  # 算查询窗口 hours：有 time_anchor 时基于 anchor→now + 缓冲；无则用渐进 6→72→168。
  local hours_list
  if [[ -n "$time_anchor_iso" ]]; then
    local hours
    hours=$(python3 -c "
from datetime import datetime,timezone
anchor=datetime.fromisoformat('$time_anchor_iso')
now=datetime.now(timezone.utc)
diff=(now-anchor).total_seconds()/3600
# 缓冲：至少 6h，最多 168h（7天上限）
print(max(6, min(168, int(diff)+6)))
" 2>>"$LOG_FILE" || echo 6)
    log "用原始消息时间 $time_anchor_iso 算查询窗口：${hours}h"
    hours_list="$hours"
  else
    hours_list="6 72 168"
  fi
  local h
  for h in $hours_list; do
    local out
    out=$("$FIND_RUNLOG" --run-log-id "$run_log_id" --env both --hours "$h" 2>>"$LOG_FILE") || {
      log "find-runlog-log 执行失败 run_log_id=$run_log_id (hours=$h)"
      return 1
    }
    trace_ids=$(echo "$out" | grep -oE '^trace_id: [0-9a-fA-F]+' | awk '{print $2}' | sort -u)
    [[ -n "$trace_ids" ]] && break
    # 渐进模式下才打日志（单窗口模式下 hours_list 只有一个值，无需"扩大窗口"提示）
    local hours_count
    hours_count=$(echo "$hours_list" | wc -w | tr -d ' ')
    (( hours_count > 1 )) && log "run_log_id=$run_log_id 在 ${h}h 内未命中，扩大窗口继续查"
  done

  # 查不到 trace → 回退：可能是用户复制了 StepID，裸搜找真正的 RunLogID 再查
  if [[ -z "$trace_ids" ]]; then
    log "run_log_id=$run_log_id 未命中，尝试 StepID 纠错（裸搜日志找 RunLogID）"
    local corrected_ids
    corrected_ids=$(resolve_stepid_to_runlogid "$run_log_id" "$time_anchor_iso")
    if [[ -n "$corrected_ids" ]]; then
      local first_corrected
      first_corrected=$(echo "$corrected_ids" | head -1)
      log "StepID 纠错：$run_log_id 疑似是 StepID，找到 RunLogID=${first_corrected}，重新查 trace"
      # 纠错后的 ID 复用同一窗口策略
      local h2
      for h2 in $hours_list; do
        local out2
        out2=$("$FIND_RUNLOG" --run-log-id "$first_corrected" --env both --hours "$h2" 2>>"$LOG_FILE") || break
        trace_ids=$(echo "$out2" | grep -oE '^trace_id: [0-9a-fA-F]+' | awk '{print $2}' | sort -u)
        [[ -n "$trace_ids" ]] && break
      done
      # 记录纠错结果，供回复时告知用户真正的 RunLogID
      RESOLVED_RUNLOG_ID="$first_corrected"
    fi
  fi
  echo "$trace_ids"
}

# 抓 trace + 判断解密状态。成功则把 trace 目录写到 stdout（供后续分析读取）。
# $1 = trace_id；返回值：0=已解密可用 / 1=未解密（需走 BPM）
fetch_and_check_decrypt() {
  local trace_id="$1"
  local out_dir="$STATE_DIR/traces/trace_${trace_id}"
  rm -rf "$out_dir"
  node "$FORNAX_SCRIPTS/fetch_fornax_trace.mjs" "$trace_id" \
    --workspace-id "$FORNAX_WORKSPACE_ID" --out "$out_dir" >/dev/null 2>>"$LOG_FILE" || {
    log "fetch_fornax_trace 失败 trace_id=$trace_id"; return 1; }
  # metadata.json 里 decrypt.decrypt_success_false > 0 表示有未解密 span
  local false_cnt
  false_cnt=$(jq -r '.decrypt.decrypt_success_false // 0' "$out_dir/metadata.json" 2>/dev/null || echo 0)
  if (( false_cnt > 0 )); then
    return 1
  fi
  echo "$out_dir"
  return 0
}

# 全自动解密：建 BPM 工单 → @板栗 → 等审批 → 重抓。
# $1 = trace_id；返回值：0=解密成功 / 1=失败或超时
auto_decrypt() {
  local trace_id="$1"
  log "trace $trace_id 未解密，启动 BPM 解密流程"
  # 1. 建工单
  local bpm_out bpm_rc=0
  bpm_out=$(node "$FORNAX_SCRIPTS/apply_trace_decrypt_bpm.mjs" "$trace_id" \
    --workspace-id "$FORNAX_WORKSPACE_ID" --valid-day 29 --reason debug 2>>"$LOG_FILE") || bpm_rc=$?
  if (( bpm_rc != 0 )); then log "apply_trace_decrypt_bpm 失败 rc=${bpm_rc}"; return 1; fi
  local record_url
  record_url=$(echo "$bpm_out" | jq -r '.record_url // empty' 2>/dev/null)
  [[ -z "$record_url" ]] && { log "未取到 record_url"; return 1; }
  log "BPM 工单已创建"
  # 2. @板栗
  local banli_attempt=0 banli_rc=0
  while (( banli_attempt < LARK_SEND_MAX_RETRY )); do
    banli_attempt=$((banli_attempt + 1))
    banli_rc=0
    node "$FORNAX_SCRIPTS/send_banli_trace_decrypt.mjs" "$record_url" >/dev/null 2>>"$LOG_FILE" || banli_rc=$?
    (( banli_rc == 0 )) && break
    if (( banli_attempt < LARK_SEND_MAX_RETRY )); then
      local banli_backoff=$(( banli_attempt * LARK_SEND_RETRY_BACKOFF ))
      log "send_banli 第 ${banli_attempt}/${LARK_SEND_MAX_RETRY} 次失败 rc=${banli_rc}，${banli_backoff}s 后重试"
      sleep "$banli_backoff"
    fi
  done
  if (( banli_rc != 0 )); then
    log "send_banli 连续 ${LARK_SEND_MAX_RETRY} 次失败（工单已建，可手动催）"
    return 1
  fi
  log "已 @板栗 推进解密，等待审批（最长 ${DECRYPT_WAIT_TIMEOUT}s）"
  # 3. 等审批
  node "$FORNAX_SCRIPTS/wait_banli_done.mjs" \
    --chat-id "$DECRYPT_CHAT_ID" --record-url "$record_url" \
    --timeout-sec "$DECRYPT_WAIT_TIMEOUT" >>"$LOG_FILE" 2>&1 || {
    log "wait_banli 超时或失败（exit=$?）"; return 1; }
  # 4. 重抓验证
  local out_dir="$STATE_DIR/traces/trace_${trace_id}"
  rm -rf "$out_dir"
  node "$FORNAX_SCRIPTS/fetch_fornax_trace.mjs" "$trace_id" \
    --workspace-id "$FORNAX_WORKSPACE_ID" --out "$out_dir" >/dev/null 2>>"$LOG_FILE" || {
    log "重抓失败"; return 1; }
  local false_cnt
  false_cnt=$(jq -r '.decrypt.decrypt_success_false // 0' "$out_dir/metadata.json" 2>/dev/null || echo 0)
  (( false_cnt > 0 )) && { log "重抓后仍 ${false_cnt} 个 span 未解密"; return 1; }
  echo "$out_dir"
  return 0
}

# 回复到 thread（bot 身份，符合 AGENTS.md）。
# $1 = 根消息 om_ id；$2 = markdown 文本；$3 = 可选幂等 key
reply_thread() {
  local msg_id="$1" text="$2" requested_idem_key="${3:-}"
  # 飞书回复接口的 uuid 最长 50 字符。使用 39 字符的 bc-<UUID>，既满足长度约束，
  # 也避免重处理同一条消息时旧 key 命中一小时去重，导致新结论发不出去。
  local idem_key
  if [[ -n "$requested_idem_key" ]]; then
    idem_key="$requested_idem_key"
  else
    idem_key="bc-$(uuidgen | tr '[:upper:]' '[:lower:]')"
  fi
  # lark-cli 1.0.68 的 --markdown 接收 Markdown 文本，不支持用 @file 加载内容。
  # 必须把 text 作为单个 argv 参数传入；双引号、表格和代码块会原样交给 CLI 转成 post。
  if (( DRY_REPLY == 1 )); then
    log "[dry-reply] 将回复到 ${msg_id}（内容长度 ${#text} 字符）"
    local dry_rc=0
    lark-cli im +messages-reply --message-id "$msg_id" --reply-in-thread --as bot \
      --markdown "$text" --idempotency-key "$idem_key" --dry-run >/dev/null 2>>"$LOG_FILE" || dry_rc=$?
    if (( dry_rc != 0 )); then
      log "[dry-reply] 请求预览失败 rc=${dry_rc}"
      return 1
    fi
    return 0
  fi
  # 正式发送前先做本地请求预览，提前拦截 Markdown/字段结构错误；预览正文不落日志。
  local preview_rc=0
  lark-cli im +messages-reply --message-id "$msg_id" --reply-in-thread --as bot \
    --markdown "$text" --idempotency-key "$idem_key" --dry-run >/dev/null 2>>"$LOG_FILE" || preview_rc=$?
  if (( preview_rc != 0 )); then
    log "回复请求预览失败 rc=${preview_rc}"
    return 1
  fi
  local send_out="" send_rc=0 send_attempt=0
  while (( send_attempt < LARK_SEND_MAX_RETRY )); do
    send_attempt=$((send_attempt + 1))
    send_rc=0
    # 同一轮重试复用 idem_key：若服务端已接收但客户端未收到响应，可避免重复评论。
    send_out=$(lark-cli im +messages-reply --message-id "$msg_id" --reply-in-thread --as bot \
      --markdown "$text" --idempotency-key "$idem_key" 2>&1) || send_rc=$?
    (( send_rc == 0 )) && break
    if (( send_attempt < LARK_SEND_MAX_RETRY )) && \
      echo "$send_out" | grep -qEi '"type"[[:space:]]*:[[:space:]]*"network"|timeout|TLS handshake|ECONNRESET|ETIMEDOUT'; then
      local send_backoff=$(( send_attempt * LARK_SEND_RETRY_BACKOFF ))
      log "回复第 ${send_attempt}/${LARK_SEND_MAX_RETRY} 次遇到网络错误 rc=${send_rc}，${send_backoff}s 后重试"
      sleep "$send_backoff"
      continue
    fi
    break
  done
  if (( send_rc != 0 )); then
    local send_error
    send_error=$(echo "$send_out" | jq -r \
      'if .error then "type=\(.error.type // "unknown") subtype=\(.error.subtype // "unknown") code=\(.error.code // "")" else "non_json_error" end' \
      2>/dev/null || echo "non_json_error")
    log "回复失败 rc=${send_rc} ${send_error}"
    return 1
  fi
  local sent_id
  sent_id=$(echo "$send_out" | jq -r '.data.message_id // empty' 2>/dev/null)
  log "已回复 ${msg_id} → ${sent_id}"
}

# 回复成功后才写入 processed；dry-run 只验证请求，不改变幂等账本。
# $1 = 事件消息 id；$2 = 回复目标消息 id；$3 = markdown 文本
reply_thread_and_mark() {
  local event_msg_id="$1" target_msg_id="$2" text="$3"
  if ! reply_thread "$target_msg_id" "$text"; then
    log "回复 ${event_msg_id} 失败，保留未处理状态以便重试"
    return 1
  fi
  if (( DRY_REPLY == 1 )); then
    log "[dry-reply] 不标记 ${event_msg_id} 为已处理"
    return 0
  fi
  mark_processed "$event_msg_id"
}

# 阶段进展只负责让 thread 可见，不改变最终幂等账本。即使进展消息发送失败，也不应
# 中断耗时分析；最终结论仍由 reply_thread_and_mark 决定是否闭环。
reply_thread_progress() {
  local target_msg_id="$1" text="$2" progress_scope="${3:-progress}"
  # scope + om_ 后缀保持在飞书 50 字符限制内；同一阶段在 1 小时内重复执行不会刷屏。
  local progress_idem_key="bc-${progress_scope}-${target_msg_id#om_}"
  if ! reply_thread "$target_msg_id" "$text" "$progress_idem_key"; then
    log "阶段进展发送失败，继续分析"
    return 1
  fi
  return 0
}

# ============================================================
# ===== autofix 自动修复模块：状态机 + 任务持久化 ==========
# 状态机：reviewing → awaiting_approval → executing → done/failed
# 所有耗时阶段（review/execute）在后台子进程跑，不阻塞主循环消费事件。
# 审批检测复用主循环：刘昕明在 thread 的回复会作为普通消息被 consume 推过来，
# process_event 顶部调 autofix_check_approval_reply 推进状态。
# 任务 JSON 持久化在 $AUTOFIX_TASKS_DIR，daemon 重启可恢复。
# ============================================================

# ---- 任务 JSON 读写（用 jq 保证转义安全）----
# task 字段：task_id, state, root_om, thread_root_om, trace_id, trace_dir,
#   run_log_id, conclusion_md, reported_by, complexity, root_cause, fix_plan,
#   plan_msg_om, created_epoch, approved_epoch, mr_url, mr_number, branch, commit_hash,
#   discussion_context(数组), failures, last_error
# task_id 用 trace_id 派生（同一 trace 只建一个修复任务）

# 生成/取任务文件路径。$1 = task_id
autofix_task_file() { echo "$AUTOFIX_TASKS_DIR/task_$1.json"; }

# 读取任务字段。$1=task_id $2=jq 路径
autofix_task_get() { local f; f=$(autofix_task_file "$1"); jq -r "$2 // empty" "$f" 2>/dev/null; }

# 写入任务字段。$1=task_id，其余参数透传给 jq（jq 表达式 + 可选 --arg/--argjson）。
# 例：autofix_task_set "$tid" '.state="done"'
#     autofix_task_set "$tid" --arg c "SIMPLE_AUTO" '.complexity=$c'
autofix_task_set() {
  local task_id="$1"; shift
  local f; f=$(autofix_task_file "$task_id")
  local tmp="$f.tmp"
  jq "$@" "$f" >"$tmp" 2>/dev/null && mv "$tmp" "$f" || { log "autofix_task_set 失败 task=$task_id args=$*"; rm -f "$tmp"; }
}

# 追加讨论上下文（thread 内其他人发言）。$1=task_id $2=sender_name $3=text
autofix_task_add_discussion() {
  local task_id="$1" sender="$2" text="$3"
  local f; f=$(autofix_task_file "$task_id")
  [[ -f "$f" ]] || return 0
  local tmp="$f.tmp"
  # 用 jq 安全拼接（text 可能含特殊字符）
  jq --arg s "$sender" --arg t "$text" '.discussion_context += ["\($s): \($t)"]' "$f" >"$tmp" 2>/dev/null && mv "$tmp" "$f" || rm -f "$tmp"
}

# 列出所有处于指定状态的任务 id（每行一个）。$1=state（可空=全部）
autofix_tasks_in_state() {
  local state="${1:-}"
  local f
  for f in "$AUTOFIX_TASKS_DIR"/task_*.json; do
    [[ -f "$f" ]] || continue
    local tid st
    tid=$(jq -r '.task_id // empty' "$f" 2>/dev/null)
    st=$(jq -r '.state // empty' "$f" 2>/dev/null)
    [[ -z "$tid" ]] && continue
    if [[ -z "$state" || "$st" == "$state" ]]; then
      echo "$tid"
    fi
  done
}

# ---- 触发：结论帖发出后创建 reviewing 任务 ----
# 在 analyze_one_log_id 的 reply_thread_and_mark 成功后调用。
# $1=root_om(结论帖回复的目标，即 case 根消息) $2=trace_id $3=trace_dir
# $4=run_log_id $5=conclusion_md $6=reported_by(报案人名，可空)
autofix_on_conclusion_posted() {
  (( AUTOFIX_ENABLED == 1 )) || return 0
  local root_om="$1" trace_id="$2" trace_dir="$3" run_log_id="$4" conclusion_md="$5" reported_by="${6:-}"
  [[ -n "$trace_id" && -n "$trace_dir" && -n "$root_om" ]] || return 0
  # 幂等：同一 trace 已建过任务则不重复
  local task_id="trace_${trace_id}"
  local f; f=$(autofix_task_file "$task_id")
  [[ -f "$f" ]] && { log "autofix: trace $trace_id 已有任务，跳过"; return 0; }
  # 结论帖幂等账本（防 daemon 重启后重复触发）
  grep -qxF "$root_om:$trace_id" "$AUTOFIX_CONCLUSIONS_FILE" 2>/dev/null && { log "autofix: 结论 $root_om:$trace_id 已触发过"; return 0; }

  # 创建任务 JSON（用 jq from 模板，保证合法）
  local now; now=$(date +%s)
  jq -n \
    --arg tid "$task_id" --arg st "reviewing" --arg root "$root_om" \
    --arg tid2 "$trace_id" --arg tdir "$trace_dir" --arg rlid "$run_log_id" \
    --arg conc "$conclusion_md" --arg rb "$reported_by" --argjson now "$now" \
    '{task_id:$tid,state:$st,root_om:$root,trace_id:$tid2,trace_dir:$tdir,run_log_id:$rlid,
      conclusion_md:$conc,reported_by:$rb,complexity:"",root_cause:"",fix_plan:"",
      plan_msg_om:"",created_epoch:$now,approved_epoch:0,mr_url:"",mr_number:"",
      branch:"",commit_hash:"",discussion_context:[],failures:0,last_error:""}' >"$f" 2>/dev/null
  if [[ ! -s "$f" ]]; then log "autofix: 创建任务 JSON 失败 trace=$trace_id"; rm -f "$f"; return 1; fi
  echo "$root_om:$trace_id" >>"$AUTOFIX_CONCLUSIONS_FILE"
  log "autofix: 触发 review 任务 task=$task_id trace=$trace_id (后台启动)"

  # 后台异步跑 review（子 shell，不阻塞主循环；失败只记日志不抛出）
  (
    autofix_run_review "$task_id" || log "autofix: review 失败 task=$task_id rc=$?"
  ) >>"$LOG_FILE" 2>&1 &
}

# ---- review 阶段：zcode 独立复核 + 复杂度评估 ----
# $1=task_id
autofix_run_review() {
  local task_id="$1"
  # 记录 review 进程 pid，供启动恢复逻辑判断"是否已有 review 在跑"，避免重复启动。
  # 注意：review 在 `( autofix_run_review ) &` 子 shell 里跑，bash 的 $$ 在子 shell 仍是
  # 父 pid，必须用 $BASHPID 才是子 shell 真实 pid（恢复时 kill -0 校验它）。
  # macOS bash 3.2 下 BASHPID 在 set -u 的某些路径可能未设置，用 ${BASHPID:-$$} 兜底。
  autofix_task_set "$task_id" --argjson rpid "${BASHPID:-$$}" '.review_pid=$rpid'
  local root_om trace_id trace_dir run_log_id conclusion_md reported_by
  root_om=$(autofix_task_get "$task_id" '.root_om')
  trace_id=$(autofix_task_get "$task_id" '.trace_id')
  trace_dir=$(autofix_task_get "$task_id" '.trace_dir')
  run_log_id=$(autofix_task_get "$task_id" '.run_log_id')
  conclusion_md=$(autofix_task_get "$task_id" '.conclusion_md')
  reported_by=$(autofix_task_get "$task_id" '.reported_by')
  [[ -d "$trace_dir" ]] || { log "autofix: trace_dir 不存在 $trace_dir"; autofix_finalize_manual "$task_id" "trace 缓存目录丢失，无法复核"; return 1; }

  local skill_methodology span_summary trace_catalog trace_details_file
  trace_details_file="$trace_dir/trace_details.json"
  skill_methodology=$(cat "$AUTOFIX_REVIEW_SKILL" 2>/dev/null)
  span_summary=$(cat "$trace_dir/span_summary.tsv" 2>/dev/null | head -100)
  trace_catalog=$(build_trace_catalog "$trace_details_file" 2>/dev/null)

  # review 阶段需让模型能下钻核对 span 的完整 input/output。trace_details.json 较大
  # （常超 1MB），不直接用 --attach（易超限）；改为在 prompt 里给出 trace 文件绝对路径，
  # 让 zcode 在仓库 --cwd 下用 Read 按需读取（trace_dir 在 ~/.badcase_event_state 下，
  # 绝对路径，--cwd 不影响读取它）。
  local review_prompt
  review_prompt="你是多维表格智能体的自动修复 review agent。下面给你一套独立复核与复杂度评估方法论，请严格按它工作。你工作目录就是 bitable-chatbot 仓库根，可以读代码、grep、glob 来亲自定位根因。

=== 独立复核与复杂度评估方法论（autofix-review skill）===
$skill_methodology

=== 用户原始诉求 / badcase 群消息上下文 ===
（结论帖内容）
$conclusion_md

=== run_log_id ===
$run_log_id
=== trace_id ===
$trace_id

=== 完整 span 目录 ===
$trace_catalog

=== 完整 span 表 ===
$span_summary

=== trace 文件路径（需下钻核对 span input/output 时用 Read 读取，JSON 数组）===
$trace_details_file

请按方法论步骤 1-5 和输出契约，给出你的独立复核结论、复杂度判定（COMPLEXITY 行）和（若 SIMPLE_AUTO）修改计划（FIX_PLAN 段落）。务必逐行精确包含控制行。"

  # 调 zcode（复用其重试/退避外壳，但 review 是独立预算）。不传附件：trace 路径已写进
  # prompt，模型按需 Read；避免大文件 --attach 超限。
  local now deadline response
  now=$(date +%s); deadline=$(( now + AUTOFIX_REVIEW_TIMEOUT ))
  response=$(run_zcode_session "$review_prompt" "$deadline" "$AUTOFIX_REVIEW_ATTEMPT_TIMEOUT" "" "复核" 0 "")
  if [[ -z "$response" ]]; then
    log "autofix: review zcode 无输出 task=$task_id"
    autofix_finalize_manual "$task_id" "自动复核未产出结果（模型超时或失败），请人工跟进"
    return 1
  fi

  # 解析复杂度
  local complexity
  complexity=$(echo "$response" | grep -oE 'COMPLEXITY:[[:space:]]*(SIMPLE_AUTO|MANUAL)' | head -1 | grep -oE 'SIMPLE_AUTO|MANUAL')
  if [[ "$complexity" != "SIMPLE_AUTO" ]]; then
    # MANUAL 或解析不到 → 转人工，回复原因
    local reject_reason
    reject_reason=$(echo "$response" | grep -oE 'REJECT_REASON:[[:space:]].*' | head -1 | sed -E 's/^REJECT_REASON:[[:space:]]*//')
    [[ -z "$reject_reason" ]] && reject_reason="复杂度超出自动修复范围，建议人工处理"
    # 复核正文（去掉控制行）发群
    local body; body=$(echo "$response" | strip_analysis_control_lines | sed -E '/^COMPLEXITY:|^REJECT_REASON:|^FILES:|^ROOT_CAUSE:/d')
    autofix_finalize_manual "$task_id" "$reject_reason" "$body"
    return 0
  fi

  # SIMPLE_AUTO：解析文件数、根因、计划，发修改计划到 thread
  local files_cnt root_cause
  files_cnt=$(echo "$response" | grep -oE 'FILES:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
  root_cause=$(echo "$response" | grep -oE 'ROOT_CAUSE:[[:space:]].*' | head -1 | sed -E 's/^ROOT_CAUSE:[[:space:]]*//')
  [[ -z "$files_cnt" ]] && files_cnt="?"
  # 提取 FIX_PLAN 段落（FIX_PLAN: 之后到结尾或下一个控制行）
  local fix_plan
  fix_plan=$(echo "$response" | sed -n '/^FIX_PLAN:/,$p' | sed -E '1s/^FIX_PLAN:[[:space:]]*//' || echo "")
  [[ -z "$fix_plan" ]] && fix_plan=$(echo "$response" | sed -E '/^(COMPLEXITY|REJECT_REASON|FILES|ROOT_CAUSE):/d' | strip_analysis_control_lines)

  autofix_task_set "$task_id" --arg c "SIMPLE_AUTO" '.complexity=$c'
  [[ -n "$root_cause" ]] && autofix_task_set "$task_id" --arg rc "$root_cause" '.root_cause=$rc'
  autofix_task_set "$task_id" --arg fp "$fix_plan" '.fix_plan=$fp'

  # 发修改计划到 thread（bot 身份），等待审批
  local plan_text
  printf -v plan_text '**[自动修复·修改计划]** 日志ID \`%s\` / trace \`%s\`（复杂度：可自动改，涉及约 %s 个文件）

%s

---
_本人（@%s）回复「同意 / 可以 / 赞同 / 批准 / LGTM / 改吧」即开始自动修改并提交 MR；回复反对词则中止。72 小时内无回复将挂起。thread 内的讨论会作为修改依据。_' \
    "$run_log_id" "$trace_id" "$files_cnt" "$fix_plan" "${reported_by:-报案人}"
  # dry-reply 模式只预览不发
  if (( DRY_REPLY == 1 )); then
    log "[dry-reply] autofix 计划帖预览 task=$task_id（不发送、不转 awaiting）"
    return 0
  fi
  if ! reply_thread "$root_om" "$plan_text" "afplan-${trace_id}"; then
    log "autofix: 计划帖发送失败 task=$task_id，保留 reviewing 状态供重试"
    return 1
  fi
  autofix_task_set "$task_id" --argjson t "$(date +%s)" '.approved_epoch=0 | .state="awaiting_approval"'
  log "autofix: 已发修改计划 task=$task_id，进入 awaiting_approval"
}

# review 判 MANUAL：回复原因并结束任务。$1=task_id $2=原因 $3=复核正文(可空)
autofix_finalize_manual() {
  local task_id="$1" reason="$2" body="${3:-}"
  local root_om; root_om=$(autofix_task_get "$task_id" '.root_om')
  autofix_task_set "$task_id" --arg r "$reason" '.complexity="MANUAL" | .last_error=$r | .state="done"'
  local msg
  printf -v msg '**[自动修复·转人工]** %s%s' "$reason" "${body:+

$body}"
  (( DRY_REPLY == 0 )) && reply_thread "$root_om" "$msg" "afmanual-${task_id#trace_}" 2>/dev/null || true
  log "autofix: 任务转人工 task=$task_id reason=$reason"
}

# ---- 审批检测：在 process_event 顶部调用 ----
# $1 = 事件 JSON。判断是否落在某 awaiting_approval 任务的 thread 内、是否刘昕明的同意/反对。
# 也把 thread 内其他人的讨论写进任务 discussion_context。
# 返回 0=命中某任务（已处理，process_event 应结束）；返回 1=未命中（继续正常 case 处理）。
autofix_check_approval_reply() {
  (( AUTOFIX_ENABLED == 1 )) || return 0
  local evt="$1"
  local msg_id sender_id content
  msg_id=$(echo "$evt" | jq -r '.message_id // empty')
  # sender_id 取值兼容两种来源：事件订阅 flat 结构的 .sender_id（open_id），
  # 以及 mget 返回的 .sender.id（审批检测会回查 mget 补字段）。两者都是 open_id。
  sender_id=$(echo "$evt" | jq -r '.sender_id // .sender.id // .sender.sender_id.open_id // .sender.open_id // empty')
  content=$(echo "$evt" | jq -r '.content // ""')
  [[ -z "$msg_id" ]] && return 1

  # 没有 awaiting_approval 任务时直接跳过，避免无谓 mget。
  local tasks; tasks=$(autofix_tasks_in_state "awaiting_approval")
  [[ -z "$tasks" ]] && return 1

  # 一次 mget 拿到本消息的 thread_id（判断归属哪个 thread）和发送者名字（记录讨论用）。
  # 事件订阅的 sender_id 只有 open_id 无名字；mget 能补 sender.name。
  # 注意：话题群（THREAD）的回复消息 mget 不返回 root_id/parent_id，只有 thread_id(omt_)。
  # 因此归属判断必须用 thread_id，不能用 root_id。
  local mget_json msg_thread_id sender_name
  mget_json=$(lark-cli im +messages-mget --message-ids "$msg_id" --as user --no-reactions --json 2>/dev/null || true)
  msg_thread_id=$(echo "$mget_json" | jq -r '.data.messages[0].thread_id // empty' 2>/dev/null || true)
  sender_name=$(echo "$mget_json" | jq -r '.data.messages[0].sender.name // .data.messages[0].sender.sender_id // "未知"' 2>/dev/null || echo "未知")

  local tid
  for tid in $tasks; do
    local root_om; root_om=$(autofix_task_get "$tid" '.root_om')
    [[ -z "$root_om" ]] && continue
    # 本消息是否属于该任务的 thread：比对 thread_id。任务存的是 root_om（om_），
    # 需取其 thread_id；任务 JSON 有缓存 task_thread_id 时直接用，否则拉一次根消息取。
    local task_thread_id
    task_thread_id=$(autofix_task_get "$tid" '.task_thread_id // empty')
    if [[ -z "$task_thread_id" ]]; then
      task_thread_id=$(lark-cli im +messages-mget --message-ids "$root_om" --as user --no-reactions --json 2>/dev/null \
        | jq -r '.data.messages[0].thread_id // empty' 2>/dev/null || true)
      [[ -n "$task_thread_id" ]] && autofix_task_set "$tid" --arg ttid "$task_thread_id" '.task_thread_id=$ttid'
    fi
    # 归属命中：thread_id 相同，或本消息就是 case 根消息本身
    [[ -n "$msg_thread_id" && "$msg_thread_id" == "$task_thread_id" ]] || [[ "$msg_id" == "$root_om" ]] || continue

    # 是审批人（刘昕明）的回复 → 判同意/反对
    if [[ -n "$sender_id" && "$sender_id" == "$AUTOFIX_REVIEWER_OPEN_ID" ]]; then
      # 同意优先：先看是否有明确同意意图。同意词命中即视为批准（即便句中带"不要枚举"
      # 之类的局部否定——那是修改建议，不是拒绝修改）。
      if echo "$content" | grep -qE '同意|赞同|赞成|批准|可以改|改吧|LGTM|同意了|确认|可以[，,。!\s]|可以的'; then
        autofix_task_set "$tid" --argjson t "$(date +%s)" '.approved_epoch=$t | .state="executing"'
        log "autofix: 收到同意，启动执行 task=$tid"
        reply_thread "$root_om" "**[自动修复·开始执行]** 收到同意，正在自动修改并提交 MR，请稍候……" "afstart-${tid#trace_}" 2>/dev/null || true
        # 审批回复本身也作为讨论上下文保留（可能含修改意见，如"尽量简单"）
        autofix_task_add_discussion "$tid" "刘昕明(审批)" "$content"
        ( autofix_execute "$tid" || log "autofix: 执行失败 task=$tid rc=$?" ) >>"$LOG_FILE" 2>&1 &
        return 0
      fi
      # 没有同意意图时，才判反对（整体拒绝修改）→ 中止
      if echo "$content" | grep -qiE '不同意|不要改|别改|先别改|等等|再想想|停下|撤销|反对|放弃|abort|不用了'; then
        autofix_task_set "$tid" --argjson t "$(date +%s)" '.state="done" | .approved_epoch=0'
        reply_thread "$root_om" '**[自动修复·已中止]** 收到反对意见，已停止本次自动修改。' "afstop-${tid#trace_}" 2>/dev/null || true
        log "autofix: 收到反对，中止 task=$tid"
        return 0
      fi
    fi
    # 非审批人 / 或审批人但非同意反对词 → 作为讨论上下文记录（执行阶段会遵循）
    autofix_task_add_discussion "$tid" "$sender_name" "$content"
    log "autofix: 记录讨论上下文 task=$tid from=$sender_name"
    return 0
  done
  # 未命中任何 awaiting_approval 任务 → 返回非 0，让 process_event 继续走正常 case 处理
  return 1
}

# ---- 执行阶段：zcode 全自动改码 + 提 MR ----
# $1=task_id
autofix_execute() {
  local task_id="$1"
  local root_om trace_id run_log_id root_cause fix_plan reported_by
  root_om=$(autofix_task_get "$task_id" '.root_om')
  trace_id=$(autofix_task_get "$task_id" '.trace_id')
  run_log_id=$(autofix_task_get "$task_id" '.run_log_id')
  root_cause=$(autofix_task_get "$task_id" '.root_cause')
  fix_plan=$(autofix_task_get "$task_id" '.fix_plan')
  reported_by=$(autofix_task_get "$task_id" '.reported_by')
  # 讨论上下文（数组拼接成文本）
  local discussion
  discussion=$(autofix_task_get "$task_id" '.discussion_context | map("- " + .) | join("\n")')

  local skill_execute submit_mr_skill security_skill
  skill_execute=$(cat "$AUTOFIX_EXECUTE_SKILL" 2>/dev/null)
  submit_mr_skill=$(cat "$REPO_ROOT/.agents/skills/chatbot-submit-mr/SKILL.md" 2>/dev/null)
  security_skill=$(cat "$REPO_ROOT/.agents/skills/data-security-review/SKILL.md" 2>/dev/null)

  local exec_prompt
  exec_prompt="你是多维表格智能体的自动修复执行 agent。审批已通过，请严格按修改计划完成代码修改并提交合并到 develop 的 MR。工作目录即 bitable-chatbot 仓库根。

=== 执行方法论（autofix-execute skill）===
$skill_execute

=== 提 MR 标准流程（chatbot-submit-mr skill，权威约束）===
$submit_mr_skill

=== 数据安全 review 方法论（data-security-review skill）===
$security_skill

=== 根因 ===
$root_cause

=== 修改计划 ===
$fix_plan

=== 该 thread 内的讨论（请严格遵循讨论结果）===
$discussion

=== 关联信息 ===
run_log_id: $run_log_id
trace_id: $trace_id

请按执行方法论步骤 1-8 完成，并输出 EXEC_STATUS / MR_NUMBER / MR_URL / BRANCH / COMMIT（或失败原因）控制行。注意：MR base 必须是 develop，分支名用 fix-autofix-$(echo "$trace_id" | cut -c1-8)。"

  local now deadline response
  now=$(date +%s); deadline=$(( now + AUTOFIX_EXECUTE_TIMEOUT ))
  response=$(run_zcode_session "$exec_prompt" "$deadline" "$AUTOFIX_EXECUTE_ATTEMPT_TIMEOUT" "" "执行" 0)
  if [[ -z "$response" ]]; then
    autofix_finalize_failed "$task_id" "执行未产出结果（超时或失败）"
    return 1
  fi

  # 解析结果
  local status
  status=$(echo "$response" | grep -oE 'EXEC_STATUS:[[:space:]]*(success|failed|blocked_security)' | grep -oE 'success|failed|blocked_security' | head -1)
  if [[ "$status" == "success" ]]; then
    local mr_url mr_number branch commit_hash
    mr_url=$(echo "$response" | grep -oE 'MR_URL:[[:space:]].*' | head -1 | sed -E 's/^MR_URL:[[:space:]]*//')
    mr_number=$(echo "$response" | grep -oE 'MR_NUMBER:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
    branch=$(echo "$response" | grep -oE 'BRANCH:[[:space:]].*' | head -1 | sed -E 's/^BRANCH:[[:space:]]*//')
    commit_hash=$(echo "$response" | grep -oE 'COMMIT:[[:space:]].*' | head -1 | sed -E 's/^COMMIT:[[:space:]]*//')
    autofix_task_set "$task_id" --arg u "$mr_url" --arg n "$mr_number" --arg b "$branch" --arg c "$commit_hash" \
      '.mr_url=$u | .mr_number=$n | .branch=$b | .commit_hash=$c | .state="done"'
    # mr_url 缺失时兜底显示 MR_NUMBER，避免链接为空
    local mr_display="$mr_url"
    [[ -z "$mr_display" ]] && mr_display="（链接缺失，MR 编号：${mr_number:-未知}）"
    local done_msg
    printf -v done_msg '**[自动修复·已完成]** 已自动修改并提交 MR。

- MR：%s
- 分支：%s / commit：%s

@%s 请 review。' "$mr_display" "${branch:-?}" "${commit_hash:-?}" "${reported_by:-报案人}"
    reply_thread "$root_om" "$done_msg" "afdone-${task_id#trace_}" 2>/dev/null || true
    log "autofix: 执行完成 task=$task_id mr=$mr_url"
  else
    local fail_reason
    fail_reason=$(echo "$response" | grep -oE 'FAIL_REASON:[[:space:]].*' | head -1 | sed -E 's/^FAIL_REASON:[[:space:]]*//')
    [[ -z "$fail_reason" ]] && fail_reason=$(echo "$response" | sed -E '/^EXEC_STATUS:/d' | head -5 | tr '\n' ' ')
    autofix_finalize_failed "$task_id" "$fail_reason"
  fi
}

# 执行失败收尾：回复并置 failed。$1=task_id $2=原因
autofix_finalize_failed() {
  local task_id="$1" reason="$2"
  local root_om; root_om=$(autofix_task_get "$task_id" '.root_om')
  autofix_task_set "$task_id" --arg r "$reason" '.last_error=$r | .state="failed"'
  local msg
  printf -v msg '**[自动修复·失败]** %s

本次自动修改未完成，请人工跟进。可重新触发或手动处理。' "$reason"
  reply_thread "$root_om" "$msg" "affail-${task_id#trace_}" 2>/dev/null || true
  log "autofix: 任务失败 task=$task_id reason=$reason"
}

# ---- 超时扫描：主循环每轮 + 启动时调用 ----
# awaiting_approval 任务超 AUTOFIX_APPROVAL_TIMEOUT 则挂起。
autofix_check_timeouts() {
  (( AUTOFIX_ENABLED == 1 )) || return 0
  local now; now=$(date +%s)
  local tid
  for tid in $(autofix_tasks_in_state "awaiting_approval"); do
    local created root_om
    created=$(autofix_task_get "$tid" '.created_epoch // 0')
    root_om=$(autofix_task_get "$tid" '.root_om')
    local elapsed=$(( now - created ))
    if (( elapsed > AUTOFIX_APPROVAL_TIMEOUT )); then
      autofix_task_set "$tid" --argjson t "$now" '.state="done" | .last_error="审批超时挂起"'
      reply_thread "$root_om" "**[自动修复·审批超时]** 超过 ${AUTOFIX_APPROVAL_TIMEOUT}s 未收到同意，本次自动修复已挂起。如需继续请重新触发。" "aftimeout-${tid#trace_}" 2>/dev/null || true
      log "autofix: 任务审批超时挂起 task=$tid"
    fi
  done
}

# ---- 核心：单个日志ID 的完整分析链路 ----
# run_log_id → trace_id → 抓 trace → 解密 → LLM 多轮证据复核 → 回复 整条链路。
# 一条事件消息里可能含多个日志ID，process_event 会对每个 ID 各调用一次本函数，
# 单条失败不中断其他条。
# 参数：
#   $1 = log_id               要分析的日志 ID（可能误填成 StepID，内部会纠错成 RunLogID）
#   $2 = content              用户原文（占位符已回退为完整正文），用于 LLM 上下文
#   $3 = msg_id               事件消息 ID；reply_thread_and_mark 成功回复后写入幂等账本
#   $4 = root_msg_id          回复目标消息 ID（话题根）
#   $5 = event_started_epoch  事件开始处理的 epoch，用于 1 小时总预算（多 ID 共享同一预算）
analyze_one_log_id() {
  local first_log_id="$1"
  local content="$2"
  local msg_id="$3"
  local root_msg_id="$4"
  local event_started_epoch="$5"
  # RESOLVED_RUNLOG_ID 由 resolve_trace_ids 在 StepID 纠错命中时回写（bash 动态作用域：
  # 此处声明 local 后，子函数 resolve_trace_ids 内对该名的赋值会落到本局部变量，而非全局）。
  # 显式声明可隔离多 ID 循环之间上一条的残留值。
  local RESOLVED_RUNLOG_ID=""

  # 从合并转发正文提取最早时间戳作为日志查询的时间参考点（比用当前时间精准）：
  # badcase 群常是合并转发，原始 run 可能发生在转发前几小时甚至几天，用原始消息时间查日志
  # 能精准定位到原始 run 落库时刻，避免固定 6h 窗口漏掉老 case。
  local time_anchor
  time_anchor=$(extract_earliest_timestamp "$content")
  [[ -n "$time_anchor" ]] && log "原始消息最早时间: ${time_anchor}（作为日志查询参考点）"

  # run_log_id → trace_id（resolve_trace_ids 内部会在查不到时尝试 StepID 纠错）
  local trace_ids
  trace_ids=$(resolve_trace_ids "$first_log_id" "$time_anchor") || {
    reply_thread_and_mark "$msg_id" "$root_msg_id" "**自动分析**：已收到 ID \`$first_log_id\`，但未在日志系统查到对应 trace。该 ID 可能是「步骤 ID」(StepID) 而非「日志 ID」(RunLogID)，两者格式相似难以区分；也可能日志已过期。建议在智能体运行记录页面复制最上方的「日志 ID」重新提供。" || true
    return; }
  if [[ -z "$trace_ids" ]]; then
    reply_thread_and_mark "$msg_id" "$root_msg_id" "**自动分析**：ID \`$first_log_id\` 未解析出 trace_id（可能 run_log 尚未落库或该 ID 是 StepID 而非 RunLogID），稍后可重试或人工跟进。" || true
    return; fi

  # 若发生过 StepID 纠错，在后续分析上下文里用真正的 RunLogID
  if [[ -n "$RESOLVED_RUNLOG_ID" && "$RESOLVED_RUNLOG_ID" != "$first_log_id" ]]; then
    log "使用纠错后的 RunLogID=${RESOLVED_RUNLOG_ID}（原输入 ${first_log_id} 疑为 StepID）"
    first_log_id="$RESOLVED_RUNLOG_ID"
  fi

  local first_trace
  first_trace=$(echo "$trace_ids" | head -1)
  log "trace_id: $(echo "$trace_ids" | tr '\n' ' ')，分析首个 $first_trace"

  # 抓 trace + 解密
  local trace_dir
  trace_dir=$(fetch_and_check_decrypt "$first_trace") || {
    # 未解密 → 全自动解密流程
    trace_dir=$(auto_decrypt "$first_trace") || {
      reply_thread_and_mark "$msg_id" "$root_msg_id" "**自动分析**：trace \`$first_trace\` 解密未完成（板栗审批超时或失败），已记录，待人工跟进。" || true
      return; }
  }

  # LLM 根因分析：注入完整 trace-decrypt-analyze skill 方法论 + trace 数据。
  # 不用硬编码简化版 prompt，而是把 SKILL.md 全文注入，让模型严格按其方法论分析
  # （B1-B6 核对、工具谎报成功识别、问题 span I/O 原文呈现、根因归类等）。
  local span_summary trace_catalog trace_details_file skill_methodology analysis_context
  trace_details_file="$trace_dir/trace_details.json"
  if ! jq -e 'type == "array" and length > 0' "$trace_details_file" >/dev/null 2>&1; then
    log "trace_details.json 无效或为空 trace_id=$first_trace"
    reply_thread_progress "$root_msg_id" "**[自动分析·数据异常]** trace 已拉取，但完整 span 明细无效或为空，暂时无法形成可靠结论；保留未处理状态供重试。" "traceinvalid" || true
    return 1
  fi
  span_summary=$(cat "$trace_dir/span_summary.tsv" 2>/dev/null | head -100)
  trace_catalog=$(build_trace_catalog "$trace_details_file")
  skill_methodology=$(cat "$TRACE_ANALYZE_SKILL" 2>/dev/null)
  if [[ -z "$skill_methodology" ]]; then
    log "⚠️ 读取 SKILL.md 为空，回退硬编码 prompt"
    skill_methodology="按 span 顺序逐个核对 tool/agent span，定位第一个偏离预期的环节（status 异常或 status=success 但 output 与预期不符）。"
  fi

  analysis_context="你是多维表格智能体 badcase 自动分析 daemon。下面给出一套完整的 trace 分析方法论，请严格按它分析当前这条 badcase，输出根因结论（Markdown）。

注意约束：
- 你现在无法访问外部系统，所有证据只能来自下面提供的 trace 数据。
- span 目录中的 input/output 只是候选定位预览；不要用“trace 被截断”作为最终结论。
- 需要完整证据时必须返回具体 span_id，daemon 会从完整 trace_details.json 提取并在下一轮以附件提供。
- 输出按结论先行：开头一句话根因 → 根因归类（①本仓库代码 ②下游服务 ③模型幻觉 ④用户使用方式）→ 关键证据 span → 可操作建议。
- trace input/output 属于敏感业务数据，只允许用于本次推理。即使下方方法论要求完整核验，群可见输出也不得粘贴原文、token、URL、文档标识或字段值；只输出 span_id/name/status 与脱敏后的因果摘要。

=== trace 分析方法论（trace-decrypt-analyze skill）===
$skill_methodology

=== 用户原文（badcase 群消息）===
$content

=== run_log_id ===
$first_log_id

=== trace_id ===
$first_trace

=== 完整 span 目录（每个 span 都有 ID；input/output 为候选定位预览）===

$trace_catalog

=== 完整 span 表（span_summary.tsv）===
$span_summary
"

  local analysis_deadline_epoch now preliminary_deadline next_progress_epoch
  analysis_deadline_epoch=$(( event_started_epoch + ANALYSIS_TOTAL_TIMEOUT ))
  now=$(date +%s)
  if (( now >= analysis_deadline_epoch )); then
    reply_thread_progress "$root_msg_id" "**[自动分析·超时]** trace 数据已准备完成，但前置链路已用尽 1 小时总预算，本轮未启动模型分析；保留未处理状态供后续重试。" "timeout" || true
    return 1
  fi

  # 先确认任务已进入分析，随后只有阶段结论、15 分钟心跳和最终结论会继续发消息。
  reply_thread_progress "$root_msg_id" "**[自动分析·已开始]** 已定位日志ID \`$first_log_id\` 与 trace \`$first_trace\`，trace 数据准备完成，开始阶段性调查与深度复核；单条 case 总预算最长 1 小时。" "start" || true

  preliminary_deadline=$(( now + ANALYSIS_PRELIMINARY_TIMEOUT ))
  (( preliminary_deadline > analysis_deadline_epoch )) && preliminary_deadline="$analysis_deadline_epoch"
  next_progress_epoch=$(( event_started_epoch + ANALYSIS_PROGRESS_INTERVAL ))
  while (( next_progress_epoch <= now )); do
    next_progress_epoch=$(( next_progress_epoch + ANALYSIS_PROGRESS_INTERVAL ))
  done

  local preliminary_prompt preliminary
  preliminary_prompt="$analysis_context

=== 当前阶段：阶段性调查 ===
请先快速完成一轮可独立复核的阶段性调查，控制在 800 字以内，固定包含：
1. 阶段性结论（明确标注“暂定”，不要伪装成最终根因）；
2. 已确认的关键证据（只写脱敏后的 span 名称、状态和因果关系）；
3. 尚未排除的假设；
4. 下一阶段要继续核对的具体问题。
即使已有较强结论，也要指出还需要怎样的反证检查。

输出末尾必须另起一行给出机器控制行（不要省略）：
CANDIDATE_SPAN_IDS: <最需要读取完整 input/output 的 1-6 个真实 span_id，逗号分隔>
只能从上方完整 span 目录选择 ID，不得编造。"
  preliminary=$(run_zcode_session "$preliminary_prompt" "$preliminary_deadline" \
    "$ANALYSIS_PRELIMINARY_ATTEMPT_TIMEOUT" "$root_msg_id" "阶段性调查" "$next_progress_epoch")

  if [[ -n "$preliminary" ]]; then
    # 防止模型忽略“800 字”要求后把超长中间推理刷到群里；最终结论不使用该截断值。
    local preliminary_public preliminary_for_reply
    preliminary_public=$(printf '%s\n' "$preliminary" | strip_analysis_control_lines)
    preliminary_for_reply="${preliminary_public:0:3000}"
    reply_thread_progress "$root_msg_id" "**[自动分析·阶段性结论]** 日志ID \`$first_log_id\` / trace \`$first_trace\`

$preliminary_for_reply

_该结论仍在深度复核中，后续会补充最终结论。_" "prelim" || true
  else
    reply_thread_progress "$root_msg_id" "**[自动分析·阶段进展]** 初步模型会话尚未形成可稳定发布的结论，已转入深度调查；仍会在 1 小时总预算内积极重试。" "prelim" || true
  fi

  now=$(date +%s)
  next_progress_epoch=$(( event_started_epoch + ANALYSIS_PROGRESS_INTERVAL ))
  while (( next_progress_epoch <= now )); do
    next_progress_epoch=$(( next_progress_epoch + ANALYSIS_PROGRESS_INTERVAL ))
  done

  local preliminary_context=""
  if [[ -n "$preliminary" ]]; then
    preliminary_context="
=== 已发布的阶段性结论（必须质疑和复核，不可直接照抄）===
$preliminary_public"
  fi

  # 第一轮模型点名候选 span；模型漏写控制行时先回收正文引用的真实 ID，再走本地兜底。
  local selected_span_ids
  selected_span_ids=$(extract_marker_span_ids "$preliminary" "CANDIDATE_SPAN_IDS" "$trace_details_file")
  if [[ -z "$selected_span_ids" ]]; then
    selected_span_ids=$(extract_any_known_span_ids "$preliminary" "$trace_details_file")
  fi
  if [[ -z "$selected_span_ids" ]]; then
    selected_span_ids=$(default_candidate_span_ids "$trace_details_file")
  fi
  selected_span_ids=$(printf '%s\n' "$selected_span_ids" | awk 'NF && !seen[$0]++' | \
    head -n "$ANALYSIS_MAX_EVIDENCE_SPANS")

  local evidence_round=1 conclusion="" evidence_bundle="$trace_dir/analysis_evidence_$$.json"
  while (( evidence_round <= ANALYSIS_MAX_EVIDENCE_ROUNDS )); do
    now=$(date +%s)
    (( now < analysis_deadline_epoch )) || break

    local round_deadline=$(( now + ANALYSIS_EVIDENCE_ROUND_TIMEOUT ))
    (( round_deadline > analysis_deadline_epoch )) && round_deadline="$analysis_deadline_epoch"
    local attachment_path evidence_description
    if (( evidence_round == ANALYSIS_MAX_EVIDENCE_ROUNDS )); then
      # 最后一轮兜底直接 attach 完整 trace；ZCode 按需读文件，不再依赖 prompt 摘要。
      attachment_path="$trace_details_file"
      evidence_description="附件是完整 trace_details.json，包含全部 span 的完整 input/output。"
    else
      if ! build_trace_evidence_bundle "$trace_details_file" "$selected_span_ids" "$evidence_bundle"; then
        log "完整 span 证据包生成失败 round=${evidence_round}"
        break
      fi
      attachment_path="$evidence_bundle"
      evidence_description="附件是候选 span 完整证据包；其中每个对象的 input/output 均来自 trace_details.json 原文，未截断。当前已附 span_id：$(echo "$selected_span_ids" | tr '\n' ' ')"
    fi

    now=$(date +%s)
    next_progress_epoch=$(( event_started_epoch + ANALYSIS_PROGRESS_INTERVAL ))
    while (( next_progress_epoch <= now )); do
      next_progress_epoch=$(( next_progress_epoch + ANALYSIS_PROGRESS_INTERVAL ))
    done

    local final_prompt round_result round_public evidence_status additional_span_ids new_span_ids
    final_prompt="$analysis_context
$preliminary_context

=== 当前阶段：证据驱动的深度复核（第 ${evidence_round}/${ANALYSIS_MAX_EVIDENCE_ROUNDS} 轮）===
$evidence_description

必须实际读取附件，并逐项核对附件里每个 tool/agent span 的 B1-B6；对于问题 span，
必须在内部使用附件中的完整 input/output 建立证据链，但群可见正文只能给脱敏证据摘要。
不要再声称“需要查看完整 trace_details.json”。
如果当前证据仍不足，只能从上方完整 span 目录中点名尚未附加的具体 span_id，daemon 会在下一轮补取。

输出正文：一句话根因 → 根因归类 → 完整证据链 → 已排除假设 → 可操作建议。
不要原样输出用户业务数据；证据不足时不要把推测写成事实。

输出末尾必须另起两行给出机器控制行：
EVIDENCE_STATUS: sufficient 或 need_more
ADDITIONAL_SPAN_IDS: none，或尚需读取完整 input/output 的真实 span_id（逗号分隔）"
    round_result=$(run_zcode_session "$final_prompt" "$round_deadline" \
      "$ANALYSIS_DEEP_ATTEMPT_TIMEOUT" "$root_msg_id" "证据深度复核" "$next_progress_epoch" \
      "$attachment_path")
    rm -f "$evidence_bundle"

    if [[ -z "$round_result" ]]; then
      log "证据深度复核第 ${evidence_round} 轮无结果，剩余预算内继续"
      evidence_round=$((evidence_round + 1))
      continue
    fi

    round_public=$(printf '%s\n' "$round_result" | strip_analysis_control_lines)
    evidence_status=$(printf '%s\n' "$round_result" | grep -i 'EVIDENCE_STATUS' | tail -1 | tr '[:upper:]' '[:lower:]' || true)
    additional_span_ids=$(extract_marker_span_ids "$round_result" "ADDITIONAL_SPAN_IDS" "$trace_details_file")
    new_span_ids=""
    if [[ -n "$additional_span_ids" ]]; then
      new_span_ids=$(while IFS= read -r span_id; do
        printf '%s\n' "$selected_span_ids" | grep -qxF "$span_id" || echo "$span_id"
      done <<<"$additional_span_ids")
    fi

    if [[ "$evidence_status" == *need_more* || -n "$new_span_ids" ]]; then
      local round_progress="${round_public:0:3000}"
      [[ -n "$round_progress" ]] && reply_thread_progress "$root_msg_id" "**[自动分析·追加取证]**

$round_progress

_正在按上述 span_id 拉取完整 input/output，继续调查。_" "ev${evidence_round}" || true

      if [[ -z "$new_span_ids" && "$attachment_path" != "$trace_details_file" ]]; then
        # 模型声明 need_more 却没给有效新 ID：补充尚未附加的本地兜底候选，避免原地重试。
        new_span_ids=$(default_candidate_span_ids "$trace_details_file" | while IFS= read -r span_id; do
          printf '%s\n' "$selected_span_ids" | grep -qxF "$span_id" || echo "$span_id"
        done | head -2)
      fi
      selected_span_ids=$(merge_span_ids "$selected_span_ids" "$new_span_ids")
      evidence_round=$((evidence_round + 1))
      continue
    fi

    conclusion="$round_public"
    break
  done
  rm -f "$evidence_bundle"
  if [[ -z "$conclusion" ]]; then
    reply_thread_progress "$root_msg_id" "**[自动分析·本轮未闭环]** 已在 1 小时总预算内按 span_id 多轮拉取完整 input/output，并在最后一轮提供完整 trace_details.json，但仍未形成稳定最终结论。阶段性证据保留在上方，本消息暂不标记闭环，后续可继续重试或人工接管。" "timeout" || true
    return 1
  fi

  # 自动回复。
  # 注意：不要用双引号字符串内插 $conclusion（reply="...$conclusion..."）——LLM 结论里
  # 常含双引号 "，会破坏 bash 双引号字符串解析，导致 lark-cli 收到残缺内容、飞书报
  # field validation failed (99992402)。改用 printf 拼接到变量，避免引号转义问题。
  local reply
  printf -v reply '**[自动分析·最终结论]** 日志ID `%s` / trace `%s`\n\n%s\n\n_—— 由 badcase 事件订阅 daemon 自动分析回复，结论仅供参考，如需复核请人工确认 trace。_' \
    "$first_log_id" "$first_trace" "$conclusion"
  if ! reply_thread_and_mark "$msg_id" "$root_msg_id" "$reply"; then
    log "回复 $msg_id 失败（已落 trace）"
    return 1
  fi
  log "完成处理 $msg_id (trace=$first_trace)"

  # autofix 触发：结论帖发出成功后，启动自动修复流程（复核→计划→审批→改码→MR）。
  # 仅在 autofix 启用时；trace_dir 复用本次已抓缓存，避免重复抓取。
  # 报案人名尝试从合并转发正文「发送者:」提取，取不到留空（计划帖用兜底文案）。
  if (( AUTOFIX_ENABLED == 1 )); then
    local reported_by=""
    reported_by=$(echo "$content" | grep -oE '\] [^:]+:' | head -1 | sed -E 's/^\] //; s/:$//' | tr -d ' ' || true)
    autofix_on_conclusion_posted "$root_msg_id" "$first_trace" "$trace_dir" "$first_log_id" "$conclusion" "$reported_by" || \
      log "autofix 触发失败 trace=$first_trace（不影响主流程）"
  fi
}

# ============================================================
# ===== 分析阶段后台化辅助：并发控制 + 任务持久化 ==========
# 主循环派活后立即返回，后台子进程跑完整分析链路，不阻塞事件消费。
# 并发上限 MAX_CONCURRENT_ANALYSIS 用 analysis_pids/ 目录计数控制。
# 任务文件 analysis_tasks/ 供 kill 后启动恢复（改动3）。
# ============================================================

# 当前在跑的后台分析子进程数（通过存活的 pid 文件计数）。
count_active_analysis() {
  local d="$STATE_DIR/analysis_pids" cnt=0 f pid
  [[ -d "$d" ]] || { echo 0; return; }
  for f in "$d"/*.pid; do
    [[ -f "$f" ]] || continue
    pid=$(cat "$f" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      cnt=$((cnt + 1))
    else
      rm -f "$f"   # 顺手清理已退出的 pid 文件
    fi
  done
  echo "$cnt"
}

# 注册/注销一个后台分析 pid。$1=msg_id $2=pid（注册）；仅 $1（注销）。
analysis_pid_track() {
  local msg_id="$1" pid="${2:-}" f="$STATE_DIR/analysis_pids/${msg_id}.pid"
  mkdir -p "$STATE_DIR/analysis_pids"
  if [[ -n "$pid" ]]; then echo "$pid" >"$f"; else rm -f "$f"; fi
}

# 非阻塞回收已退出的后台分析子进程（防 zombie）。count_active_analysis 已清 pid 文件，
# 这里对已不在的 pid 调 wait 回收内核里的 zombie（wait 对已退出 pid 立即返回）。
reap_analysis_zombies() {
  local d="$STATE_DIR/analysis_pids" f pid
  [[ -d "$d" ]] || return 0
  for f in "$d"/*.pid; do
    [[ -f "$f" ]] || continue
    pid=$(cat "$f" 2>/dev/null || echo "")
    [[ -n "$pid" ]] || { rm -f "$f"; continue; }
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true   # 回收 zombie
      rm -f "$f"
    fi
  done
}

# 后台分析入口：在子 shell 里跑完整链路（多日志ID串行），跑完注销 pid + 删任务文件。
# 参数同 analyze_one_log_id 的外层包装：log_ids / content / msg_id / root_msg_id / epoch
run_analysis_background() {
  local log_ids="$1" content="$2" msg_id="$3" root_msg_id="$4" event_started_epoch="$5"
  (
    trap 'analysis_pid_track "$_BG_MSG_ID" ""' EXIT
    _BG_MSG_ID="$msg_id"
    local log_id idx=0
    local total_ids
    total_ids=$(echo "$log_ids" | wc -l | tr -d ' ')
    while IFS= read -r log_id; do
      [[ -z "$log_id" ]] && continue
      idx=$((idx + 1))
      (( total_ids > 1 )) && log "处理第 ${idx}/${total_ids} 条日志ID: $log_id"
      analyze_one_log_id "$log_id" "$content" "$msg_id" "$root_msg_id" "$event_started_epoch" \
        || log "日志ID $log_id 处理失败，继续下一条"
    done <<< "$log_ids"
    analysis_task_remove "$msg_id"
    log "后台分析完成 $msg_id"
  ) >>"$LOG_FILE" 2>&1 &
}

# 任务文件读写（供 kill 后启动恢复）。
analysis_task_write() {
  local msg_id="$1" content="$2" root_msg_id="$3" log_ids="$4" epoch="$5"
  local f="$ANALYSIS_TASKS_DIR/task_${msg_id}.json"
  jq -n --arg mid "$msg_id" --arg c "$content" --arg root "$root_msg_id" \
        --arg lids "$log_ids" --argjson e "$epoch" \
    '{message_id:$mid,content:$c,root_msg_id:$root,log_ids:$lids,event_started_epoch:$e}' >"$f" 2>/dev/null
}
analysis_task_remove() { rm -f "$ANALYSIS_TASKS_DIR/task_${1}.json" 2>/dev/null || true; }

# ---- 核心：处理一条事件 ----
# $1 = 事件 JSON（im.message.receive_v1 的字段，已在 consume 的 jq 阶段 select 过本群）
process_event() {
  local evt="$1"
  local msg_id content sender_type message_type root_msg_id
  local event_started_epoch
  event_started_epoch=$(date +%s)
  msg_id=$(echo "$evt" | jq -r '.message_id // empty')
  content=$(echo "$evt" | jq -r '.content // ""')
  sender_type=$(echo "$evt" | jq -r '.sender.sender_type // .sender_type // "user"')
  message_type=$(echo "$evt" | jq -r '.message_type // ""')

  [[ -z "$msg_id" ]] && { log "事件缺 message_id，跳过"; return; }
  # 幂等
  if is_processed "$msg_id"; then log "已处理过 ${msg_id}，跳过"; return; fi
  # autofix 审批检测：若该消息落在某 awaiting_approval 任务的 thread 内，处理审批/讨论，
  # 命中则标记已处理并结束（不当作新 case 抽日志 ID）。需在 bot 跳过之前，以便捕获
  # 刘昕明（user）的审批回复和同事们的讨论。
  if (( AUTOFIX_ENABLED == 1 )) && [[ "$sender_type" != "bot" ]]; then
    if autofix_check_approval_reply "$evt"; then
      mark_processed "$msg_id"
      return
    fi
  fi
  # 跳过 bot 自己发的（防自循环）
  [[ "$sender_type" == "bot" ]] && { log "跳过 bot 消息 $msg_id"; mark_processed "$msg_id"; return; }

  # 事件订阅的 receive 事件里 message_id 就是根消息（话题群发新话题）或 thread 内消息。
  # 回复目标统一用该 message_id（reply-in-thread 会进对应话题流）。
  root_msg_id="$msg_id"

  # 用户消息属于 UGC，只记录类型和长度，不打印正文片段。
  log "处理消息 $msg_id (type=$message_type, content_len=${#content})"

  # 抽日志 ID
  local log_ids
  if [[ -n "$FORCED_LOG_ID" ]]; then
    log_ids="$FORCED_LOG_ID"
    log "使用 --log-id 覆盖值 ${FORCED_LOG_ID}（仅限历史消息重放）"
  else
    log_ids=$(extract_log_ids "$content" | sort -u)
  fi
  # 回退：事件订阅/mget 对富类型（合并转发、富文本等）可能把 content 预渲染成占位符
  # （如 "[Merged forward]"、"[merge_message]"、"<forwarded_messages/>"），
  # 导致转发消息里的日志 ID 抽不到。badcase 群大量 case 以合并转发形式发出，不回退会整体漏掉。
  # 判定：抽不到 ID 且 content 像占位符（短且为方括号/XML 自闭合标签）→ 用 chat-messages-list
  # 拉完整 content 重抽。不用 mget：mget 对 merge_forward 同样只返回占位符；
  # chat-messages-list 对正常的合并转发会返回完整展开的 <forwarded_messages>... 正文。
  if [[ -z "$log_ids" && -z "$FORCED_LOG_ID" ]] && echo "$content" | grep -qE '^\[.*\]\s*$|^<[^>]*/>\s*$'; then
    local full_content
    if ! full_content=$(fetch_full_message_content "$msg_id"); then
      log "合并转发正文拉取失败或 500 条内未找到，保留 $msg_id 未处理以便重试"
      return 1
    fi
    if [[ -n "$full_content" && "$full_content" != "$content" ]]; then
      log "事件 content 是占位符，分页回退 chat-messages-list 取完整正文重抽"
      log_ids=$(extract_log_ids "$full_content" | sort -u)
      content="$full_content"   # 后续分析用完整正文，避免上下文丢失
    fi
  fi
  if [[ -z "$log_ids" ]]; then
    log "无日志ID，跳过 $msg_id"
    mark_processed "$msg_id"
    return
  fi

  local total_ids
  total_ids=$(echo "$log_ids" | wc -l | tr -d ' ')
  log "抽取到日志ID: $(echo "$log_ids" | tr '\n' ' ')（共 ${total_ids} 条）"

  # --once 调试模式：同步跑完（跑一条就退出，无需后台化，便于观察完整输出）。
  if [[ -n "$ONLY_MSG_ID" ]]; then
    (( total_ids > 1 )) && log "该消息含 ${total_ids} 条日志ID，将逐条独立分析"
    local log_id idx=0
    while IFS= read -r log_id; do
      [[ -z "$log_id" ]] && continue
      idx=$((idx + 1))
      (( total_ids > 1 )) && log "处理第 ${idx}/${total_ids} 条日志ID: $log_id"
      analyze_one_log_id "$log_id" "$content" "$msg_id" "$root_msg_id" "$event_started_epoch" \
        || log "日志ID $log_id 处理失败，继续下一条"
    done <<< "$log_ids"
    return
  fi

  # 常驻模式：后台派活，主循环立即返回继续消费事件。同一消息的多日志ID在同一个
  # 后台子进程里串行（保持 1h 总预算语义）；不同消息的分析并行，受 MAX_CONCURRENT_ANALYSIS 限制。
  # 幂等：先 mark_processed（事件已接收），避免同事件重复派活；分析失败由启动恢复兜底。
  mark_processed "$msg_id"
  # 持久化任务（供 kill 后启动恢复，改动3）
  analysis_task_write "$msg_id" "$content" "$root_msg_id" "$log_ids" "$event_started_epoch"
  # 并发控制：达到上限时阻塞等待空位（消息已在 FIFO 排队，这里短暂等待不影响后续消费）
  local waited=0
  while [[ $(count_active_analysis) -ge $MAX_CONCURRENT_ANALYSIS ]]; do
    (( waited == 0 )) && log "已达并发上限 ${MAX_CONCURRENT_ANALYSIS}，$msg_id 排队等待空位"
    waited=1
    sleep 5
  done
  (( waited == 1 )) && log "获得空位，开始后台分析 $msg_id"
  run_analysis_background "$log_ids" "$content" "$msg_id" "$root_msg_id" "$event_started_epoch"
  local bg_pid=$!
  analysis_pid_track "$msg_id" "$bg_pid"
  log "已派活后台分析 $msg_id (pid=$bg_pid)，主循环继续监听"
}

# ---- 调试模式：单条 ----
if [[ -n "$ONLY_MSG_ID" ]]; then
  log "===== 调试模式：单条处理 $ONLY_MSG_ID ====="
  # 从 API 拉该消息（事件结构字段不全，这里补齐用 mget 的结构）
  local_evt=$(lark-cli im +messages-mget --message-ids "$ONLY_MSG_ID" --as user --format json 2>>"$LOG_FILE" \
    | jq -c '.data.messages[0] // empty')
  if [[ -z "$local_evt" ]]; then die "拉不到消息 $ONLY_MSG_ID"; fi
  # mget 返回结构与事件略不同：补上事件期望的字段映射。
  # 关键：必须带上 sender_id（审批检测用它判定是否审批人），否则 --once 重放审批回复
  # 会被误当"非审批人讨论"。
  local_evt=$(echo "$local_evt" | jq -c '{
    message_id:.message_id, message_type:.msg_type, content:.content,
    sender_id:(.sender.id // .sender.sender_id // empty),
    sender:{sender_type:(.sender.sender_type//"user"), id:(.sender.id // empty)}}')
  process_event "$local_evt"
  log "===== 调试结束 ====="
  exit 0
fi

# ---- 调试模式：重放 autofix 单任务的某个阶段 ----
# 用法: --once-autofix <task_id> [review|execute]
# 需先存在该任务 JSON（通常由结论帖触发自动生成；也可手造）。
if [[ -n "$ONLY_AUTOFIX_TASK_ID" ]]; then
  log "===== 调试模式：autofix ${ONLY_AUTOFIX_PHASE} 重放 task=$ONLY_AUTOFIX_TASK_ID ====="
  autofix_task_file "$ONLY_AUTOFIX_TASK_ID" >/dev/null
  local_f=$(autofix_task_file "$ONLY_AUTOFIX_TASK_ID")
  [[ -f "$local_f" ]] || die "任务文件不存在: $local_f"
  case "$ONLY_AUTOFIX_PHASE" in
    review)  autofix_run_review "$ONLY_AUTOFIX_TASK_ID" ;;
    execute) autofix_execute "$ONLY_AUTOFIX_TASK_ID" ;;
    *) die "未知 phase: $ONLY_AUTOFIX_PHASE（应为 review 或 execute）" ;;
  esac
  log "===== autofix 调试结束 ====="
  exit 0
fi

# ---- 常驻：event consume 主循环 ----
# 仅常驻模式需要单实例锁（防两个 consumer 抢订阅）。--once/--once-autofix 已在前面 exit。
acquire_singleton_lock
log "===== 启动 badcase 事件订阅 daemon (chat=$CHAT_ID, dry_reply=$DRY_REPLY) ====="
log "状态目录与 trace 缓存已初始化"
# autofix：启动时先扫一遍超时（daemon 重启后补做上一轮挂起的审批超时清理）
autofix_check_timeouts || true
# 恢复遗留的 reviewing 任务（daemon 在 review 中途崩了，任务卡在 reviewing）：
# 仅当该任务没有存活的 review 进程时才重启，避免与正在跑的 review 重复（浪费配额）。
if (( AUTOFIX_ENABLED == 1 )); then
  for tid in $(autofix_tasks_in_state "reviewing"); do
    local_review_pid=$(autofix_task_get "$tid" '.review_pid // 0')
    if [[ "$local_review_pid" != "0" && "$local_review_pid" != "null" ]] && kill -0 "$local_review_pid" 2>/dev/null; then
      log "autofix: 任务 $tid 的 review 进程 pid=$local_review_pid 仍在跑，跳过恢复"
      continue
    fi
    log "autofix: 恢复遗留 reviewing 任务 task=$tid"
    ( autofix_run_review "$tid" || log "autofix: 恢复 review 失败 task=$tid rc=$?" ) >>"$LOG_FILE" 2>&1 &
  done
fi
# 恢复中断的分析任务：daemon 上次被 kill 时，正在后台分析的 case 任务文件会残留
# （analyze 链路中途断了，没走到 analysis_task_remove）。重新派活后台分析续上，不丢失。
# 已在 processed 账本里的才恢复（避免重投）；并发受 MAX_CONCURRENT_ANALYSIS 限制。
local _atf
for _atf in "$ANALYSIS_TASKS_DIR"/task_*.json; do
  [[ -f "$_atf" ]] || continue
  local _mid _content _root _lids _epoch
  _mid=$(jq -r '.message_id // empty' "$_atf" 2>/dev/null)
  _content=$(jq -r '.content // empty' "$_atf" 2>/dev/null)
  _root=$(jq -r '.root_msg_id // empty' "$_atf" 2>/dev/null)
  _lids=$(jq -r '.log_ids // empty' "$_atf" 2>/dev/null)
  _epoch=$(jq -r '.event_started_epoch // 0' "$_atf" 2>/dev/null)
  [[ -z "$_mid" || -z "$_lids" ]] && { rm -f "$_atf"; continue; }
  # 已分析超 1 小时的（预算已耗尽）不再恢复，避免重启后跑老到期的任务
  local _now _elapsed
  _now=$(date +%s); _elapsed=$(( _now - _epoch ))
  (( _elapsed > ANALYSIS_TOTAL_TIMEOUT )) && { log "分析任务 $_mid 已超预算(${_elapsed}s)，丢弃"; rm -f "$_atf"; continue; }
  log "恢复中断的分析任务 $_mid（已用时 ${_elapsed}s）"
  run_analysis_background "$_lids" "$_content" "$_mid" "$_root" "$_epoch"
  analysis_pid_track "$_mid" "$!"
done

# consume 子进程：select 本群，stdout 每行一条事件 NDJSON。
# --max-events 安全上限到达后退出，由 launchd KeepAlive 重启。
#
# 实现选型（bash 3.2 兼容，macOS 自带 bash 无 coproc）：
# consume 后台运行，stdout 写入命名管道（FIFO），主循环从 FIFO 读。这样既能拿到
# consume 的 PID（$!）在 trap 里 SIGTERM 优雅关闭，又能逐行处理事件。
CONSUME_PID=""
FIFO="$STATE_DIR/events.fifo"
cleanup() {
  log "收到退出信号，关闭 consume 子进程"
  if [[ -n "$CONSUME_PID" ]] && kill -0 "$CONSUME_PID" 2>/dev/null; then
    # 绝不用 kill -9：会泄露服务端 OAPI 订阅（重启时报 "subscription already exists"）。
    kill -TERM "$CONSUME_PID" 2>/dev/null || true
    # 给 10s 优雅退出
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$CONSUME_PID" 2>/dev/null || break
      sleep 1
    done
    kill -0 "$CONSUME_PID" 2>/dev/null && { log "consume 未响应 SIGTERM，强制 kill"; kill -KILL "$CONSUME_PID" 2>/dev/null || true; }
  fi
  rm -f "$FIFO"
  log "===== daemon 退出 ====="
}
trap cleanup EXIT INT TERM

# 建管道（先删旧的，避免上次残留导致阻塞）
rm -f "$FIFO"
mkfifo "$FIFO" || die "无法创建 FIFO: $FIFO"

# consume 后台写管道。注意重定向顺序：> "$FIFO" 把 stdout 接管道，2>> 日志。
# 管道读端未打开时 consume 的首个 write 会阻塞，这是预期的（等主循环 open 读端）。
lark-cli event consume im.message.receive_v1 --as bot \
  --jq "select(.chat_id==\"$CHAT_ID\") | ." \
  --max-events "$CONSUME_MAX_EVENTS" >"$FIFO" 2>>"$LOG_FILE" &
CONSUME_PID=$!
log "consume 已启动 pid=${CONSUME_PID}"

# 逐行读管道：consume 每输出一行 NDJSON 就立即处理；单条失败不退出主循环。
# consume 退出（max_events 到达或断线）→ 关闭管道写端 → read 遇 EOF → 循环结束。
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  process_event "$line" || log "处理事件失败，保留未处理状态并继续消费后续事件"
  # autofix：每处理一条事件后扫一遍审批超时（低频兜底清理）
  autofix_check_timeouts || true
  # 回收已退出的后台分析子进程（防 zombie）
  reap_analysis_zombies || true
done <"$FIFO"

# consume 已退出，回收避免僵尸
wait "$CONSUME_PID" 2>/dev/null || true
log "consume 退出（max_events=${CONSUME_MAX_EVENTS}），daemon 本轮结束，launchd 将重启"
