# 交接：badcase daemon 回复发送失败排查

> **状态：已于 2026-07-12 修复。** `lark-cli 1.0.68` 的 `--markdown` 参数接收
> Markdown 文本，不会把 `@file` 展开为文件内容。旧实现实际向飞书发送了字面量
> `@/Users/.../reply_xxx.md`，从而触发 `99992402`。现已改为
> `--markdown "$text"`，并通过约 10KB 历史失败结论的 dry-run 验证请求体。
> daemon 已重启，`bytedcli` 依赖也已恢复。
>
> **2026-07-13 补充修复：** 飞书回复接口的 `uuid` 最大 50 字符，旧的
> `badcase-auto-<message_id>-<timestamp>` 实际为 59 字符，仍会触发 `99992402`。
> 现改为 39 字符的 `bc-<UUID>`；同时只有回复成功后才写入 processed，回复失败
> 保留未处理状态供重试，dry-run 不再污染 processed 账本。
>
> **2026-07-13 现场重放补充修复：** ZCode 单次分析超时由 600 秒提高到
> 1200 秒，限流、连接超时、`rc=124` 等瞬态错误按 30/60 秒退避重试；飞书
> bot 回复和板栗催审也增加网络重试，并在回复重试中复用同一幂等 key。日志 ID
> 抽取会排除显式 `uid/user_id`，合并转发正文改为分页查找；历史合并转发正文已
> 无法由 lark-cli 展开时，可使用 `--once <message_id> --log-id <已核验ID>` 重放。
> 数据安全同步收敛：不再记录用户消息正文片段或模型完整 stderr，降级评论不再
> 暴露本机绝对路径。
>
> **2026-07-13 长分析增强：** 单条 case 总处理预算调整为 3600 秒。先用最多
> 600 秒生成不超过 800 字的阶段性调查，回复后继续深度反证；深度单轮最多
> 2400 秒，剩余预算内最多 8 轮积极重试，退避最大 120 秒。长会话每 15 分钟
> 发送一次安全心跳；开始、阶段结论、心跳和超时状态均使用稳定幂等 key 且不写
> processed，只有最终结论成功回复后才闭环。所有正式回复发送前先 dry-run，阶段
> 结论群内展示最多 3000 字符，trace/模型临时文件通过 `umask 077` 限制为当前用户。
>
> **2026-07-13 完整证据按需拉取：** 旧实现只向模型传 span 名称/状态/长度摘要，
> 却要求模型在证据不足时提示“查看完整 trace_details.json”，导致模型永远无法拿到
> 文件。现改为：第一轮传全部 span 的 ID/调用树/预览并要求返回候选 span_id；daemon
> 与本地 trace 求交后生成包含完整 input/output 的私有证据包，通过 ZCode 0.15.2 的
> `--attach` 提供给深度轮。模型若返回 `ADDITIONAL_SPAN_IDS`，后续轮继续扩充证据；
> 最后一轮直接 attach 完整 trace_details.json 兜底。控制行不会发到群里，问题 span
> 的 input/output 不在证据包内截断。

## 你需要做什么

修掉 badcase daemon 最后一个未解决的 bug：**LLM 分析结论发送到飞书 thread 时，lark-cli 报 `field validation failed (99992402)`，回复发不出去**。前面的链路（抽 ID、查 trace、解密、LLM 分析）都已跑通，只差发送这一步。

## 一句话症状

daemon 的 `reply_thread()` 调 `lark-cli im +messages-reply --markdown "@$md_file" ...` **总是返回 rc=1 + 错误 code 99992402 (field validation failed)**。但**用完全相同的 md 文件手动跑同样的 lark-cli 命令却能成功**。问题只在 daemon 脚本上下文里复现。

## 关键事实（已验证，非推测）

1. **手动发能成功**：把 daemon 生成的 md 文件（含 24 个双引号、表格、代码块，9866 字节）手动跑 `lark-cli im +messages-reply --markdown "@<file>"` → 成功（返回 ok:true）。
2. **daemon 内发失败**：同一个文件、同一条命令，在 daemon 脚本的 `reply_thread()` 里调 → rc=1, code 99992402。
3. **set -euo 环境模拟也成功**：用 `bash -c 'set -euo pipefail; ...同样的调用...'` 复现 → 成功。所以不是 set -euo 的问题。
4. **短内容能发**：500 字以内的简单 markdown，daemon 和手动都成功。失败的是 LLM 结论（~10KB，含双引号/表格/中文）。
5. **不是幂等 key 问题**（已加时间戳后缀修过）。**不是双引号内插问题**（已改用 `printf -v` 拼接，双引号正确保留）。**不是 @file 问题**（@file 手动测成功）。
6. **lark-cli 版本 1.0.65**（有 1.0.68 可更新，但未确认是否相关）。

## 最可疑的方向（还没排除）

- **lark-cli `--markdown` 的 @file 解析在 daemon 进程环境（launchd 或后台 timeout 包装）下行为不同**。daemon 是被 `timeout 600 ./scripts/...sh --once ...` 或 launchd 启动的，可能有某个环境变量（如 TERM、CWD、shell 初始化）影响 lark-cli 对 @file 的读取。
- **md 文件内容有 BOM 或尾部字节**：`printf '%s'` 写的文件 vs 手动 `cat` 的文件，末尾可能有差异。需要 hexdump 对比 daemon 写的文件和手动 cat 的文件。
- **idempotency-key 与飞书的交互**：虽然加了时间戳后缀，但飞书可能对同一 message_id 的 reply 有额外频率/内容限制。

