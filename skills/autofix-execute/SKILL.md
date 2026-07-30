# autofix 自动改码与提 MR 执行方法论

本文档会被完整注入 daemon 的 zcode 执行会话。审批已通过，你的任务是**严格按修改计划完成代码修改并提交合并到 develop 的 MR**。你工作在 bitable-chatbot 仓库根目录，具备文件读写和 shell 能力。

## 输入约定（由 daemon 在 prompt 中提供）

- 复核后的根因（ROOT_CAUSE）与修改计划（FIX_PLAN）。
- 该 thread 内**所有讨论内容**（discussion_context）：包括报案人、刘昕明和其他同事对「该怎么改」的讨论。**你必须遵循讨论结果**，讨论结果优先于计划本身的细节。
- trace_id 与 run_log_id（供你在 commit message 里引用）。
- 工作目录即 bitable-chatbot 仓库根。

## 工作步骤（按顺序，不要跳步）

### 步骤 1：确保从 develop 干净出发

```bash
cd <仓库根>
git status --short --branch          # 先看是否有未提交改动
git switch develop                   # 切到 develop
git pull --ff-only origin develop 2>/dev/null || true   # 拉最新（失败不阻断）
git switch -c fix-autofix-<trace_id短>   # 短横线命名，不带 slash
```

- 若工作区有他人无关改动：**不要回滚、不要一起提交**，只在你的新分支上改本次任务文件。
- 分支名用 `fix-autofix-<trace前8位>`，简短可识别。

### 步骤 2：按修改计划（+ 讨论结果）改代码

- 严格按 FIX_PLAN 改，**遵循 discussion_context 里讨论达成的结论**（例如同事提出换个改法、缩小范围、换文件，以讨论为准）。
- 改动尽量小、局部、可回滚。不要顺手重构无关代码、不要改无关格式。
- 只读确认的文件不要改；只改计划/讨论确定的文件。
- 读代码时只看主源码 `application/chatbot/...`，忽略 `.claude/worktrees/...` 副本。

### 步骤 3：验证

```bash
gofmt -w <你改过的 .go 文件>
git diff --check
```

- Go 文件必须 gofmt。
- 不要在本地跑全量 `go test ./...`（AGENTS.md 规定本地不跑单测，会非常耗时并吃满 CPU）。如果改动影响逻辑，说明「单测建议走 run-ut 远程」，但**不要**你自己在本地执行全量单测。
- 可以对改动的单个包跑非常局部的验证（如 `go build ./application/chatbot/tool_impl/...`）确认编译通过，但不要扩大范围。

### 步骤 4：数据安全自评（必做，决定能否继续）

针对你的改动，自评是否涉及：存储、缓存、MQ、TOS、MySQL、Redis、Abase、日志、埋点、LLM prompt/response、工具结果、用户输入、文件、token、权限、客户数据处理。

- 若涉及且你判断有 P0/P1 风险（如客户数据明文存储、敏感日志、token 泄露、生产加密 fail-open 等）：**立即停止，不要 commit、不要提 MR**。在输出里写 `EXEC_STATUS: blocked_security` 并说明风险。
- 若不涉及或无 P0/P1：在 MR 描述里写「数据安全 review：不适用，原因是...」或给出结论。

### 步骤 5：commit

```bash
git add <你改过的具体文件路径>   # 不要用 git add .
git diff --cached --stat
git diff --cached --check
git commit -m "<中文提交信息>"
```

- 提交信息中文，说清修了什么 badcase（可带 trace_id）。

### 步骤 6：push

```bash
git push -u origin <你的分支名>
```

- 网络失败按权限申请提权重试。保留 push 输出里可能的 MR 创建链接作为兜底。

### 步骤 7：创建合并到 develop 的 MR

```bash
bytedcli --json codebase mr create -R "ee/bitable-chatbot" \
  --head <你的分支名> --base develop \
  --title "<中文标题>" --body "<真实多行 Markdown>"
```

**`--body` 必须是真实多行 Markdown，禁止用字面量 `\n` 拼接。** MR 描述三段式：

```
变更：<改了什么，对应哪个 badcase，trace_id>
验证：<跑了 gofmt / git diff --check，单测建议走 run-ut 远程等>
数据安全 review：<结论或不适用原因>
```

- `--body` 的 shell quoting 必须正确，正文含特殊字符要转义。**不要**在同条命令前加 `body="$(<file)"` 这类命令替换（会破坏 bytedcli 前缀授权匹配、再次触发审批）。
- 鉴权失败（`AUTH_REQUIRED`）走：
  ```bash
  bytedcli --json auth login --begin
  bytedcli --json auth login --complete <challenge_token>
  ```
- 创建后**必须**用 `bytedcli --json codebase mr get -R "ee/bitable-chatbot" --number <MR_NUMBER>` 回读描述，确认没有字面量 `\n`、转义引号或 Markdown 乱码。如有乱码，用 `mr update` 修正。

### 步骤 8：输出结果契约（daemon 按此解析，发回群里）

成功时最终回答**必须**包含：

```
EXEC_STATUS: success
MR_NUMBER: <数字>
MR_URL: <可点击的 MR 链接>
BRANCH: <分支名>
COMMIT: <commit hash 短>
```

失败时：

```
EXEC_STATUS: failed
FAIL_REASON: <一句话失败原因，例如 push 鉴权失败 / 编译错误 / data-security 拦截>
```

被安全自评拦截时：

```
EXEC_STATUS: blocked_security
FAIL_REASON: <P0/P1 风险描述>
```

## 硬性约束

- **目标分支只能是 develop**，MR base 永远是 develop。
- 绝不 `git push --force`、绝不 `git rebase` 已推送分支、绝不删他人分支。
- 不要修改 `.git/`、不要碰 CI 配置、不要改 launchd plist、不要改本 daemon 自身。
- 改动若超出 FIX_PLAN 范围（例如发现需要顺带改第 4 个文件），说明判定复杂度时低估了 → 停止并输出 `EXEC_STATUS: failed` + `FAIL_REASON: 复杂度超预期（需改 N 个文件），转人工`，不要擅自扩大改动。
- 所有文本（commit message、MR 描述、你的输出）中文。不要把 trace 用户业务数据原文、token、URL 写进 commit/MR/输出。
