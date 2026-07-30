---
name: "trace-decrypt-analyze"
description: "当用户发送日志 ID（run_log_id，例如 7590084861042927618、7590... 这样的纯数字或字母数字 ID，或用户说「分析这个日志/这个 run/这次运行」并附带 ID）时，自动触发：通过 run_log_id 反查 traceID，自动申请 Fornax trace 解密权限（BPM API 创建工单 + 飞书群 @ 板栗推进审批），拉取解密后的完整 trace（含 LLM input/output、工具调用入参/出参），并按标准方法论分析 trace：完整时间线还原与首次异常定位（当单条 trace 无法定位根因时，向上追查同一 chatbot 的历史 run，建立完整时间线，定位第一次异常，结合运行时决策日志和代码验证根因）、验证最终输出是否符合预期、逐个核对每个工具的 input/output 是否符合预期（重点识别工具谎报成功、参数错配、写操作假成功等）、对照代码验证根因、输出分析报告与修复计划。适用于排查 Agent 跑飞、超时、结果缺失、写入未生效、输出不稳定、能力缺失/工具不可见等 badcase。"
---

# Trace 解密分析

## 适用场景

- 用户提供 run_log_id，需要拿到对应 Agent 运行的完整 trace（含解密的 LLM input/output、工具调用入参/出参）。
- 排查 Agent 打转（tool_step 爆炸）、超时、结果内容缺失、输出不稳定等问题。
- 对比多次运行（好/坏 case）的工具调用分叉点。
- 定位到问题后，对照代码验证根因，输出修复计划，经用户确认后修代码提 MR。

## 工具依赖

- `bytedcli`（已完成 ByteCloud 认证）—— 日志检索、BPM 工单、fornax trace 拉取、JWT 获取。
- `fornax-cli`（由 bytedcli 自动代理安装）—— 拉取解密 trace。
- `lark-cli`（已认证）—— 飞书群发消息 @ 板栗。
- 先确保 `bytedcli auth status` 和 `lark-cli auth status` 都显示已认证。

## 关键常量（固定值，直接复用）

| 常量 | 值 | 用途 |
|---|---|---|
| Fornax workspace_id | `7590084861042927618` | chatbot 团队 Fornax space，fornax trace get 必填 |
| BPM workflow_config_id | `32544` | Trace解密查看申请 工单的固定配置 ID |
| BPM workflow_key | `trace_view_auth` | 工单工作流标识 |
| BPM target_system | `Fornax_Trace` | 工单目标系统 |
| BPM 创建工单 API | `POST https://bpm.bytedance.net/api/inf/v1/workflow/record` | 创建解密工单 |
| BPM 查询工单 API | `GET https://bpm.bytedance.net/api/inf/v1/workflow/record/{id}` | 查工单状态 |
| trace解密专用群 chat_id | `oc_281c368b7b46b13b49acc96d0f650d70` | 板栗所在的飞书群 |
| 板栗 open_id | `ou_fef959b84c89c1f9d11f50ab34935772` | 推进 BPM 审批的机器人 |
| valid_day | `30` | 解密有效期 30 天 |

---

## 完整 Workflow

### 阶段 1：run_log_id → traceID

#### 1.1 日志检索

用 `bytedcli log search-psm-log` 检索 run_log_id，从日志里抽 traceID。

环境默认值（与 chatbot-log-id skill 一致）：

| 场景 | PSM | vregion | site |
|---|---|---|---|
| 线上/BOE（默认） | `bitable.ai.chatbot` | `China-North` / `China-BOE` | cn |
| Pre/预发 | `bitable.ai.chatbot_pre_release` | `China-North` | cn |

用户未指定环境时默认查线上 `bitable.ai.chatbot` + `China-North`。

```bash
bytedcli log search-psm-log \
  --psm "bitable.ai.chatbot" \
  --vregion "China-North" \
  --start "$(date -v-6H -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --end "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --keyword "<RUN_LOG_ID>" \
  --max-logs 200 \
  --limit 50 \
  --output file
```

注意：
- macOS 的 `date` 不支持 `-d`，用 `date -v-6H`（往前 6 小时）。
- 单次搜索时间窗超过 6 小时会查不到，需分多个 6 小时区间。
- 如果用户给了精确时间，直接用 ISO8601 字面量，例如 `--start "2026-06-23T05:00:00Z" --end "2026-06-23T07:00:00Z"`。

#### 1.2 从日志提取 traceID 和 run 元信息

从输出文件中提取，优先级如下：

**优先级 1：`GetRunLogDetail read success` 行（最权威）**

含 trace_id、status、duration_ms、step_count、trigger_time 等完整元信息：
```
_msg=[RunLog] read success: method=GetRunLogDetail ... run_log_id=<ID> ... trace_id=<TRACE_ID> status=<N> duration_ms=<MS> step_count=<N>
```

**优先级 2：`upsert run log done` 行（agent_start/agent_end 事件）**

含 trace_id，但可能没有 status/duration/step_count 汇总：
```
_msg=[RunLog] upsert run log done: event_type=agent_start ... trace_id=<TRACE_ID>
```

**优先级 3：`ListRunLogs` 响应**

