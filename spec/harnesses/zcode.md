# ZCode Harness — Local Usage & Client Behavior

Scope: local ZCode usage sources, accounting, credential acquisition, and observations of the
ZCode desktop client's own behavior. Remote GLM quota and the monitor's ZCode extension API
integration remain in [GLM Provider spec](../providers/glm.md).

## Local Token Source (ZCode)

GLM Coding Plan's native local token detail comes from the official ZCode CLI's SQLite
database — the same client used to drive GLM. Supported OpenCode and DSH GLM provider IDs
are automatically attributed alongside it.

| Item | Value |
|---|---|
| Database | `~/.zcode/cli/db/db.sqlite` (WAL mode, active `-wal`) |
| Tables | `model_usage` (one row per model request) + `part` (looked up via `model_usage.assistant_message_id` for round-level reasoning classification of 智谱 rows, and for the char-proportion split of 非智谱 slices) |
| Included rows | (`provider_id LIKE 'builtin:bigmodel-%'` OR `provider_id LIKE 'account:bigmodel-%'` OR `provider_id LIKE 'account:zai-%'` OR `provider_id = 'offpeak-idle-plan'`) AND `status = 'completed'` AND (`input + output + reasoning + cache_read`) > 0 |
| Cache | `~/Library/Application Support/LLM-monitor/token-monitor/glm-zcode.json` (versioned, db+WAL fingerprint) |
| Daily window | Seven local calendar days, including today |

The scanner reads the following columns from each GLM `model_usage` row:

```text
started_at                     # epoch ms, source of per-day aggregation
time_to_first_token_ms         # per-call TTFT (epoch ms, 71% coverage); NULL-aware
                               #   read (NULL → nil), /1000 → sample.ttftSeconds
                               #   (main rows and non-智谱 slices share the same rule)
duration_ms                    # epoch ms of the full call (发起→完成, incl. TTFT);
                               #   /1000 → sample.durationSeconds (token/s denominator,
                               #   main rows and non-智谱 slices share the same rule);
                               #   L0 validity domain (0, 3600] s — out of range → nil
turn_id                        # native turn grouping (one user prompt → one turn)
session_id                     # session dedup for sessionCount
model_id                       # diagnosis + per-row modelName
assistant_message_id           # FK to message.id; NULL for session_title, otherwise used
                               #   to test whether a reasoning part exists
input_tokens                   # FULL input (cacheRead is a subset, NOT uncached)
output_tokens                  # generation (includes folded reasoning for reasoning models)
reasoning_tokens               # native value when supplied; otherwise Method A may classify output by part type
cache_read_input_tokens        # cache hit
cache_creation_input_tokens    # cache write (bookkeeping, not in total)
```

The scanner also checks the `part` table via `assistant_message_id`:

```text
part.data                      # JSON: {"type": "reasoning"|"text", ...}
                               # 智谱行: any type='reasoning' part classifies that round as
                               #   reasoning, no character/token ratio is calculated
                               # 非智谱分片: reasoning/text/tool part 的字符数进入比例分摊
```

**Input 口径（重要）**：ZCode 的 `input_tokens` 列是**完整输入（含 cacheRead）**，不是
纯新输入 —— 证据：`computed_total_tokens = input_tokens + output_tokens` 恒成立，且
`input_tokens - cache_read_input_tokens` 才是真实的纯新输入（avg≈1k，符合"每轮新增几百到
几千"）。因此 `LocalUsageDaily.input`（= uncached）= `max(input - cacheRead, 0)`，饱和减法
保证 db 取整误差（cacheRead 偶尔 > input）下不产生负值。这与 Codex daily model 的口径
（uncached input + cached input 子集）完全对齐。

`cache_read` is kept as a separate cache bucket. The displayed total is
`uncached_input + cache_read + output + reasoning`; `cache_write` is reported separately
and is not included in the consumption total.

**Reasoning 口径（方案 A — 按 Round 整轮归类）**：GLM 系列是 reasoning model。ZCode 的账单层
`model_usage.reasoning_tokens` 列实测恒为 0（GLM-5.2 / 5.3 / 5.3-Flash 均如此，2026-08-28 复核
2636 行 GLM-5.3 亦全部走 part 表）—— 但 ZCode
**实际把思考文本存到了 `part` 表**（`type='reasoning'` 的 part，`text` 字段是完整思考过程）。

归类规则（**Method A — 100% 基于账单列和 part 表 JSON 直接判断，不做任何字符/token 换算**）：

