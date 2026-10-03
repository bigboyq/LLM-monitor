# Agy Local Usage — Provider Merge Spec

agy 是 Antigravity 的 CLI 分支（二进制 `agy`，数据根 `~/.gemini/antigravity-cli/`）。
它不是菜单栏 provider，也不是 DSH / OpenCode 那种跨 provider 共享账本：其本地
transcript 用量是 Google Antigravity（`QuotaProviderID.antigravity`）quota 卡的一个
native 贡献源，与 `ClientID.antigravity`（IDE RPC 账本）同卡并列。诊断入口在
Settings → Clients 的独立 Agy tab（由 `ClientDescriptor.all` 自动出现）。

## Data source

| Item | Value |
|---|---|
| Session root | `~/.gemini/antigravity-cli/brain/`（下一级目录名即 session uuid） |
| Transcript | `<session>/.system_generated/logs/transcript.jsonl` + `chunks/transcript/*.jsonl` |
| Model sidecar | `~/.gemini/antigravity-cli/log/cli-YYYYMMDD_HHMMSS.log`（文件名本地时区；正文 go log 行 `Resolving model <name>` 取每文件最后一条） |
| Format | 明文 JSONL，无压缩；行带 `source` / `status` / `created_at`（ISO8601 UTC）/ `step_index` |
| 计量行 | 只有 `source == "MODEL"` 且 `status == "DONE"` 且带 token 字段的行；token 三键 `input_tokens` / `cache_read_tokens` / `output_tokens` 实测成组出现（要么都有要么都没有） |
| Cache | `~/Library/Application Support/LLM-monitor/token-monitor/agy.json`（fingerprint + versioned JSON） |
| Daily window | Seven local calendar days, including today |

读取集合（本机 8 个 session 实测核实的行重叠关系）：

| 路径 | 是否读取 | 原因 |
|---|---|---|
| `transcript.jsonl` | 读 | 主文件 |
| `chunks/transcript/*.jsonl` | 读（合并） | 轮转后旧行只存在于分块，只读主文件会漏 |
| `transcript_full.jsonl` | 不读 | 行集合与主文件完全相等（别名），读了只会重复 |
| `chunks/transcript_full/` | 不读 | 落后主文件（实测 21 行主文件只含 18 行），读它会漏行 |

主文件与分块在轮转期会同时包含同一行：合并读取后跨**本轮全部文件**用
`(sessionID, created_at epoch, step_index ?? -1)` 去重兜底，不重不漏。去重只跳过
该行的聚合，外层解析循环照常推进，重复行不可能卡住扫描。

行口径：

- 非 DONE 行（`RUNNING` 等中间态）整行跳过；
- DONE 但完全没有 token 字段的行是未计量响应（实测 104 条 DONE 中 68 条），
  整行跳过，不产出样本也不计轮次；
- `truncated_fields` 只截 content，不影响 token 计数。

## Accounting contract

统一估算契约见 [`spec/accounting.md`](../accounting.md)。计数口径与 Antigravity RPC
一致（`TokenAccountingCatalog.antigravity`）：`input_tokens` 是未缓存输入（uncached），
`cache_read_tokens` 是独立缓存读桶，`output_tokens` 含思考。账本没有原生 reasoning
计数：`thinking` 非空时按字符占比（`thinking` chars vs `content` + `tool_calls`
序列化 chars；工具参数计入可见侧，与 DSH 的 `tool-call.arguments` 同口径）用共享的
`ReasoningCharSplit.split(outputTokens:reasoningChars:visibleChars:)` 守恒拆分，
`reasoning + output == 原始 output_tokens` 恒成立；无 `thinking` 时 raw output 全放
`Output`、`Reason = 0`。分摊发生在逐行样本层，日聚合是拆分结果的直加（行级粒度）。

sample 层遵守 `LocalTokenUsageSample` 历史语义：`inputTokens` 存 cache-inclusive
总输入（`input + cacheRead`），`cachedInputTokens` 存独立缓存读；进入价格估算时由
`TokenUsageBuckets.fromSample` 还原拆分。agy transcript 没有 cacheWrite 字段，
统一估算层自然也不涉及。

## Provider mapping

| Card | 归属模式 |
|---|---|
| Google Antigravity（`QuotaProviderID.antigravity`） | native：帧自带 `quotaProviderID`，与 `ClientID.antigravity` 同款 |