只有前两者都查不到时才用。从接口响应里能确认 run 存在（Status/DurationMs），但**不含 trace_id**。此时需提示用户从 CCM run log 详情页直接复制 trace_id。

抽取命令示例：

```bash
LOG_FILE="<bytedcli 输出的文件路径>"

# trace_id 出现频次（确认唯一性）
grep -oE 'trace_id=[a-f0-9]+' "$LOG_FILE" | sort | uniq -c

# 完整元信息（从 GetRunLogDetail 行）
grep -oE 'method=GetRunLogDetail[^"]*messages' "$LOG_FILE" | head -1 \
  | grep -oE '(run_log_id|trace_id|status|duration_ms|step_count|trigger_time|_env|_idc|user_id|chatbot_id|trigger_type)=[^ ]+' | sort -u
```

**若出现多个不同 trace_id**：说明该 run_log_id 对应多次 Agent 运行（重试/扇出）。需结合 `__timestamp` 和用户描述，确认关心哪一次；必要时把所有 traceID 都列出，附各自时间，让用户选择。

**若完全查不到 trace_id**（只有 ListRunLogs 命中）：该 run 可能没打 ChatbotRunLogEvent，或走了其它日志流。提示用户从 CCM run log 详情页直接复制 trace_id。

#### 1.3 run_log_id 与 traceID 的关系

一条 run_log_id 可能对应：
- **单次 Agent 运行**：只有 1 个 traceID。
- **多次 Agent 运行/重试/扇出**：有多个 traceID（需按时间或按用户意图选择）。

因此第一步「转 traceID」必须确认唯一性，不能默认 1:1。

---

### 阶段 2：申请 trace 解密（全自动）

#### 2.1 先尝试直接拉取 trace（判断是否已有解密权限）

```bash
bytedcli --json fornax trace get \
  --trace-id "<TRACE_ID>" \
  --workspace-id 7590084861042927618 \
  --since "<ISO8601 start>" \
  --until "<ISO8601 end>" \
  -o ./trace_output
```

时间窗：从阶段 1 的 `trigger_time`（毫秒）转 ISO8601，前后各留 1 小时余量：

```bash
TZ=Asia/Shanghai date -r $((<TRIGGER_TIME_MS> / 1000)) '+%Y-%m-%dT%H:00:00+08:00'
```

也可用 `--last-n-minutes 43200`（30 天）替代时间窗。

#### 2.2 判断是否已解密

**关键：不要依赖 `reserved_encrypt` 字段的 `decrypt_success`**（`--tree` 模式下该字段恒为 true 但不代表真实解密）。正确判断方法：取任一 `span_type=model` 的 span，检查 output 是否为明文 JSON：

```python
import json
spans = [json.loads(l) for l in open('<TRACE_FILE>') if l.strip()]
for s in spans:
    if s.get('span_type') == 'model':
        out = s.get('output', '')
        is_decrypted = out.lstrip().startswith('{') and '"choices"' in out[:100]
        print(f"decrypt: {'OK' if is_decrypted else 'FAIL'}")
        break
```

- **已解密**：output 是明文 `{"choices":[{"finish_reason":...`，跳过阶段 2 剩余步骤，直接进阶段 3。
- **未解密**：output 是 `AUgKPAAAAAAAA...` 压缩加密串，继续 2.3。

#### 2.3 创建 BPM 解密工单（API 自动创建）

`bytedcli bpm ticket` 没有 create 命令，但 BPM 后端 API 支持直接 POST 创建。用 bytedcli 的 JWT 认证：

```bash
JWT=$(bytedcli auth get-bytecloud-jwt-token 2>/dev/null)

curl -s -X POST "https://bpm.bytedance.net/api/inf/v1/workflow/record" \
  -H "X-Jwt-Token: $JWT" \
  -H "Content-Type: application/json; charset=utf-8" \
  -H "Accept: application/json, text/plain, */*" \
  -H "origin: https://cloud.bytedance.net" \
  -H "referer: https://cloud.bytedance.net/" \
  -d '{
    "workflow_config_id": 32544,
    "config": {
      "trace_id": "<TRACE_ID>",
      "workspace_id": "7590084861042927618",
      "valid_day": "30",
      "reasoning": "1"
    }
  }'
```

返回 `data.id` 即 BPM record ID（如 `106876182`），status 初始为 `approval`。

创建后 `node_status.approval` 会自动变成 `finished`（lushenggang 自动审批），但整体还卡在 approval，需要下一步 @ 板栗推进到 done。

#### 2.4 在 trace解密专用群 @ 板栗推进工单

用 bot 身份发送 BPM 链接 @ 板栗。**关键：必须用 `<at>` 语法，不能手写 mentions 数组。**

```bash
lark-cli im +messages-send \
  --chat-id "oc_281c368b7b46b13b49acc96d0f650d70" \
  --as bot \
  --text 'https://bpm.bytedance.net/record/<RECORD_ID> <at user_id="ou_fef959b84c89c1f9d11f50ab34935772">板栗</at>'
```

**mention 格式坑点**（已验证）：
- ✅ 正确：`--text '... <at user_id="ou_fef959b84c89c1f9d11f50ab34935772">板栗</at>'`，lark-cli shortcut 会自动归一化为 mention，板栗能收到 @。
- ❌ 错误：`--content '{"text":"... @_user_1","mentions":[{"key":"@_user_1","id":"ou_xxx",...}]}'`，mention 不渲染（`lark-cli im +messages-mget` 查看会发现 `mentions: []`），板栗收不到 @，工单卡住。