| 条件 | 该轮 `output_tokens` 归到哪 |
|---|---|
| `mu.reasoning_tokens > 0`（账单层直接给出，priority path） | `reasoning_tokens` 报账单值, `output_tokens` 报账单值（独立两列；不重分类） |
| `assistant_message_id` 存在 + `part` 表有 `type='reasoning'` part | `reasoning_tokens = output_tokens`, `output_tokens = 0`（**整轮归 reasoning**） |
| `assistant_message_id` 存在 + `part` 表无 `type='reasoning'` part（含 text-only / 缺 type 字段 / 合法 JSON 但无 reasoning part） | `reasoning_tokens = 0`, `output_tokens = output_tokens`（保持原样） |
| `assistant_message_id IS NULL`（`session_title` 后台任务 / 早期数据） | `reasoning_tokens = 0`, `output_tokens = output_tokens`（无 part 可关联） |

实现：`GlmZcodeDBReader.queryPerDay` 的 `SUM(CASE ... WHEN EXISTS (... type='reasoning') ...)`
里，per-row 把 `output_tokens` 整轮归到 reasoning 列（或保持 output 列），不走字符比例估算。
**不是 token 级精确拆分**,而是"该 round 是否整轮算 thinking"的硬分类。

> **关于字符分摊**：本节上面的归类规则、下面的边界条件表，以及"整轮硬分类、不做字符/token
> 换算"的结论，**只适用于智谱行**。但 Method A 对**非智谱 provider 分片**不成立 —— MiniMax / DeepSeek
> 的一轮里思考文本与正文混在同一 `assistant_message_id` 下，整轮归类会把可见正文一起算进
> reasoning。因此分片改走**字符比例分摊**（见「非智谱 provider 分片的 reasoning 口径」），
> 与 MiniMax Code runtime / Dsh M3 同一口径。
> 当前状态：**分类策略仍是两套**（智谱行 = Method A 整轮归类；非智谱分片 = 字符比例分摊），
> 但三处字符分摊的**公式**已统一到共享工具
> `Sources/LLM-monitor/Models/ReasoningCharSplit.swift`，不再各写一份比例算法。

| 边界条件 | 行为 |
|---|---|
| `assistant_message_id IS NULL` | `output_tokens` 保持原样, `reasoning_tokens = 0` |
| `part` 表无该 `message_id` 对应行 | `output_tokens` 保持原样, `reasoning_tokens = 0` |
| `part.data` 缺 `type` 字段 / `type='text'` / `type='tool'` | `output_tokens` 保持原样, `reasoning_tokens = 0` |
| `part.data` 损坏 JSON | reader 先用 `json_valid` 将其替换为 `{}`，再执行 `json_extract`；走 ELSE 分支（output 保持原样、reasoning=0），静默处理 |
| 未来 ZCode 账单层直接写 `reasoning_tokens > 0` | priority path: `output_tokens` 报账单值, `reasoning_tokens` 报账单值（独立加总） |

**实测分布**（189 行 / 单 session, 2026-08-02）: Method A 把 88 / 189 行（47%）的
`output_tokens` 整轮归为 reasoning（part 表里有 `type='reasoning'` part），跟 GLM-5.2
"思考重" 的直觉一致。剩余 101 / 189 行（`session_title` 后台任务 + text-only part）保持
output 不变,`reasoning_tokens = 0`。

OpenCode 的 `zhipuai-coding-plan` 分片本身有原生 reasoning tokens（由
`ProviderStatus.usageProjection` 相加合并），
所以合并后 reason 数据来自两个独立源交叉验证。如果 Method A 估值跟 OpenCode 原生 reason
差异巨大（>20%），说明 ZCode schema 变了（新增 reason 字段 / part 类型变化），
需要重新评估 reader 逻辑。

per-sample 分布：reader 直接输出 `LocalTokenUsageSample.reasoningOutputTokens` 跟 `outputTokens`
(Method A 已经在 SQL CASE 里算好),scanner 不再额外做 sample 回写——比字符分摊时代少一层
"按日比例回写"的复杂度。

### 非智谱 provider 分片的 reasoning 口径（字符比例三段式）

ZCode 的 `model_usage.reasoning_tokens` 对**所有** provider 恒 0，非智谱分片的思考文本同样
只存在于 `part` 表。分片**不走 Method A**（智谱行的整轮硬分类会把 thinking 与正文混排的
一轮整体算成 reasoning），改走与 MiniMax Code runtime / Dsh M3 同款的**字符比例守恒分摊**。

