#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/dev/find-runlog-log.sh --run-log-id <id> [options]

Options:
  --env <prod|pre|boe|both|all>   Default: both (prod + pre)
  --hours <hours>                 Lookback window. Default: 6
  --out-dir <dir>                 Default: /tmp/bitable-runlog-<id>-<timestamp>
  --poll-timeout <seconds>        Default: 60
  --max-logs <count>              Default: 200
  --limit <count>                 Default: 50

The script searches exact structured keyword run_log_id=<id> with selected
diagnostic fields, then prints hit files, agent_log_id, trace_id, run_log
summary, and a suggested small-window command for fetching the full agent log.
Result files may contain selected log messages; treat the output directory as
a local debug artifact.
EOF
}

run_log_id=""
env_mode="both"
hours="6"
out_dir=""
poll_timeout="60"
max_logs="200"
limit="50"
abs_start=""
abs_end=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-log-id)
      run_log_id="${2:-}"
      shift 2
      ;;
    --env)
      env_mode="${2:-}"
      shift 2
      ;;
    --hours)
      hours="${2:-}"
      shift 2
      ;;
    --start)
      abs_start="${2:-}"
      shift 2
      ;;
    --end)
      abs_end="${2:-}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:-}"
      shift 2
      ;;
    --poll-timeout)
      poll_timeout="${2:-}"
      shift 2
      ;;
    --max-logs)
      max_logs="${2:-}"
      shift 2
      ;;
    --limit)
      limit="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$run_log_id" ]]; then
  echo "--run-log-id is required" >&2
  usage >&2
  exit 2
fi
if [[ ! "$run_log_id" =~ ^[0-9]+$ ]]; then
  echo "--run-log-id must be numeric" >&2
  exit 2
fi
if ! [[ "$hours" =~ ^[0-9]+$ ]] || [[ "$hours" -le 0 ]]; then
  echo "--hours must be a positive integer" >&2
  exit 2
fi

case "$env_mode" in
  prod|pre|boe|both|all) ;;
  *)
    echo "--env must be prod, pre, boe, both, or all" >&2
    exit 2
    ;;
esac

if ! command -v bytedcli >/dev/null 2>&1; then
  echo "bytedcli not found in PATH" >&2
  exit 127
fi
if ! command -v node >/dev/null 2>&1; then
  echo "node not found in PATH; bytedcli may fail in non-login shells" >&2
  exit 127
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found in PATH" >&2
  exit 127
fi

if [[ -z "$out_dir" ]]; then
  out_dir="/tmp/bitable-runlog-${run_log_id}-$(date +%s)"
fi
mkdir -p "$out_dir"

envs=()
case "$env_mode" in
  prod)
    envs=(prod)
    ;;
  pre)
    envs=(pre)
    ;;
  boe)
    envs=(boe)
    ;;
  both)
    envs=(prod pre)
    ;;
  all)
    envs=(prod pre boe)
    ;;
esac

env_config() {
  case "$1" in
    prod)
      printf '%s\t%s\t%s\t%s\n' "cn" "bitable.ai.chatbot" "China-North" ""
      ;;
    pre)
      printf '%s\t%s\t%s\t%s\n' "cn" "bitable.ai.chatbot_pre_release" "China-North" ""
      ;;
    boe)
      printf '%s\t%s\t%s\t%s\n' "boe" "bitable.ai.chatbot" "China-BOE" "--site boe"
      ;;
  esac
}

log_fields="__timestamp,K_LOGID,__logid,K_METHOD,_level,_msg,_psm,_primary_psm,agent_log_id,trace_id,serial_id,run_log_serial_id,status,duration_ms,trigger_time,trigger_type"

segments_file="$out_dir/segments.tsv"
python3 - "$hours" >"$segments_file" <<'PY'
from datetime import datetime, timedelta, timezone
import sys

hours = int(sys.argv[1])
now = datetime.now(timezone.utc).replace(microsecond=0)
start = now - timedelta(hours=hours)
max_window = timedelta(hours=6)
i = 0
while start < now:
    end = min(start + max_window, now)
    print(f"{i}\t{start.isoformat().replace('+00:00', 'Z')}\t{end.isoformat().replace('+00:00', 'Z')}")
    start = end
    i += 1
PY

echo "result_dir: $out_dir"
echo "keyword: run_log_id=$run_log_id"
echo "note: result files contain selected log fields; treat as local debug artifacts"