板栗收到 @ 后会推进工单到 `done` 状态（约 10-20 秒）。

**批量 @ 板栗解密多个工单时**：必须把**每个工单的完整 BPM 链接**都放进同一条消息，且**链接之间用空格分隔**，板栗才能逐个识别并推进。不要只贴一个链接或把多个 record id 挤在一起。

```bash
# ✅ 正确：多条完整链接，空格分隔，只 @ 一次板栗
lark-cli im +messages-send \
  --chat-id "oc_281c368b7b46b13b49acc96d0f650d70" \
  --as bot \
  --text 'https://bpm.bytedance.net/record/106883637 https://bpm.bytedance.net/record/106885303 https://bpm.bytedance.net/record/106885400 <at user_id="ou_fef959b84c89c1f9d11f50ab34935772">板栗</at>'

# ❌ 错误：只贴 record id（板栗无法识别）
--text '106883637 106885303 <at ...>板栗</at>'

# ❌ 错误：链接连在一起没有空格（板栗解析不出多个链接）
--text 'https://bpm.bytedance.net/record/106883637https://bpm.bytedance.net/record/106885303 <at ...>板栗</at>'
```

注意：批量场景下板栗处理多工单可能稍慢，轮询（2.5）时需确认**所有** record 都变 done 再重新拉取 trace。

#### 2.5 轮询确认工单完成

```bash
bytedcli --json bpm ticket get --ticket-id <RECORD_ID> 2>/dev/null
# 看 status 是否变为 "done"，finished 是否为 1
```

工单 done 后，重新 `bytedcli fornax trace get`（2.1 同样命令）即可拿到明文 input/output。

#### 2.6 排错

| 问题 | 原因 | 解决 |
|---|---|---|
| 工单卡在 approval 不变 done | 板栗没收到 @ | `lark-cli im +messages-mget` 检查消息 mentions 是否非空；重发一次 |
| curl 创建工单报权限错误 | JWT 过期 | 重新 `bytedcli auth get-bytecloud-jwt-token` |
| `--tree` 显示 decrypt_success:true 但实际未解密 | tree 模式不可信 | 必须用非 tree 模式拉取，检查 model output 是否明文 |
| fornax trace get 报 workspace 错误 | workspace_id 不对 | chatbot 团队固定用 `7590084861042927618` |

---

### 阶段 3：解析 trace（JSONL）

trace 文件是 **JSONL**（每行一个 span，不是一个 JSON 数组），**必须按行解析**：

```python
import json
spans = []
with open('<TRACE_FILE>') as f:
    for line in f:
        line = line.strip()
        if line:
            spans.append(json.loads(line))
```

每个 span 关键字段：

| 字段 | 含义 |
|---|---|
| `span_type` | `fornax_query`(根)/`agent`/`tool`/`model`/`prompt` |
| `span_name` | 具体名称，如 `ReceiveMessage`、`agent`、`table_agent_mcp.get_records`、`ark` |
| `duration` | 毫秒 |
| `status` | `success` / `error` |
| `input` / `output` | 解密后的入参/出参（字符串，可能内含 JSON，需二次 `json.loads`） |
| `parent_id` / `span_id` | 构成调用树 |
| `started_at` | 微秒时间戳，用于排序 |
| `custom_tags` | chatbot_id / user_id / env / trigger_type 等 |
| `system_tags.reserved_encrypt` | 加密信息（但 decrypt_success 字段不可信，见 2.2） |

---

### 阶段 4：完整时间线还原与首次异常定位

> **核心洞察（第一性原理）**：用户提供的那条 trace 只是完整时间线上的一个点——它可能是问题的**表象**而非**根源**。问题的根源往往在更早的运行/对话轮次中。**完整时间线上的第一次异常，往往是问题的关键。** trace spans 回答"Agent 做了什么"，运行时决策日志回答"Agent 有哪些工具/能力可选"，代码回答"为什么能力被限制"。三者缺一不可。

#### 4.1 什么时候必须扩大时间线（不能只看用户提供的那条 trace）

以下三类场景，单条 trace 内部分析无法定位根因，**必须**执行本阶段的时间线还原：

1. **单条 trace 所有工具都 status=success，但最终结果不符合用户预期。** 这说明问题可能不在"执行"而在"能力/配置"——该用的工具压根没出现在 LLM 的可选列表里（工具被 lazy discovery 隐藏、权限缺失、FG 未开、工具注册条件不满足）。trace 只记录"做了什么"，不会记录"有哪些工具可用但没选"。
2. **用户描述的问题跨多次对话/多次运行。** 典型措辞："上次让他……他说做了但实际没有"、"前几天还好好的今天突然不行了"、"上周就报错了"。根因可能在更早的 run 里，用户提供的只是最后一条。
3. **用户提供的 run log 是他侧视角看到的最后一条，而非问题第一次出现的 run。** 需要向上追溯找到第一次异常发生在哪一轮。