公式收敛到共享工具 `Sources/LLM-monitor/Models/ReasoningCharSplit.swift` 的
`split(outputTokens:reasoningChars:visibleChars:)`：
`reason = round(output × rchars / (rchars + vchars))`，结果 clamp 到 `[0, output]`，
`reasoning + output == 原始 output_tokens` 恒成立；账面 output ≤ 0 或思考字符 ≤ 0 时返回
`nil`（无法估算，调用方保持原样）；字符数异常大时 `Int.max` 饱和而不溢出。

三段式判定（`GlmZcodeDBReader.querySlicePerDay` / `querySliceSamples`）：

| 优先级 | 条件 | 该行 `output_tokens` 归到哪 |
|---|---|---|
| ① native | `mu.reasoning_tokens > 0` | 原样透传：两列独立上报，不重分类 |
| ② 字符分摊 | 无 native + 该 slice/day（或该行）的 `part` 表里有思考文本 | 按上式拆成 `reasoning_tokens` + `output_tokens`（守恒） |
| ③ 兜底 | 都没有（无 part / 损坏 JSON / 字符里没有思考文本） | `reasoning_tokens = 0`，`output_tokens` 保持原样 |

字符口径（`querySliceReasoningChars`，与 MiniMax Code 的字符桶同构）：

| 类别 | `part.data` 条件 | 取的字符 |
|---|---|---|
| 思考 | `$.type = 'reasoning'` | `$.text` 长度 |
| 可见输出 | `$.type = 'text'` | `$.text` 长度 |
| 可见输出 | `$.type = 'tool'` | `$.state.input` 长度（工具参数同属模型生成输出，对应 MiniMax Code 的 `tool_call_args` 桶） |

**粒度**：日聚合（`querySlicePerDay`）是 **day 级**分摊 —— `querySliceReasoningChars`
按 provider × 本地自然日汇总两类字符；逐次样本（`querySliceSamples`）是**行级**分摊 ——
SELECT 里两个相关子查询按 `assistant_message_id` 关联本行 part 字符。两者共用
`ReasoningCharSplit`，都是守恒拆分，所以重算 `totalTokens` 后仍等于原始
`input + output + cacheRead`。

边界：`assistant_message_id IS NULL` 或 `part` 表无对应行时字符数自然为 0 → 走 ③；
`part.data` 损坏 JSON 先由 `json_valid` 替换为 `{}` 再 `json_extract`，静默处理。实测
minimax 分片的 `assistant_message_id` 100% 非空，因此"非智谱行不做 part 归类"已不再是
保留原样的理由。

### Rounds and turns

- **rounds** = `COUNT(*)` — every `model_usage` row is one tokenized LLM call (including
  main-agent, subagent, retry, and `session_title` background generation).
- **turns** = `COUNT(DISTINCT turn_id)` — ZCode emits a native `turn_id`; all model calls
  triggered by one user prompt share the same `turn_id` and count as one turn.
- The recent sample prompt IDs are `session_id:turn_id` (falling back to
  `session_id:event-<id>` when `turn_id` is null). Before cross-source merging, OpenCode
  sample prompt IDs are namespaced with the `opencode:zhipuai-coding-plan:` prefix so a
  native ZCode prompt ID and an OpenCode prompt ID never collide.

### Input display (chart vs quota-window table)

Both the 7-day stacked bar chart and the 「额度窗口」 usage table show the **uncached** input as
the primary "input" number, so the two views never disagree:

- **7-day chart** (`LocalUsageDaily.input`): `GlmDailyUsage.inputTokens` is already uncached
  (= `max(input_raw - cacheRead, 0)`), computed in the reader.