## 文件位置

```
/Users/xinming/MyProject/working-workspace/badcase-daemon/
├── scripts/badcase_event_monitor.sh      # daemon 主体（532 行）
├── scripts/find-runlog-log.sh            # run_log_id → trace_id
├── skills/fornax-trace-fetch/*.mjs        # trace 抓取+解密（4 个脚本）
├── skills/trace-decrypt-analyze/SKILL.md  # 注入 LLM 的分析方法论
├── badcase_event_monitor.plist            # launchd 配置
└── HANDOFF-debug-reply-failure.md         # 本文档
```

## 关键代码位置（badcase_event_monitor.sh）

- **第 294-321 行 `reply_thread()`**：发送逻辑。当前用 `printf '%s' "$text" > "$md_file"` 写文件，然后 `lark-cli ... --markdown "@$md_file" ...`。发送后 md 文件**暂未删除**（调试用，第 314 行 log 保留路径）。
- **第 452-459 行**：构造 reply 内容。用 `printf -v reply '...' "$first_log_id" "$first_trace" "$conclusion"` 拼接（LLM 结论在 `$conclusion` 里，可能含双引号/表格/中文）。
- **第 115-148 行 `run_zcode_session()`**：调 LLM 生成结论，返回纯文本。

## 如何复现

```bash
WS=/Users/xinming/MyProject/working-workspace/badcase-daemon

# 1. 确认有一条已处理的 case（trace 已解密）
#    刘家宁的 case：message_id=om_x100b6a3daa5cacb8b283ff9583aeee9
#    run_log_id=7660770405636246763, trace=30e2fe589228a83d3a3bfb9a357d28a4

# 2. 清掉它的 processed 记录，用 --once 补处理
grep -v "om_x100b6a3daa5cacb8b283ff9583aeee9" ~/.badcase_event_state/processed_events.txt > /tmp/pe.tmp && mv /tmp/pe.tmp ~/.badcase_event_state/processed_events.txt
rm -f ~/.badcase_event_state/badcase_event_monitor.pid

# 3. 跑（会走完 抽ID→trace→可能解密→分析→发送失败）
timeout 600 "$WS/scripts/badcase_event_monitor.sh" --once "om_x100b6a3daa5cacb8b283ff9583aeee9"

# 4. 失败后，daemon 保留的 md 文件在这里：
ls -t ~/.badcase_event_state/reply_*.md | head -1
# 用它手动发（应该成功）：
MDFILE=$(ls -t ~/.badcase_event_state/reply_*.md | head -1)
lark-cli im +messages-reply --message-id "om_x100b6a3daa5cacb8b283ff9583aeee9" --reply-in-thread --as bot \
  --markdown "@$MDFILE" --idempotency-key "manual-$(date +%s)"

# 5. 对比：daemon 写的文件 vs 手动写的文件（hexdump 看末尾差异）
xxd "$MDFILE" | tail -3
```

## 已做过的修复尝试（都未解决发送问题）

1. ~~幂等 key 固定导致旧结论被去重~~ → 改加时间戳后缀（修了去重问题，但发送仍失败）
2. ~~bash 双引号内插 `$conclusion` 遇双引号~~ → 改 `printf -v`（正确了，但发送仍失败）
3. ~~`--markdown "$text"` 命令行参数太长~~ → 改 `--markdown "@$md_file"`（手动成功，daemon 仍失败）
4. ~~`runJson` 拼接 stdout+stderr 导致 wait_banli 崩溃~~ → 改只解析 stdout + try/catch 容错（这个修好了 wait_banli 的问题）

## daemon 整体架构（供了解全貌）

```
launchd (KeepAlive) → badcase_event_monitor.sh
  └─ lark-cli event consume im.message.receive_v1 --as bot  # WebSocket 长连接，收 badcase 群所有新消息
       └─ FIFO → while read → process_event(evt)
            ├─ 抽日志ID（正则，含 merge_forward 占位符回退 + StepID 纠错）
            ├─ find-runlog-log.sh → trace_id
            ├─ fetch_fornax_trace.mjs（用 fornax-cli 二进制，非 bytedcli）→ 抓 trace
            ├─ 未解密 → apply_trace_decrypt_bpm.mjs + send_banli + wait_banli_done.mjs → 重抓
            ├─ run_zcode_session() → LLM 分析（注入 SKILL.md 方法论）
            └─ reply_thread() → lark-cli --markdown "@file" 回复 thread  ← 卡在这里
```

## 其他已知小问题（不影响当前排查，但记录）

- bash 3.2（macOS 自带）对「变量名紧跟中文字符」会报 unbound variable。脚本里所有 `$var中文` 都已改成 `${var}中文`，但新加代码要注意。
- `reply_thread` 当前第 314 行有调试 log（保留 md 文件路径），修完后应恢复 `rm -f "$md_file"`。
- daemon 是**串行处理**（一条 case 解密等待会阻塞后续消息），这是架构限制，非本次排查范围。

## 期望产出

让 `reply_thread()` 能稳定发送 LLM 结论到飞书 thread。验证方式：`--once` 跑完一条 case，`已回复 om_xxx → om_yyy` 出现在日志里，且飞书群里能看到完整的分析结论回复。