如果用户的 case 明确是单次执行的执行错误（如超时、打转、写操作参数错配），可以直接跳到阶段 5 逐工具核对，本阶段非必须。

#### 4.2 从单条 trace 扩展到完整时间线

**目标**：把"一条 trace"扩展成"该 chatbot 在问题时间窗内的全部运行序列"。

从阶段 1 已提取的元信息中拿到 `chatbot_id`、`session_id`、`job_id`、`trigger_time`。以此为锚点，搜索该 chatbot 在问题前后（建议前后各扩 1-2 小时）的全部 run：

```bash
# 用 chatbot_id 搜索该 chatbot 在时间窗内的全部 run 的发布状态
bytedcli log search-psm-log \
  --psm "bitable.ai.chatbot" \
  --vregion "China-North" \
  --start "<问题时间-2h>" \
  --end "<问题时间+2h>" \
  --keyword "<CHATBOT_ID>" \
  --keyword "executor publish status" \
  --max-logs 300 \
  --limit 200 \
  --output file
```

从输出中提取每条 run 的：`serial_id` / `trace_id` / `turn_id` / `status` / `duration_ms` / `tool_count` / `err_len`。

**对话类触发（larkMessage 等）**：一个 session 内可能有多个 turn（多轮对话）。用 `TriggerCallback` 日志或 `executor publish status` 日志，按 `turn_id` 排序还原完整对话序列：

```
18:39:47  turn 1  serial=...27527129  trace=0b102cca...  status=3  tool_count=2   [novabase_analysis_agent, use_skill]
18:41:15  turn 2  serial=...9710971067 trace=16b89b4...  status=3  tool_count=0   [无工具，纯文本回复]
18:46:24  turn 3  serial=...852793018  trace=41a847de...  status=3  tool_count=6   [6× search_users，3次失败]
```

**非对话类触发（schedule/comment/record 触发器等）**：每次触发是独立 run，按 trigger_time 排序即可。

#### 4.3 定位完整时间线上的第一次异常

逐行扫描完整时间线，找出**第一个偏离预期的事件**——这才是问题的关键起点，而非用户提供的最后一条 run。

"异常"不限于 `status=error`。以下都是异常信号，必须逐项检查：

| 异常信号 | 怎么识别 | 指向什么根因 |
|---|---|---|
| **工具调用序列缺少了应该有的工具** | 用户要求做 X（如创建定时任务、发消息、写记录），但该 turn 的工具调用序列里完全没有对应的工具 | 能力缺失：工具不可见/未注册/被过滤 |
| **运行时决策日志与预期不符** | `visible=N` 远小于 `manifest=M`，或 `lazy_tool_count=0`，或出现 `Skipping conditional tool` / `Hiding xxx` | 工具被 lazy discovery / 权限 / FG 隐藏 |
| **同类请求在不同 turn 的行为不一致** | turn 1 还能调某工具，turn 3 突然调不了；或同类请求今天和昨天的工具列表不同 | 配置变更 / FG 灰度 / 会话状态漂移 |
| **tool_count 突变** | 突然变多→打转/重试循环；突然变少→能力丢失或提前终止 | 执行错误或能力丢失 |
| **status=error 的 run** | 完整时间线上第一次出现非 status=3 的 run | 该 run 的报错即根因起点 |

**特别警惕**：第一次异常可能**不在 trace spans 里**，而在**运行时决策日志**里。trace 只记录"做了什么"，不记录"有哪些工具可选但没用"。如果一个工具在代码里存在、在 manifest 里有注册，但 LLM 从未调用它，问题极可能在于它对 LLM 不可见——这只能通过运行时决策日志发现。

#### 4.4 日志证据 + 代码双重验证

定位到第一次异常后，用**运行时决策日志** + **代码**双重验证根因。这是确认"为什么没做"（能力缺失类问题）的必要步骤。

**步骤 A：提取运行时决策日志（trace spans 里看不到的）**

以下日志揭示运行时的工具可见性/能力决策，是能力缺失类问题的关键证据：

```bash
# 从该 chatbot 的日志中提取工具可见性决策
LOG_FILE="<搜索输出文件>"

# lazy discovery：visible 是 LLM 实际可用工具数，manifest 是全部注册工具数
grep -oE "Lazy tool discovery enabled, visible=[0-9]+, manifest=[0-9]+" "$LOG_FILE"

# 工具过滤：N/M 差值 = 被条件过滤掉的工具数
grep -oE "Filtered tools: [0-9]+/[0-9]+ visible" "$LOG_FILE"

# LLM 是否主动用 tool_get 发现过隐藏工具（lazy_tool_count=0 说明从未尝试）
grep -oE "lazy_tool_count=[0-9]+, lazy_tool_names=\[[^]]*\]" "$LOG_FILE"

# 具体哪个工具被跳过/隐藏及原因
grep -E "Skipping (conditional|skill-scoped) tool|Hiding " "$LOG_FILE"
```

**步骤 B：与 trace 中实际调用的工具列表交叉比对**

从 trace（阶段 3）中提取 LLM 实际调用的工具名列表，与步骤 A 的日志对比：