agy 是单一 quota 归属，不需要 DSH / OpenCode 式的 provider 路由键，也**不进**
`config.json` 的 `clientBindings[]`（`defaultBindings` 没有它的条目）——provider
启用即扫描、即并入卡片（`LocalUsageOrchestration.ActiveSources.agy` 直接取
`enabledKinds.contains(.antigravity)`）。模型价格零改动：`gemini-3.1-pro-high` 由
contains 命中 `ModelPricing.json` 现有 `gemini-3.1-pro` 条目，其余 Gemini 模型同样
复用 Antigravity 价目（见 [`antigravity.md`](antigravity.md) 的 Model Pricing）。

## 模型名 join

transcript 行不带模型名。scanner 用 `log/cli-*.log` 构建时间线后 join：

- 文件名 `cli-YYYYMMDD_HHMMSS` 按**本地时区**解析成该次运行的开始时间
  （正文是 go log 本地墙钟行，与行内 UTC `created_at` 两个时区语义在绝对时刻
  比较处汇合）；
- 每文件取**最后一条** `Resolving model <name>`（同一次运行内模型可能被多次解析）；
- 行的 `created_at`（UTC）取「开始时间 ≤ created_at 的最近一个 log」的模型名；
- created_at 早于全部 log 时回退最早已知模型（时间线上最近一次已知的模型配置）；
- 时间线在**每次扫描的指纹短路判定之前**解析：log-only 变化（transcript 指纹
  不变）靠时间线签名使短路失效并触发全量重聚合，模型名刷新不会被旧缓存吞掉；
- 时间线为空（目录缺失 / 枚举失败 / 全部文件不可解析）时模型名保持 `nil`，行仍
  计入用量，投影层归入 `ProviderHarnessProjection.unknownModelName`；
- 单 log 文件 16 MiB 读取上限；超限 / 文件名不可解析 / 正文无模型行的文件只跳过
  自身，不阻断时间线构建，更不阻断扫描（join 失败与用量聚合完全解耦）。

## Rounds and turns

- `rounds`: 一条计量 MODEL 行（DONE + 有 token 字段）。
- `turns`: distinct 裸 promptID per local day。promptID 格式 `session:step:N`
  （`step_index` 缺失时用 `created_at` epoch 兜底）；同一 promptID 的多条样本是
  同一次用户请求的多轮模型调用，日聚合的 turns 只记一次，与
  `LocalTokenUsageSample` 的 prompts 口径一致。

Recent samples 的 promptID 以裸格式落盘；`agy:` 命名空间由帧构造
（`UsageSampleNamespace.agy`）统一施加——与 DSH / OpenCode / antigravity native
同一规则，旧缓存里的裸 ID 与新写入的裸 ID 得到相同终态 ID，不需要缓存迁移。

## Scanner behavior

- 预算（`AgyLocalUsageScanLimits.production`，形态与 DSH 同款）：1,024 个
  transcript 文件、1 GiB 原始字节、8 MiB 单行、65,536 条 recent samples，另加
  单个 cli log 16 MiB。文件数 / 字节触顶按 mtime 最新优先截断（path 升序稳定
  tie-break），最旧 session 被挤出 7 天统计，`isTruncated` 置位，日志记录
  selected / available 计数。
- 解析流式进行：字节级 `"source":"MODEL"` 一级过滤（纯 ASCII marker，不会切进
  UTF-8 多字节序列）+ 行缓冲上限 8 MiB，峰值内存与文件大小无关；取消按读取
  分块检查，且取消必须抛 `CancellationError`——静默半结果会被写进指纹缓存，
  尾部数据永久缺失。单文件行数超过预算（`maxSessionFiles × 10_000` 行）同样
  必须抛错（`AgyLineBudgetExceededError`）：超预算文件按失败隔离（partial），
  不入指纹，下一轮重试，而不是静默半结果入库。
- 指纹缓存 `AgyCacheIndex` v2（per-file mtime/size 指纹 + **cli log 时间线签名**
  + 全量快照 + 日历签名）：指纹含 transcript 文件与时间线签名两部分，任一变化
  都触发重聚合（log-only 变化由此刷新模型名）；全部未变只做 midnight rebase
  （按当前日历重算 7 天窗口并重剪样本，业务字段原样保留）；日历签名变更强制
  重建日桶；显式 hard-full 才绕过缓存。时间线为空签名记 nil，空 log 目录不破坏
  短路；v1 → v2 无迁移，旧缓存一次性失效重建。