for env_name in "${envs[@]}"; do
  IFS=$'\t' read -r _site psm vregion site_args <<<"$(env_config "$env_name")"
  while IFS=$'\t' read -r seg_idx start_iso end_iso; do
    prefix="$out_dir/${env_name}-${seg_idx}"
    {
      printf 'env=%s\npsm=%s\nvregion=%s\nstart=%s\nend=%s\n' \
        "$env_name" "$psm" "$vregion" "$start_iso" "$end_iso"
    } >"${prefix}.meta"

    echo "search env=$env_name psm=$psm start=$start_iso end=$end_iso"
    # site_args 可能为空（prod/pre 无 --site boe）。
    # bash 3.2（macOS 自带）下，对空数组用 "${arr[@]}" 在 set -u 中会报 unbound variable。
    # 因此只在 site_args 非空时插入 --site boe，否则直接调 bytedcli（无站点参数）。
    if [[ -n "$site_args" ]]; then
      # shellcheck disable=SC2206
      site_parts=($site_args)
      bytedcli "${site_parts[@]}" log search-psm-log \
        --psm "$psm" \
        --vregion "$vregion" \
        --start "$start_iso" \
        --end "$end_iso" \
        --keyword "run_log_id=$run_log_id" \
        --fields "$log_fields" \
        --max-logs "$max_logs" \
        --limit "$limit" \
        --poll-timeout "$poll_timeout" \
        --output file >"${prefix}.stdout" 2>"${prefix}.stderr" || true
    else
      bytedcli log search-psm-log \
        --psm "$psm" \
        --vregion "$vregion" \
        --start "$start_iso" \
        --end "$end_iso" \
        --keyword "run_log_id=$run_log_id" \
        --fields "$log_fields" \
        --max-logs "$max_logs" \
        --limit "$limit" \
        --poll-timeout "$poll_timeout" \
        --output file >"${prefix}.stdout" 2>"${prefix}.stderr" || true
    fi

    log_file="$(awk -F': ' '/Log output file:/ {print $2}' "${prefix}.stdout" | tail -1)"
    if [[ -n "$log_file" && -f "$log_file" ]]; then
      cp "$log_file" "${prefix}.log"
    else
      : >"${prefix}.log"
    fi
  done <"$segments_file"
done

python3 - "$out_dir" <<'PY'
from datetime import datetime, timedelta, timezone
from pathlib import Path
import re
import sys

out_dir = Path(sys.argv[1])
hits = []
for log_path in sorted(out_dir.glob("*.log")):
    text = log_path.read_text(errors="replace")
    if not text or "No log items found" in text:
        continue
    meta = {}
    meta_path = log_path.with_suffix(".meta")
    if meta_path.exists():
        for line in meta_path.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                meta[k] = v
    hits.append((log_path, meta, text))

print()
print(f"hits: {len(hits)}")
if not hits:
    print(f"no exact run_log_id hit; inspect stdout/stderr under {out_dir}")
    sys.exit(0)

def first(pattern, text):
    m = re.search(pattern, text)
    return m.group(1) if m else ""

def all_ts(text):
    out = []
    for raw in re.findall(r"__timestamp=([^ ]+)", text):
        try:
            out.append(datetime.fromisoformat(raw.replace("Z", "+00:00")))
        except ValueError:
            pass
    return out

for log_path, meta, text in hits:
    agent_log_id = first(r"agent_log_id=([^ ]+)", text) or first(r"K_LOGID=([^ ]+)", text)
    trace_id = first(r"trace_id=([^ ]+)", text)
    serial_id = first(r"serial_id=([^ ]+)", text) or first(r"run_log_serial_id=([^ ]+)", text)
    status = first(r" status=([0-9]+)", text)
    duration_ms = first(r"duration_ms=([0-9]+)", text)
    trigger_time_ms = first(r"trigger_time=([0-9]{13})", text)
    trigger_type = first(r"trigger_type=([^ ]+)", text)
    timestamps = all_ts(text)
    start = min(timestamps) if timestamps else None
    end = max(timestamps) if timestamps else None
    query_start_dt = start
    query_end_dt = end
    if trigger_time_ms:
        trigger_dt = datetime.fromtimestamp(int(trigger_time_ms) / 1000, tz=timezone.utc)
        query_start_dt = trigger_dt
        if duration_ms:
            query_end_dt = trigger_dt + timedelta(milliseconds=int(duration_ms))
        else:
            query_end_dt = trigger_dt + timedelta(minutes=10)

    print()
    print(f"hit_file: {log_path}")
    print(f"env: {meta.get('env', '')}")
    print(f"psm: {meta.get('psm', '')}")
    print(f"vregion: {meta.get('vregion', '')}")
    print(f"agent_log_id: {agent_log_id}")
    print(f"trace_id: {trace_id}")
    print(f"serial_id: {serial_id}")
    print(f"trigger_type: {trigger_type}")
    print(f"status: {status}")
    print(f"duration_ms: {duration_ms}")
    print(f"trigger_time_ms: {trigger_time_ms}")
    if start and end:
        print(f"log_time_range: {start.isoformat()} .. {end.isoformat()}")
    if agent_log_id and query_start_dt and query_end_dt:
        query_start = (query_start_dt - timedelta(minutes=1)).astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
        query_end = (query_end_dt + timedelta(minutes=1)).astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
        print("next_agent_log_query:")
        site_prefix = "--site boe " if meta.get("env") == "boe" else ""
        print(
            f"  bytedcli {site_prefix}log search-psm-log --psm \"{meta.get('psm', '')}\" "
            f"--vregion \"{meta.get('vregion', '')}\" --start \"{query_start}\" "
            f"--end \"{query_end}\" --keyword \"{agent_log_id}\" "
            "--max-logs 500 --limit 100 --poll-timeout 90 --output file"
        )
PY