- 如果某工具"**应该被用到**"但既不在 `visible` 列表里、也没被 `tool_get` 发现、也没在 trace 中出现 → **能力缺失类问题**，进入步骤 C。
- 如果工具在 `visible` 里且被调用了但结果不对 → **执行类问题**，跳到阶段 5.2 逐工具核对。

**步骤 C：结合代码确认"为什么能力被限制"**

根据步骤 A/B 定位的缺失工具，在代码中追溯其可见性决策链路：

| 代码位置 | 检查内容 |
|---|---|
| `agentContext/tool_builder.go` 的 `defaultPinnedToolKeys` | 该工具是否在 lazy_execute 模式的 pinned 白名单里？不在则只能通过 manifest + tool_get 间接发现 |
| `agentContext/tool_builder.go` 的 `GetTools` 过滤逻辑 | 该工具是否被条件过滤（conditionalConfig / OwnerAbilities / ActivationKey）排除？ |
| `tool_impl/*.go` 的工具注册逻辑 | 该工具的注册是否有前置条件（如 `hasEditPermissionQuiet`、FG 开关）未满足？ |
| TCC 配置（`tool_discovery_config` 等） | lazy_pinned_tool_keys / lazy_tool_short_descs 是否覆盖了该工具？short_desc 是否被截断丢失关键信息？ |

**步骤 D：区分根因类型，决定后续路径**

- **执行类问题**（工具被调了但结果不对：参数错配、谎报成功、写操作未生效）→ 进入**阶段 5.2** 逐工具核对。
- **能力/配置类问题**（工具压根没被调，因为不可见/未注册/被过滤/short_desc 截断）→ 直接进入**阶段 5.3**（对照代码验证根因），跳过逐工具核对——因为 trace 里根本没有该工具的 span 可核对。

---

### 阶段 5：分析 trace（标准方法论）

按以下顺序逐步分析，每一步都要有明确结论。

#### 5.1 验证最终输出是否符合用户预期

**目标**：判断这次 Agent 运行的结果是否正确。

方法：
1. 找到最后一个 `span_type=model` 的 span（即最终 LLM 输出）。
2. 解析其 output 的 `choices[0].message.content`（最终文本回复）和 `choices[0].message.tool_calls`（如果还在调工具说明没结束）。
3. 结合用户的原始诉求（从根 span `ReceiveMessage` 的 input 或 trigger 信息获取），判断输出是否满足预期。

```python
# 找最终输出
last_model = [s for s in spans if s.get('span_type') == 'model'][-1]
out = json.loads(last_model.get('output', '{}'))
msg = out.get('choices', [{}])[0].get('message', {})
final_content = msg.get('content', '')
final_tool_calls = msg.get('tool_calls', [])
```

判断维度：
- **内容完整性**：用户要求生成报告，是否生成了？是否漏了章节？
- **内容正确性**：数据是否准确？是否引用了不存在的数据？
- **行为合理性**：是否做了不该做的操作（如误删数据、创建无用文档）？
- **终止合理性**：是正常结束（有 content 无 tool_calls），还是异常中断？

**结论输出**：明确写出「符合预期」或「不符合预期」，如果不符，说明具体哪里不符。

#### 5.2 逐工具 / 子 Agent 核对 input/output 是否符合预期（核心环节）

**目标**：对 trace 中**每一个** `span_type=tool`（工具调用）和 `span_type=agent`（子 Agent 调用，如分析类子 agent）的 span，逐一拆解并核对其 input 和 output 是否符合预期，定位第一个出错的环节。这一步是分析的核心，**不能跳过任何一个工具或子 Agent，也不能只看 status 字段就下结论**。

**关键认知（重要）**：`status=success` 只代表"调用流程跑完了"，**不代表工具 / 子 Agent 真的完成了用户期望的语义动作**。真实 case 中最常见的坑就是：
- 工具 `status=success`、返回 `_meta.code=0`、甚至返回了 record_id / 文档 token，但**实际数据没落库 / 没生效 / 写到了错的地方**。
- 例如 `upsert_records` 返回 `"add 4 records successfully"` + 4 个 record_id，但用户在表里找不到任何新数据。这种问题只能通过"逐个核对 input（写什么）+ output（声称写了什么）+ 用户实际现象（有没有生效）"三端对齐才能发现。
- 子 Agent 同样会"谎报成功"：主 Agent 委派的任务与实际意图不符（该分析却只读取、该聚合却只列清单），或子 Agent 返回的结论 / 数据是编造的、与其自身读取的数据自相矛盾。这类问题同样只能通过核对子 Agent 的 input（被委派了什么任务）+ output（实际返回了什么）+ 用户现象三端对齐才能发现。

因此**即使最终输出看起来符合预期、即使所有 status 都是 success，也必须逐个核对工具 / 子 Agent 的 input/output**，因为 bug 往往藏在"谎报成功"或"参数 / 委派意图对不上"里。

**步骤 A：建立工具 / 子 Agent 调用序列（含配对与委派边界）**

按 `started_at` 排序，建立完整的调用序列，同时识别两类需要核对的 span：