- **partial 永不入盘**不变量：stat 失败或聚合中有坏文件（含行数熔断）时保留
  last-good cache 并按 partial 暴露（`scanResultIsComplete`）；stat 失败的
  last-good 视图按当前日历 rebase 7 天窗口并推进 `scannedAt`（对齐 DSH 同分支），
  落盘快照必须以 complete 形态保存（`saveIndex` 有 assert 守门）；失败文件不入
  成功指纹，下一轮重试。
- `isPartial` 出相等 / `isTruncated` 入相等（`AgyLocalUsage.==`，`scannedAt` 同样
  排除）：partialness 走 freshness 通道、不参与结果内容相等；truncation 描述
  数字本身的口径且没有旁路通道，翻转必须能重新发布 UI。
- brain 与 log 两个目录都挂 FSEvents watcher（`jsonl` / `log` 扩展名）；
  transcript 追加是高频事件，由指纹 diff + 缓存短路消化。
- 整个 pipeline 由跨实例共享的 `AsyncMutex` 串行，detached utility 任务承载纯
  文件系统扫描。
- `brain/` 目录不存在时（未装 agy CLI）返回空快照，不报错；
  `LocalUsageOrchestration.checkClientReadiness` 也按该目录存在性短路。

## Refresh timing

agy 不挂独立 timer、没有 quota 依赖：由 `ProviderRefreshScheduler` 每批 Provider
请求结算后的 `LocalUsageOrchestration.reconcile()` 驱动。`scanAllClients` 的批次
序列是 `[minimax, glm, opencode] / [dsh] / [agy] / [antigravity] / [codex]`——agy
单独一批，与 Antigravity RPC 批次隔开（两者都是大 JSONL / trajectory 消费者，
同批会重建这段编排要压掉的内存峰值）。结果经 `AppState.applyAgyUsage` 挂到
`.antigravity` 卡的 `agyUsage` 字段；freshness 走 `LocalUsageSource.agy`，
投影到 `.antigravity` 卡。

## UI

- `.antigravity` 卡三段式的段 3（7 天图）自动获得 agy 贡献：帧进
  `usageProjection` 后与 antigravity native 同管道，卡视图零改动。
- Settings → Clients 的 Agy tab 由 `ClientDescriptor.all` 自动出现
  （displayName `Agy`，icon `paperplane.fill`，subtitle
  「Agy CLI 本地会话与 token 用量」）。
- 设置页客户端切换条 7 客户端实测总宽 ~709pt，超出 6 客户端时代的 660pt 内容区
  口径，按设计由 `ClientSegmentedControl` 外层横向滚动兜底（不压成省略号）；
  守门测试预算放宽到 720pt，守门语义保留。

## Implementation map

| Responsibility | Source |
|---|---|
| 快照模型（isPartial 出相等 / isTruncated 入相等） | `Sources/LLM-monitor/Models/AgyLocalUsage.swift` |
| 行解析 / 去重 / 模型 join / thinking 分摊 / 日聚合纯函数 | `Sources/LLM-monitor/Services/AgyLocalUsageAggregation.swift` |
| scanner（预算截断 / cli log 时间线 / 指纹缓存 / partial 不变量） | `Sources/LLM-monitor/Services/AgyLocalUsageScanner.swift` |
| 帧适配 + `agy:` 命名空间 | `Sources/LLM-monitor/Models/UsageFrameExtractors.swift`（`agyFrames`）+ `Models/UsageProjectionKernel.swift`（`UsageSampleNamespace.agy`） |
| 编排与卡片接线 | `Sources/LLM-monitor/Services/LocalUsageOrchestration.swift`（`agyCoordinator` / `ActiveSources.agy` / readiness 短路）+ `Services/AppState.swift`（`applyAgyUsage`） |
| 缓存路径 | `Sources/LLM-monitor/Services/TokenMonitorPaths.swift`（`TokenMonitorProvider.agy` → `token-monitor/agy.json`） |
| Client 身份与描述符 | `Sources/LLM-monitor/Models/ClientIdentity.swift`（`ClientID.agy` + `ClientDescriptor`） |
| Regression tests | `Tests/LLMMonitorTests/AgyLocalUsageScannerTests.swift`（16 个用例：MODEL 行解析与 thinking 分摊守恒、无 thinking 全记 output、非 DONE / 无 token 行跳过、主文件与分块去重、模型名 join 命中与目录缺失兜底、指纹缓存短路、stat 失败保留 last-good 且窗口重算、log-only 变化解除短路重建缓存、行数熔断失败隔离不入指纹、文件数 / 字节预算截断最旧优先并置位、超长行丢弃与恢复、`AgyLocalUsage.==` 语义、帧投影 `.antigravity` 卡命名空间、unknownModelName 归桶） |