- **Quota-window table** (`QuotaWindowUsageMetrics(usage:)`, the Input bucket behind the
  用量 mode's `Input` column and the 今 / 闲 rows): it renders
  `usage.uncachedInputTokens` (= `max(inputTokens - cachedInputTokens, 0)`)，缓存量单独成
  `Cached` 桶（不是 `(+N cached)` 后缀）。`UsageMetricSummary.inputTokens` keeps
  its project-wide "full input (cache is a subset)" invariant; `cacheHitRate` is still
  computed against full input.

This is a global caliber change (applies to all providers) so the Input number is never
the full input masquerading as new input.

### Off-peak tasks (闲时任务)

### Provider 分类（Coding Plan / Start Plan / 加速卡 / 闲时 / 其他）与额度窗口白名单

ZCode 的 `model_usage` 表是共享账本，GLM 卡按 `provider_id` 分类：

| 分类 | `provider_id` | 典型来源 | 计入额度窗口 | 计入 token 柱图 |
|---|---|---|---|---|
| Coding Plan | `account:bigmodel-individual-coding-plan`、`account:bigmodel-team-coding-plan`、`account:zai-individual-coding-plan`、`account:zai-team-coding-plan`、`builtin:bigmodel-coding-plan` | 交互式 Coding Plan 调用（2026-09-17 `0020_provider_model_selection` 迁移后账号套餐改写 `account:` 前缀；显式枚举于 `zcodeGlmCodingPlanProviderIDs`，通配写法已删，新套餐需显式登记） | **是**（唯一计入来源） | 是 |
| 闲时任务 | `account:bigmodel-offpeak-idle-plan`、`account:zai-offpeak-idle-plan`、`offpeak-idle-plan`（0020 迁移前历史裸值） | 系统赠送的后台任务 | 否 | 是 |
| Start Plan | `provider_id` 含 `bigmodel-start-plan`（`account:bigmodel-start-plan` / `builtin:bigmodel-start-plan`） | 智谱体验套餐；从「其他」里单独摘出成行（`isGlmStartPlanSample`） | 否 | 是 |
| 加速卡 | `account:bigmodel-highspeed-card`、`account:zai-highspeed-card`（显式枚举于 `zcodeGlmHighspeedProviderIDs`；2026-10-25 实测只有 bigmodel 变体出现，zai 变体按账号化命名规律预防性登记） | ZCode 加速卡权益（highspeed-card，`model_id` 就是普通 `GLM-5.3`，不是独立模型）；从「其他」里单独摘出成行（`isGlmHighspeedSample`） | 否 | 是 |
| 其他任务 | 其余 `builtin:bigmodel-%` / `account:bigmodel-%` / `account:zai-%`（含 `account:zai-start-plan`） | 未登记的未来智谱新套餐 | 否 | 是 |
| （不进 GLM 卡，按前缀进分片） | 不带 `builtin:bigmodel-` / `account:bigmodel-` / `account:zai-` 前缀的一切 provider | ZCode 接入的非智谱服务（如 `minimax` / `deepseek`，经 `ZcodeProviderSlice` 并入对应卡片；reasoning 口径见「非智谱 provider 分片的 reasoning 口径」，不走 Method A） | — | — |

Start Plan、加速卡与「其他」任务都不消耗 Coding Plan 积分，额度窗口统计排除，避免高估
消耗；token 柱图保留真实消耗。拆行只是展示层的细分：`isGlmOtherPlanSample` 仍把
Start Plan 与加速卡一起覆盖，额度窗口口径与拆行前完全一致。前缀通配保证未来智谱新套餐
自动落进「其他」。
非智谱 provider 不会被误算进 GLM 卡：它们由 `ZcodeProviderSlice` 的前缀谓词切出
`providerSlices`，再按内置 provider 路由自动归入 DeepSeek / MiniMax 卡。未知 provider 不会
被猜测归类。

设置 → 客户端 → ZCode 按 `GlmUsageCategory.classify`（与额度窗口白名单同一判定，拆行实现
在 `Services/ClientUsageAggregation.glmUsageRows`）把
ZCode 贡献的样本拆成 Coding Plan → Start Plan → 加速卡 → 闲时任务 → 其他任务五行（行序 =
`GlmUsageCategory.allCases` 声明序，无用量的分类不出行），各自独立 token 柱图与计价
——对齐 Antigravity 按模型分组拆行的模式；弹窗卡片维持合并汇总不拆。之后依次是同一
客户端列里 DeepSeek / MiniMax 两个分片行（来自各自卡的 ZCode 贡献，按 provider 自动归因），
排序由 `ClientUsageAggregation.zcodeRowRank` 固定，不参与字母序。
样本为空时不拆行，避免把聚合值错标成某一分类。

ZCode 的闲时任务是系统赠送的、**不消耗 Coding Plan 积分**的后台任务（需提前排队）。
它的 `model_usage` 行写在同一张表，但 **`provider_id` 是独立的闲时 ID**（0020 迁移后
为 `account:bigmodel-offpeak-idle-plan` / `account:zai-offpeak-idle-plan`，迁移前历史
行仍是裸值 `offpeak-idle-plan`；均不是正式 Coding Plan provider）；落在
`off_peak_tasks.[started_at, ended_at]` 时间窗口内的调用不扣积分。

| 位置 | 是否包含闲时 / Start Plan / 加速卡 / 其他任务 token |
|---|---|
| 今日 / 7 天本地 token 柱图（footer） | **包含**（真实 token 消耗，按日聚合不经过窗口过滤） |
| 5h / 周额度窗口行（「额度窗口」表格，`ProviderCardDerivedValues.windowUsageSnapshot` → `LocalUsageSummaryBuilder.windowUsage` 的白名单口径） | **排除**（不消耗积分，计入会高估额度消耗） |
| 额度窗口表格「闲 / 免 / 速 / 它」四条今日动态行 | 单独拆出展示（各分类的今日切片，与 5h / 周 / 今 并列，不计入窗口统计） |

「额度窗口」表格的「闲」行曾是闲时用量的唯一卡内出口，如今与「免 / 速 / 它」并列为
**四条今日动态行**（闲 / 免 / 速 / 它，同一构造模式，闲在前，全部今日切片、无量整行不画）：
曾经的独立闲时脚注（`OffPeakUsageFootnote`）已删除，用量并入表格。「闲」行由
`ProviderCardDerivedValues.offPeakUsageRow` 构造，「免 / 速 / 它」三行由
`ProviderCardDerivedValues.glmCategoryUsageRows` 对 `[.startPlan, .highSpeed, .other]`
三个分类各产一行（行标签 `QuotaWindowUsageSection.startPlanRowLabel` = 「免」 /
`highSpeedRowLabel` = 「速」 / `otherPlanRowLabel` = 「它」，单字，与「闲」同一长度档）。
数据与被删脚注同源同口径（`LocalUsageSummaryBuilder.offPeakTodaySummary` /
`glmCategoryTodaySummary`，今日样本筛选谓词全仓仅 `offPeakTodaySamples` /
`glmCategoryTodaySamples` 一份——后者是前者的按 `GlmUsageCategory` 泛化形态），
价值列对同一批今日样本走 `ModelPricingCatalog.estimate` 计价（原币种，格内不加
「零积分」说明），速度列对同一批样本走 `windowTokenRate`；仅
`status.kind == .glmCodingPlan` 构造，重置日期格恒 `—`，四桶合计为 0 由 `visibleRows`
统一跳过，说明句「ZCode 闲时任务真实消耗；不影响 5h / 周积分余额」逐字保留为「闲」行
类型格的 tooltip（免 / 速 / 它暂无专属说明句）。

实现：`GlmZcodeDBReader` 读 `builtin:bigmodel-%` / `account:bigmodel-%` / `account:zai-%`
三前缀 LIKE + `offpeak-idle-plan` 裸值精确匹配（每个前缀一个 `LIKE ?`，再加一个精确 `= ?`，
谓词与绑定由 `zcodeBigmodelProviderPrefixes` 同源生成），让闲时与其他任务的真实消耗进入
今日 / 7 天柱图。scanner 每次扫描额外读 `~/.zcode/v2/tasks-index.sqlite` 的
`off_peak_tasks` 表（`status='completed'` 且 `started_at` / `ended_at` 都非空、且
`ended_at >= started_at`），产出
`[GlmOffPeakWindow]` 挂在 `GlmLocalUsage.offPeakWindows`。`LocalUsageSummaryBuilder.summary`
的额度窗口路径是**白名单**口径：sample 上的原始 `provider_id` 精确判定——
闲时 ID（`account:bigmodel-offpeak-idle-plan`、`account:zai-offpeak-idle-plan`
与历史裸值 `offpeak-idle-plan`，显式枚举于 `zcodeOffPeakProviderIDs`，经
`isZcodeOffPeakProvider` 判定）归为闲时（`isGlmOffPeakSample`），其余智谱前缀
（非正式 Coding Plan，`isZcodeGlmCodingPlanProvider` 判定）归为其他（`isGlmOtherPlanSample`），两者都不计入额度窗口；同一时间
窗口内的正常 Coding Plan 调用不会被误排除。旧缓存没有来源字段时，才回退到
`completedAt` 是否落入闲时窗口（闭区间 + 2 秒容差）。
OpenCode / DSH 合并 sample（`zhipuai-coding-plan`、`dsh:glm` 等）不带 bigmodel 前缀，
始终视为正常消耗。

> 缓存版本 11：同库内非智谱 provider（`minimax` / `deepseek`）按 `ZcodeProviderSlice`
> 前缀切出 `providerSlices` 随快照一起供 MiniMax / DeepSeek 卡消费；v10 快照该字段恒为
> nil，直接复用会让卡片永久缺这条来源，升版强制重扫。（v10：识别
> `0020_provider_model_selection` 迁移后的 `account:bigmodel-` / `account:zai-` 前缀，
> 读取谓词同步为三前缀 LIKE + `offpeak-idle-plan` 精确匹配；v9 快照漏掉迁移后新写入的
> 账号套餐行。**v9**：额度窗口改为"仅正式 Coding Plan 计入"白名单口径，纠正 v8 错误算入的
> 其他套餐样本。）

## Accounting contract

ZCode 的 `model_usage.input_tokens` 是包含 cache-read 的 raw input，
`cache_read_input_tokens` 是子集。reader 的 daily 路径先计算 uncached input；sample
保留完整 input 以兼容 `LocalTokenUsageSample`。Method A 已在 reader 内完成 reasoning
归类：output/reasoning 进入统一层时已经互斥，不再二次相减。`cache_creation_input_tokens`
只保留为 raw 诊断，不进入统一 total、图表或金额估算。Method A 只属于**智谱行**；同一本
账本里的**非智谱 provider 分片**（`minimax` / `deepseek` 等）不走 Method A，改走字符比例
三段式分摊，见「非智谱 provider 分片的 reasoning 口径」。见
[`spec/accounting.md`](../accounting.md)。

## Local credentials

`GlmZcodeCredentialReader` 读取 ZCode 的 `deviceMid` 与 JWT。当前观察到的本地来源为
`~/.zcode/v2/telemetry-state.json`（明文设备标识）及 `~/.zcode/v2/credentials.json`
（`zcodejwttoken` 等 `enc:v1:` 值）；Swift reader 使用 CryptoKit AES-256-GCM，并按实现
中的 fallback 密钥派生方式解密：SHA-256 of
`zcode-credential-fallback:darwin:<homeDirectory>:<userName>`。具体路径可由 GLM `authPath` 指定。LLM-monitor 只在
JWT 扩展开关开启时读取凭证；OAuth access token 不作为 GLM 请求凭证。文件格式与解密
方法属于客户端实现观察，可能随 ZCode 版本变化。

## ZCode desktop client polling observations (2026-11-06)

Static inspection of `/Applications/ZCode.app/Contents/Resources/app.asar` for
ZCode `3.17.2` (bundle build `3.17.2.9661`) found the following client-side behavior. These
observations describe that installed build only; they are not an official API contract and
are independent of LLM-monitor's provider refresh schedule. No fixed timer was found for the
activity-plan entitlement lookup.

| Client feature | Observed behavior |
|---|---|
| Billing balance helper | GET calls are coalesced by API client, authorization value, and URL. A settled/in-flight promise is kept for about 1 second to deduplicate overlap; this is not a durable response TTL. The helper itself showed no periodic timer; calls are made by entitlement validation and usage snapshot requests. |
| Marketing touch | In production, successful polling repeats every 10 minutes while the authenticated marketing controller is visible. Initial mount, visibility restoration, and browser `online` trigger an immediate query. Hidden state pauses polling. Failures retry with 30s, 60s, doubling intervals up to 10 minutes. |

## Official client reset-card behavior

**机制**（[官方使用统计文档](https://zcode.z.ai/cn/docs/usage-stats)）：额度重置卡分
5 小时 / 每周两类，在有效期内使用可把对应额度立即恢复到 100%。ZCode 会在闲时自动向
Coding Plan 用户下发 5 小时卡（闲时时段 + 5h 用量超阈值 + 当日下发次数未达上限）；
其他活动的重置卡也在端内一并显示。多张卡时自动使用最早获得的。

**接口**（ZCode 客户端逆向，`/api/v1/coding-plan/reset/*`，host 为 `zcode.z.ai`）：

| 端点 | 方法 | 说明 |
|---|---|---|
| `/api/v1/coding-plan/reset/status` | GET | 可用重置卡列表 + 使用历史（面板数据源） |
| `/api/v1/coding-plan/reset/use` | POST | 用卡，body `{idempotency_key, reset_type}` |
| `/api/v1/coding-plan/reset/opportunity` | POST | 闲时申领 5h 卡；业务码 `3301` = 未中签（`data.next_try_at`） |
| `/api/v1/coding-plan/reset/history/read` | POST | 标记历史已读 |

以上是客户端行为与接口调研；LLM-monitor 仅读取 `/status`，远端响应与鉴权契约见
[GLM Provider spec](../providers/glm.md#额度重置卡接口与展示)。

## ZCode 上下文压缩行为（调研记录，2026-10-29）

> 只读调研（窗口 10-21~10-28：4,375 completed 智谱行、91 sessions / 299 turns）。
> 非官方契约，随 ZCode 版本可能变化；本节只记录发现，不进任何代码路径。

**核心结论：ZCode（3.16.3）没有自动会话压缩（compact）。** 上下文水位单调增长，
实测 main_turn 持续水位 **435,978 tokens**（15.1 小时、+389K、零压缩），单行尖峰
**586,892**（GLM-5.3 正常返回 tool-calls，无 context_exceeded）；「prev ≥ 120K 且
next < 0.55×prev」的 antigravity 式骤降检测命中的 3 次全部是**单次请求注入的尖峰
假信号**（下一调用立即回到 prev+微涨、cache 前缀不变 cr/in=0.983），不是压缩。
无 summary 模型条目、message 表无 compact 事件类型、日志无 compact 记录。

ZCode 真正的上下文管理手段（rollout model-io 字段实证）：

| 机制 | 行为 |
|---|---|
| **请求窗口三分法**（`messagesKind` / `messageOffset` / `messageCount`） | `full`（全量消息库）/ `tail`（**固定最后 64 条**，offset=count−64）/ `delta`（仅新增 2~3 条）；水位 = 底座 + 窗口内容 |
| **turn 边界 reasoning 剥离** | 新用户消息后，窗口内旧 assistant 消息的 reasoning 块全部不发。实测 diff：reasoning 46,471 字符 → 0、text 原样，input 236,681 → 171,636（−65K，回落比 0.72~0.81，6 次同类）；**cache_read 全部崩塌到 18.5~23.4K**（cr/in≈0.11~0.21，前缀从头改写） |
| **静态底座** | system prompt + 56 个工具定义 ≈ **22,080~23,360 tokens**（缓存失效后幸存的幸存前缀）；session 首行 input p50 = 30,690（含首条消息） |

其余量：增长斜率（435K session）≈ +25.8K tokens/hour；turn 级水位（n=223）p50 =
170,610 / p90 = 417,654 / max = 586,892；subagent 行水位 p50 = 86,639、max = 403,929
（分 agent 上限：G53-General 272K、general-purpose 404K、Explore 116K）。

**与 Antigravity / Codex 的路线差异**：ZCode 的水位由「窗口构造」决定而非「全部
历史」，压缩式骤降检测在 ZCode 上不可用；真实削减只有 turn 边界的 reasoning 剥离
（削 19~27% 且 cache 全断）。

**数据在哪看**：

```bash
# WAL 活跃库：三件套拷到 /tmp 只读，勿直查原文件
cp ~/.zcode/cli/db/db.sqlite{,-wal,-shm} /tmp/zc.db
sqlite3 -readonly /tmp/zc.db "SELECT session_id,started_at,turn_id,input_tokens,
  cache_read_input_tokens,output_tokens,model_id FROM model_usage
  WHERE provider_id LIKE 'account:bigmodel-%' AND status='completed'
  ORDER BY session_id,started_at;"
```

`query_source` 区分 main_turn / subagent / session_title（session_title 行 input 仅
236~732，剔除）；3.16.3 的 turn_id 无 NULL。请求构造的实证文件在
`~/.zcode/cli/rollout/model-io-session_*.jsonl`（**只保留最近 3 个 session**，尖峰
session 不一定在内）。

## TTFT / 首字时延上游字段（调研记录，2026-11-08）

> 只读调研（本机 `~/.zcode/cli/db/db.sqlite` 实测）。非官方契约，随 ZCode 版本可能
> 变化；本节只记录发现，不进任何代码路径。

`model_usage` 表自带**逐模型调用粒度**的原生时延列：

| 列 | 含义 |
|---|---|
| `first_token_at` | epoch 时刻，首个 token 到达 |
| `time_to_first_token_ms` | 首 token 延迟（TTFT） |
| `duration_ms` | 全调用时长（发起→完成，即监控现消费的口径） |

另有 `turn_usage` 表（**逐 turn 粒度**）带同款时延列
`first_model_start_at` / `first_token_at` / `duration_ms` / `time_to_first_token_ms`。

覆盖率实测（2026-11-08）：`model_usage` 16,434 行中 11,658 行（**71%**）有
`time_to_first_token_ms`，`duration_ms` 100% 有值；缺口成因未深究（疑为中断调用或
早期版本行）。

监控现状（2026-11-08 更新）：reader 消费 `duration_ms`（含 TTFT 的总时长，见
§Local Token Source 列注释与 [`accounting.md`](../accounting.md) §Token/s 速率口径），
并已接入 `time_to_first_token_ms`——主表与非智谱分片两条 SELECT 都读该列，
NULL-aware 读取（NULL → sample `ttftSeconds` nil，71% 缺口行不伪装成 0），ms ÷ 1000
写秒；缓存 v12 重建。`first_token_at` 仍未读取（epoch 时刻，TTFT 已含其信息）。
zcode-tps-monitor 插件也在消费同库该字段（其「首字 N s」读数）。

## Implementation map

| Responsibility | Source |
|---|---|
| Local usage data model | `Sources/LLM-monitor/Models/GlmLocalUsage.swift` |
| SQLite reader | `Sources/LLM-monitor/Services/GlmZcodeDBReader.swift` |
| Off-peak window reader | `Sources/LLM-monitor/Services/GlmZcodeOffPeakReader.swift` |
| Scanner, cache, and seven-day snapshot | `Sources/LLM-monitor/Services/GlmZcodeLocalUsageScanner.swift` |
| ZCode 本地凭证读取 | `Sources/LLM-monitor/Services/GlmZcodeCredentialReader.swift` |
| Window summary + off-peak exclusion | `Sources/LLM-monitor/Models/LocalTokenUsageSample.swift` |

### Scan trigger

All local scanners — GLM included — are driven by
`LocalUsageOrchestration.reconcile()` after each Provider batch settles. Startup performs a Full Scan;
manual, wake-up, interval, and natural-day reconciles use dirty mode after startup and only
reprocess changed source data. This remains independent of whether the quota batch succeeded.
GLM's former dedicated periodic trigger (`AppState.glmLocalUsagePeriodicTask`) has been removed.

The scanner's db+WAL fingerprint check is unchanged: when nothing changed only a `stat()` runs
(microseconds); SQL (~1.5ms) only runs when the WAL actually moved.

## Test Coverage

Local SQLite reader, scanner, off-peak/category attribution, credential parsing, and context
accounting coverage lives in `GlmZcodeDBReaderTests.swift`, `GlmOffPeakTests.swift`,
`GlmUsageCategoryTests.swift`, and `GlmZcodeCredentialReaderTests.swift` (under
`Tests/LLMMonitorTests/`). Provider API/auth orchestration tests remain in the
[GLM Provider spec](../providers/glm.md#test-coverage).

| Test | What it verifies |
|---|---|
| `testGlmZcodeDBReaderMethodAClassification` | Native/reasoning-part priority, malformed JSON fallback, and conservation |
| `testGlmZcodeDBReaderNativeAndSnapshot` | Native aggregation, samples, snapshot padding, and today selection |
| `testGlmReaderAppliesRecentCutoffToDailyAggregation` | Recent cutoff applies to daily aggregation and samples |
| usageProjection GLM client contribution tests | OpenCode GLM usage projection and sample namespace |
| `testOffPeakUsageRowMirrorsTheDeletedFootnote` | 「闲」行与被删脚注同源同口径：四桶映射与 `offPeakTodaySummary` 一致（Input 为未缓存输入），命中率与 `summary.cacheHitRate` 相等，价值对同批 `offPeakTodaySamples` 与目录逐分一致（¥ 原币种）；正常任务样本不进「闲」行 |
| `testOffPeakUsageRowIsNilWithoutOffPeakSamplesToday` | 当天无闲时样本 →「闲」行整个不画（nil，不是全零行） |
| `testOffPeakUsageRowIsNilForNonGlmProviders` | 非 `glmCodingPlan` kind 恒返回 nil（闲时窗口只属于智谱任务，不泄漏到共用 ZCode 账本的 MiniMax / DeepSeek 卡） |
| `testGlmCategoryUsageRowsMirrorTheOffPeakRowConstruction` | 「免 / 速 / 它」三行与「闲」行同构：行序 免 → 速 → 它、四桶与 `glmCategoryTodaySummary` 一致、价值/速度对同批 `glmCategoryTodaySamples` 逐分一致、重置格恒 `—`、正常与闲时样本不进动态行 |
| `testGlmCategoryUsageRowsAreEmptyWithoutMatchingSamplesToday` | 当天三分类都无样本 → 空数组（不凭空造行） |
| `testGlmCategoryUsageRowsAreEmptyForNonGlmProviders` | 非 `glmCodingPlan` kind 恒返回空数组（同「闲」行的防泄漏理由） |
| `testGlmHighspeedSampleStaysExcludedFromQuotaWindow` | 加速卡拆行不影响额度窗口口径：`isGlmOtherPlanSample` 仍覆盖、无来源标记不误判、与 Start Plan 互斥 |

> 本文件源自 `spec/providers/glm.md` 的本地 harness 内容；代码核对基线继承原文件，未因本次拆分重新核对全部实现。
外部 ZCode.app 静态观察日期：2026-11-06；版本 `3.17.2` / build `3.17.2.9661`。

> 核对基线：2026-11-08 · 代码 1a4238f