```python
spans_sorted = sorted(spans, key=lambda x: int(x.get('started_at', 0)))

# 需要逐一核对的 span：工具调用 + 子 Agent 调用
check_spans = [s for s in spans_sorted if s.get('span_type') in ('tool', 'agent')]
# 每个 tool span 的 input 通常来自上一个 model span 的 tool_call.arguments，
# tool span 的 output 会回灌给下一个 model span。
# 每个 agent span（子 Agent）的 input 是主 Agent 委派的任务描述，
# output 是子 Agent 返回的最终结果（子 Agent 内部还会嵌套自己的 model/tool span，按 parent_id 归属）。
```

**子 Agent 委派边界**：`span_type=agent` 的 span 是一条独立的子运行。核对时既要看它**作为整体**的 input/output（主 Agent 委派了什么、子 Agent 最终返回了什么），也要在必要时下钻到子 Agent 内部的 model/tool span，验证子 Agent 返回结论的依据（是否真去读了数据、读到的数据是否支撑其结论、有没有编造）。子 Agent 的"假成功"往往体现为：返回了看似合理的结论，但结论与它自身子 trace 里读到的真实数据自相矛盾。

**步骤 B：对每个 tool / agent span 逐个执行核对清单**

对 trace 里**每一个** `span_type=tool` 和 `span_type=agent` 的 span，必须依次回答以下 6 个问题，缺一不可。每个问题都要在结论里给出"符合预期 / 不符合预期（附证据）"的判断：

| 核对项 | 怎么判断 | 不符合预期的典型表现 |
|---|---|---|
| **B1. 调用的对象对不对** | span_name 是否是该步骤该用的工具 / 子 Agent？LLM 是否选错（该读却写、该查却建、该用子 Agent 却手写 SQL、该用 A 子 Agent 却委派了 B）？ | 应该 `get_records` 读取却调了 `create_doc`；该用分析子 agent 却手写 SQL；该委派子 Agent 却直接调底层 tool |
| **B2. input 参数 / 委派意图对不对** | 工具：逐字段核对 `baseToken`/`tableId`/`recordId`/`field`/查询条件等是否正确指向目标对象？参数值是否来自前序步骤的真实结果而非幻觉？schema 列名是否与实际表字段完全匹配（顺序也要对）？子 Agent：核对主 Agent 给出的任务描述是否准确传达了用户意图（目标、范围、约束有没有被扭曲、遗漏或夹带私货）？ | recordId 传错或拼错；列名是幻觉（表里根本没有该字段）；baseToken 指向了错误的 base；子 Agent 被委派的任务与用户原意不一致（如要求"分析趋势"却委派成"列出数据"） |
| **B3. output 是否真符合语义** | **不能只看 status/code**。工具：核对 output 里的实际数据 / 返回对象是否符合该工具"声称完成的事情"——返回的数据是否为空？是否完整？返回的 id/token 是否真实存在？写操作是否真的写了预期的内容？子 Agent：核对返回的结论 / 数据是否真由其子 trace 中的真实读取支撑（下钻到子 Agent 内部 model/tool span 核对），有没有编造、有没有与自身读到的数据自相矛盾？ | `get_records` 返回全 None；`fetch-doc` 返回空；`upsert` 返回 record_id 但内容与 input 不一致；读操作返回 0 条却没报错；子 Agent 返回了表里根本没有的统计值 |
| **B4. input 与 output 是否自洽** | 工具：写操作 output 声称写入的数量 / 内容，是否与 input 里的 addRecords/updateRecords 真实一致？读操作返回字段是否覆盖了 input 请求的字段？子 Agent：output（返回的结论）与 input（被委派的任务）是否对应——任务要求 A，是否返回了 A 而不是 B 或部分？ | input 传 4 行 output 说 "add 3"；input 要 A/B/C 列 output 只返回了 A 列；子 Agent 被要求汇总 5 个维度却只返回了 2 个 |
| **B5. 该输出与用户实际现象是否一致** | 把工具 / 子 Agent 的 output（声称做了什么）和用户反馈的现象（实际看到什么）放在一起对齐。这是发现"假成功"的关键。 | 工具说"4 条写入成功"，但用户反馈表里一条都没有；子 Agent 说"已生成趋势分析"，但用户反馈最终回复里没有该分析 → 三端不一致，锁定该环节 |
| **B6. 问题环节的 input/output 是否完整体现（输出契约）** | **本项只针对被判定为"不符合预期"（即问题环节）的 span。** 这类 span 的**完整 input 和完整 output 原文必须在最终给用户的分析输出中完整体现**，不得截断、不得只用摘要、不得只贴 _meta.code。完整体现是让用户（和后续 review）能独立复核判断的前提。符合预期的 span 用摘要即可。 | 问题环节只在报告里写"output 显示成功，疑似假成功"却不附 output 原文，无法复核 → 不合格 |

**核对脚本示例**（逐个 tool / agent span 打印 input/output，便于核对）：

```python
import json

# 先标记哪些 span 是问题环节（不符合预期）。分析过程中维护这个集合。
# 这里 problem_span_ids 是示意，实际由 B1~B5 判定后填入。
problem_span_ids = set()

for s in spans_sorted:
    if s.get('span_type') not in ('tool', 'agent'):
        continue
    is_problem = s.get('span_id') in problem_span_ids
    label = '子AGENT' if s.get('span_type') == 'agent' else 'TOOL'
    print("=" * 70)
    print(f"{label}: {s.get('span_name')} | span_id={s.get('span_id')} | "
          f"duration={s.get('duration')}ms | status={s.get('status')} | "
          f"{'⚠️ 问题环节' if is_problem else 'ok'}")
    inp = s.get('input', '') or ''
    outp = s.get('output', '') or ''

    if is_problem:
        # 问题环节：必须完整体现 input/output 全文，禁止截断
        print(f"--- INPUT (len {len(inp)}) 完整 ---")
        print(inp)
        print(f"--- OUTPUT (len {len(outp)}) 完整 ---")
        print(outp)
        # 对结构化 output，二次解析核对关键字段（也完整打印）
        try:
            parsed = json.loads(outp)
            print(f"--- PARSED _meta: {parsed.get('_meta')} ---")
            print(f"--- PARSED structuredContent: "
                  f"{json.dumps(parsed.get('structuredContent'), ensure_ascii=False)} ---")
        except Exception:
            pass
        # 子 Agent 还需提示下钻：列出其内部子 span，核对结论依据
        if s.get('span_type') == 'agent':
            child_spans = [c for c in spans_sorted
                           if c.get('parent_id') == s.get('span_id')]
            print(f"--- 子 Agent 内部 span（{len(child_spans)} 个），需下钻核对结论依据 ---")
            for c in child_spans:
                print(f"  [{c.get('span_type')}] {c.get('span_name')} "
                      f"status={c.get('status')} out_len={len(c.get('output','') or '')}")
    else:
        # 符合预期的环节：摘要即可，避免上下文膨胀
        print(f"--- INPUT 摘要 (len {len(inp)}) ---")
        print(inp[:2000])
        print(f"--- OUTPUT 摘要 (len {len(outp)}) ---")
        print(outp[:2000])
        try:
            parsed = json.loads(outp)
            print(f"--- PARSED _meta: {parsed.get('_meta')} ---")
        except Exception:
            pass
```

> 脚本逻辑：问题环节（`is_problem=True`）打印完整 input/output 不截断，并解析结构化字段；符合预期的环节用 `[:2000]` 摘要即可。最终的文字分析报告里同样遵循这条规则——**问题环节完整体现，其余摘要**。

**步骤 C：跨工具交叉验证（参数来源追溯）**

很多 bug 出在"工具链之间的参数传递"。对每个写操作 / 关键读操作，追溯其关键参数的**来源**：

| 追溯维度 | 怎么做 | 典型问题 |
|---|---|---|
| **id 类参数来源** | 写操作的 `tableId`/`recordId` 是否来自前面 `get_base_schema`/`get_records` 的真实返回？还是 LLM 自己编的？ | LLM 编了一个看起来合法但实际不存在的 tableId |
| **数据来源** | 写入的数据值是否来自前面的真实读取结果？ | LLM 把分析结果里的行写错了列 / 漏了字段 |
| **schema 一致性** | 写操作的 schema 列名 + 顺序，是否与 `get_base_schema` 返回的真实字段完全一致？ | 列名是近似（"记录日期" vs "超期记录日期"）导致错列写入 |

**步骤 D：定位第一个偏离预期的环节**

完成 B、C 后，找出**第一个**出现"不符合预期"的工具环节。注意：
- 只列出**能 100% 确定**的问题环节，附上证据（具体的 span_name、span_id、input/output 原文片段）。
- 不确定的地方明确标注「需进一步验证」，不要猜测。
- 如果是多个环节连环导致，理清因果链（A 导致 B，B 导致 C）。
- **特别警惕"工具谎报成功"**：如果工具 output 声称成功，但与用户现象（5.1 / 用户原始反馈）不一致，这就是问题环节，根因往往在工具实现或下游服务，而非本仓库代码。

**步骤 E：定义问题环节的特征**

对每个定位到的问题环节，明确写出：
- **环节位置**：第几个 LLM step / 哪个 tool span（span_name + span_id）。
- **预期行为**：这个环节本来应该做什么。
- **实际行为**：trace 里实际做了什么（input/output 原文）。
- **证据**：input/output 里的具体内容（引用原文）+ 与用户现象的对齐结果。
- **根因假设**：为什么会出现这个偏差（区分本仓库代码 vs 下游服务 vs 数据 vs 环境）。

#### 5.3 对照代码验证根因

**目标**：确认 trace 里的问题是否由代码逻辑导致，而非偶发/环境因素。

方法：
1. 根据 5.2 定位的问题环节，确定涉及的功能模块（如 tool 调用逻辑、prompt 构造、错误处理等）。
2. 在代码库中找到对应实现（用 Grep/Glob 搜索 span_name、tool_name、相关函数名）。
3. 对照 trace 的实际表现，验证代码逻辑是否与 trace 一致：
   - 如果**一致**：说明是代码逻辑的问题（设计缺陷或 bug），进入 5.4。
   - 如果**不一致**：可能是环境/数据/版本差异，需进一步排查（比如查 git log 看相关代码是否近期改过、是否 canary vs prod 版本差异）。

#### 5.4 输出分析报告和修复计划

**分析报告**包含：

1. **问题概述**：一句话描述问题。
2. **trace 概要**：run_log_id、trace_id、品牌/用户、env、duration、step_count。
3. **最终输出评估**：是否符合预期，具体哪里不符。
4. **问题环节定位**：每个问题环节的预期行为、实际行为、证据。**证据必须完整体现该环节的 input 和 output 原文**（工具与子 Agent 同样要求），不得截断或仅用 `_meta.code` 摘要代替，以便用户独立复核。
5. **根因分析**：代码层面的原因（附文件路径和行号）。
6. **修复方案**：具体的代码改动建议。

**修复计划**包含：

1. **改动范围**：涉及哪些文件。
2. **改动内容**：每个文件具体改什么，为什么这么改。
3. **风险评估**：改动可能影响的其它功能。
4. **验证方案**：如何验证修复有效（复现 case、跑 UT、手动触发）。

**review 后与用户确认**：把分析报告和修复计划完整呈现给用户，明确询问「是否需要修复」。在用户确认前，不修改任何代码。

#### 5.5 修复执行（仅当用户确认后）

用户确认修复后：

1. 从当前分支新建 feature 分支。
2. 按修复计划修改代码。
3. 运行相关 UT 验证（优先用 run-ut skill 远程执行）。
4. 提交 MR（用 chatbot-submit-mr skill，遵循仓库 MR 规范）。

---

## 排查目标速查

根据不同排查目标，聚焦不同维度（均需完成 5.2 逐工具 / 子 Agent input/output 核对；问题环节的 input/output 必须在最终输出中完整体现）：

| 排查目标 | 分析重点（5.2 步骤 B 的侧重） |
|---|---|
| Agent 打转/超时 | tool span 序列，识别重复调用同一工具；model duration 总和；是否有无意义的 tool_get 循环 |
| 结果内容缺失（如漏章节、数据没写入） | **逐个核对写操作的 input（写了什么）与 output（声称写了什么），并与用户实际现象三端对齐**；警惕工具 status=success 但实际未生效（假成功）；对比好/坏 case 的 tool 调用分叉点 |
| 状态异常（status≠3） | 找 status=error 的 span，看 input/output 里的报错；看 agent span 的最终状态 |
| 输出不稳定（同输入不同输出） | 好坏 case 并排对比，定位第一个分叉的 model/tool span；检查是否有 tool_get error 导致路径偏移 |
| 误操作（如创建无用文档） | 逐个检查写操作 span（create-doc/upsert_records 等）的 input/output，看 LLM 的 reasoning 是否合理、写入参数对不对 |
| 能力缺失 / 工具不可见（如触发器没创建、配置没生效、Agent 说做了但实际没做） | **优先走阶段 4 完整时间线方法**：检查 visible vs manifest 差值、lazy_tool_count、运行时决策日志；确认"应该有的工具"是否真的在 LLM 可见列表里；结合代码确认工具注册 / pin / FG / 权限链路。如果确认能力可见且工具被调了但结果不对，再走 5.2 逐工具核对 |

---

## 输出格式

每次分析输出包含：

1. **traceID 映射表**：run_log_id → trace_id（多个时全列出，附时间）。
2. **run 元信息**：status / duration / step_count / env / trigger_time。
3. **解密状态**：确认 input/output 是否可读（明文 JSON）。
4. **span 调用序列表**：span_type | span_name | duration | status，按时间排序。
5. **完整时间线还原**（仅当执行了阶段 4 时）：该 chatbot 在问题时间窗内的全部 run/turn 序列表（时间 | turn | trace_id | status | tool_count | 关键工具 | 异常标记），以及第一次异常的定位和证据（运行时决策日志原文 + 代码路径）。
6. **最终输出评估**：是否符合用户预期。
7. **逐工具 / 子 Agent input/output 核对表**（核心）：对每个 tool span 和 agent span 逐个列出 span_name、input、output、以及 B1~B6 每一项的"符合预期 / 不符合预期（证据）"判断；尤其要呈现"工具 / 子 Agent output 声称做了什么" vs "用户实际现象"的对齐结果。**问题环节（任何一项被判为不符合预期的 span）的完整 input 和完整 output 原文必须在该环节下完整体现，不得截断、不得只用摘要或 `_meta.code` 代替**；符合预期的环节用摘要即可。
8. **问题环节定位**（仅当有环节不符预期）：每个环节的预期/实际/证据/根因，并明确区分根因归属（本仓库代码 / 下游服务 / 数据 / 环境）。**证据必须包含该环节的完整 input 和完整 output 原文**（与第 7 项呼应，二处都不得截断），让用户能独立复核判断。
9. **分析报告和修复计划**（仅当定位到代码根因）。

---

## 注意事项

- fornax trace 数据有保留期（约 35 天，`logic_delete_date` 字段可见），超期的 trace 拉不到。
- `--workspace-id` 必须正确，否则报权限错误。chatbot 团队固定用 `7590084861042927618`。
- trace 文件可能很大（含完整 LLM input/output，几 MB），解析时优先聚合统计，避免把全文打印到上下文。
- 不要把 trace 里的真实用户数据（query、业务数据）写入仓库或外发；分析结论可脱敏后记录。
- BPM 工单创建后，approval 节点会自动 finished，但必须 @ 板栗才能推进到 done；板栗没响应就重发。
- 一次触发可能产生多个 run（fan-out），每个 run 有独立 traceID，需分别解密和分析。
