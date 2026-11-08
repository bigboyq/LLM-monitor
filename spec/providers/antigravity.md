# Antigravity — Provider Spec

Provider id: `antigravity`

Implementation: `Sources/LLM-monitor/Fetchers/AntigravityFetcher.swift`（额度决策树：远端主路径 + 本地回退）+ `Sources/LLM-monitor/Fetchers/AntigravityProcessDiscovery.swift`（进程发现，2.4.2 起回退专用复活）+ `Sources/LLM-monitor/Fetchers/AntigravityCredential.swift`（Keychain 凭据读取/解析）+ `Sources/LLM-monitor/Fetchers/AntigravitySchemas.swift`（远端/本地响应模型）+ `Sources/LLM-monitor/Services/AntigravitySessionDBReader.swift`（会话 `.db` 直读）+ `Sources/LLM-monitor/Services/AntigravityLocalUsageScanner.swift` 及其同族（`AntigravityFilesystem.swift` / `AntigravityLocalUsageCache.swift` / `AntigravityLocalUsageAggregation.swift`；`AntigravityStepTimestampReader.swift` 由 agy harness 共用保留）

**阶段一（2026-11-08）**：额度/账号路径已切换为 Keychain 凭据 + 远端 Google API——读取登录钥匙串 `gemini` / `antigravity` 条目的 OAuth access_token，直接 POST `googleapis.com` 配额接口，额度主路径退役进程发现（Antigravity 未运行时额度照常工作，token 未过期时）。

**阶段二b（2026-11-08）**：本地用量路径退役本地 RPC / `.pb` 支持——scanner 对每个脏 session 用 `AntigravitySessionDBReader.probe → readCalls + readUserTurnSteps` 直读会话 `.db`（全量读，本地 db 毫秒级），不依赖 Antigravity 进程运行、不发任何网络请求、不做混合/回退；读失败按错误类别两路收敛——probe `.incompatible` 的 session 当轮采纳当前指纹，SQLite I/O 类 `.retryable` 不采纳指纹自然重试、连续 3 次有界收敛（两路都记一次失败 + log、保留 last-good，不做 RPC 回退）。下文 § Incremental trajectory metadata / § Bounded convergence 为历史记录。

**2.4.2（2026-11-08，keychain 陈旧窗口回退）**：额度路径增加「keychain 过期 → 本地 language_server RPC」回退。背景事实（已实测）：keychain 条目 `gemini/antigravity` 只在登录/agy 使用时被写，IDE 运行期间刷新的 token 只在其内存（经 host bridge 分发），keychain 会陈旧；过期 token 打远端必 401；而运行中的 language_server 持有 bridge 新凭据且本地 RPC 一直可用。决策树：凭据新鲜 → 远端主路径（不变，远端 401 亦转入本地回退）；凭据缺失/过期 → 进程发现（`AntigravityProcessDiscovery`，原 Phase-0 排序规则复活）+ 本地 `RetrieveUserQuotaSummary`（`response` 包装形状，group/bucket 归一化与远端共用），账号信息用本地 `GetUserStatus`（仅 `.full`，可选失败，tier 回退链照 spec）。本地 RPC 成功后不再打远端；回退失败时凭据缺失/过期或「远端 401 且无本地后端」落 `credentialExpired`（新文案「token 已过期：打开 Antigravity 可继续监控额度，重新登录可刷新凭据」），其余错误按现有路径上抛。用量 scanner 保持纯 `.db` 直读不变（无 RPC 回退）；refresh_token 流程仍然不做。§ Discovery Flow / § Local RPCs / § Local RPC Response Shapes 中与 quota/account 相关的小节按「回退路径」口径恢复为运行时事实。

**2.4.3（2026-11-08，额度来源标记 + 设置窗口展示）**：两条成功路径给返回的 `QuotaInfo` 打来源标记 `antigravityQuotaSource`（远端 → `.remoteCloudCode`、本地回退 → `.localLanguageServer`，见 § Remote Quota Path 的「来源标记 + UI 展示」）；设置窗口 Antigravity pane 在「允许监控刷新 Token」开关下方新增只读「额度来源」行展示当前路径（UI 细节见 [`spec/ui/settings.md`](../ui/settings.md) § Antigravity pane 的「额度来源」行）。

## Current Status

| Item | Current implementation |
|---|---|
| Auth source | 登录钥匙串条目 service=`gemini` / account=`antigravity`（Antigravity 客户端写入并自行续期）；不需要 Antigravity 运行。2.4.2 起条目缺失/过期时回退本地 RPC（见下），回退也失败才落 `credentialExpired` |
| Direct OAuth token use | ✅ 阶段一起直接使用 Keychain access_token 请求远端配额接口；本地判定 `token.expiry`，过期不发任何远端请求、转入本地回退（2.4.2） |
| Process discovery | ↩ 2.4.2 起**额度回退路径恢复**（`AntigravityProcessDiscovery.swift` 从 aafbae0^ 复活）：仅凭据缺失/过期或远端 401 时 pgrep + lsof + CSRF；额度主路径仍不发现进程，本地用量路径仍 `.db` 直读（阶段二b，无 pgrep） |
| Main local RPCs | 回退路径三件套（2.4.2）：`RetrieveUserQuotaSummary`（quota，致命）+ `GetUserStatus` / `GetLoadCodeAssist`（账号/tier，仅 `.full`，可选失败）。`GetCascadeTrajectoryGeneratorMetadata`（per-event token usage）保持退役，scanner 直读会话 `.db` |
| Remote endpoints | `POST /v1internal:retrieveUserQuotaSummary`（quota）、`POST /v1internal:loadCodeAssist`（tier，仅 `.full`），见 § Remote Quota Path (Phase 1)；仅 401 终止主机回退并转入本地回退 |
| Account fields | email = Keychain `id_token_email`（本地回退时 GetUserStatus.email 优先、Keychain 兜底）；tier = 远端 `currentTier.name` → `paidTier.name` → `paidTier.id`；本地回退（`.full`）= `userStatus.userTier.name` → `planStatus.planInfo.*` → `GetLoadCodeAssist.currentTier.name`（见 § Local RPC Response Shapes） |
| Refresh cadence | 默认 **300s**（provider 未显式配置时；本地 RPC 时代为 60s）；显式 `refreshIntervalSeconds` 不受影响。tier 仅 `.full`（「次要信息频率」），后台通过 `AntigravityFillingMissingMerger` 保留上次账号/套餐 |
| Model groups | `Gemini Models`, `Gemini 4 Argon`, `Claude and GPT models` |
| Window types | `5h`, `weekly` |
| Reset credits | Not used |
| **Local token usage history** | ✅ `.db` 直读架构（阶段二b）：`gen_metadata` ↔ `steps` 连接命中的逐调用 uncached input / cacheRead / rawOutput（含思考）/ reasoning，聚合到最近 7 个本地日，持久化到 `~/Library/Application Support/LLM-monitor/token-monitor/antigravity.json`；turns = `step_type=14` 直计（turnIndex ≥ 1 首见开轮，turn-0 背景调用不开轮）、rounds = 连接命中 Call 数；`cacheWrite` 恒 0（db 不提供，本就排除在 total 外，仅诊断可见性损失） |

## Accounting contract

Antigravity call 的 uncached input 与 `cacheRead` 独立记录命中缓存。raw output
（db `gen_metadata` usage 子消息 `f3`，与旧 RPC `outputTokens` 同口径）**已含思考**——
用户在本机 271 个会话（60,373 条含 token 事件）上实测 100% 满足
`outputTokens == thinkingOutputTokens + responseOutputTokens`。因此
`TokenAccountingCatalog.antigravity` 声明 `output: .reasoningIncluded`（与 DSH 同款关系）：
规范化 `Output = outputTokens − thinkingOutputTokens`、`Reason = thinkingOutputTokens`，
`Output + Reason == rawOutputTokens`，四桶守恒；daily 与 sample 的 raw→桶都走该 catalog
唯一入口（`AntigravityLocalUsageAggregation.aggregateDaily` / `makeSample`）。sample 为
兼容历史结构将 input 保存为 `input + cacheRead`，`reasoningOutputTokens` 保存分拆后的
思考桶。`cacheWriteTokens` 只保留在 raw 诊断数据，不进入统一 total、图表或价值估算。见
[`spec/accounting.md`](../accounting.md)。

## Model Pricing

客户端 tab 的名义价值估算基于随 app 打包的价格目录
[`Sources/LLM-monitor/Resources/ModelPricing.json`](../../Sources/LLM-monitor/Resources/ModelPricing.json)
（`ModelPricingCatalog` 启动时加载）。Antigravity 的条目（USD per 1M
tokens，模型名小写 + `_` 归一为 `-` 后按 contains 匹配，数组顺序即求值顺序）：
调价 / 增删模型需改 JSON，并同步 `ModelPricingJSONTests` / `ProviderModelTests` 的
价格断言与本 spec 的价格表。

| 模型 | Input | Cache read | Output |
|---|---|---|---|
| Gemini Flash 3.x（`gemini-3.6-flash` / `gemini-3.7-flash` / `gemini-3.8-flash`） | 0.75 | 0.075 | 3.75 |
| `gemini-3.1-pro` | 2.00 | 0.20 | 12.00 |
| `gemini-4-argon` | 2.00 | 0.10 | 10.00 |
| `claude-opus-5.5` / `claude-opus-5-5` | 4.00 | 0.20 | 20.00 |
| `claude-sonnet-5.5` / `claude-sonnet-5-5` | 2.00 | 0.20 | 10.00 |
| `gpt-oss-120b` | 0.09 | 0.009 | 0.36 |
| `claude-4` / `claude-3.7-sonnet`（旧 Claude 家族） | 3.00 | 0.30 | 15.00 |
| `claude-3.5-haiku` | 0.80 | 0.08 | 4.00 |
| `gpt-4.1` | 2.00 | 0.50 | 8.00 |

- **Gemini 支持清单**：`gemini-3.1-pro`、`gemini-4-argon` 与 3.6 / 3.7 / 3.8 Flash 有价。
  **Gemini 2.5 系列（Pro / Flash）已退休**：条目已删除，历史用量显示"未定价"（有意行为）。
- **Gemini 4 Argon**：按 introductory API 定价（至 2026-11-30，`2.00 / 0.10 / 10.00`）；`gemini-4-argon` 子串同时覆盖 `-low` / `-medium` / `-high` 三个思考档位。
- **Claude Opus / Sonnet 4.6 已下架**（2026-10 起被 5.5 取代）：条目已删除，历史用量显示"未定价"（有意行为，与 Gemini 2.5 退休同口径）。
- **Gemini 3.1 Pro**：按标准档（≤200K 上下文）定价；>200K 的长上下文档不建模 ——
  本地账本不保留请求上下文长度，与 MiniMax >512K 档不参与同一口径。
- **Gemini 3.8 Flash**：官方价与 3.7 Flash 完全相同（introductory 定价至 2026-12-31），
  因此共用 "Gemini Flash 3.x" 同一条目。
- Antigravity 没有兜底价：未知模型保持"未定价"并在客户端 tab 明确列出（与 zhipu 的
  永远兜底口径不同）。

## Window Value Anchors（窗口价值锚，调研记录）

> 2026-11-06 校准记录。额度 API 只提供 `remainingFraction` 百分比，无金额语义；以下金额锚点
> 由「本地目录价折算的用量 ÷ 官方已用百分比」互推得出，仅供余量折算美元参考——
> **不进任何代码路径**（app 不展示窗口美元值）。价格口径即 §Model Pricing 的 Gemini
> intro 折扣价。本地账本只覆盖本机 IDE + agy CLI，锚点是**下界**：账号在其他设备的
> 用量不计入。Gemini 周额度最终实测确认为 **$120**、5h **$30**，周 / 5h 容量比精确为 **4.0**；
> 此倍率进入窗口换算代码，金额锚仍只作调研记录。

| 组 / bucket | 窗口结构 | 整窗价值锚 | 依据 |
|---|---|---|---|
| `Gemini Models`（`gemini-5h` / `gemini-weekly`） | 5h + weekly，周 = 4 × 5h | **$120 / 周，$30 / 5h** | 2026-11-06 用户再次实测确认周额度 $120、5h $30、容量比精确 4.0；取代同日早前的 $100 / 3.5 读数（该读数又取代最初 4.0 倍 / 5h $25 的推算） |
| `Gemini 4 Argon`（`gemini-argon-wtu-weekly`） | 仅周窗，独立重置时间 | **≈ $15 / 周**（实测 $14.8，取整） | 见下 |
| `Claude and GPT models`（`3p-5h` / `3p-weekly`） | 5h + weekly，周 = 2 × 5h | 无锚点（本机 3p 用量不足以校准） | — |

**Argon $15 校准（2026-10-28）**：周期 2026-10-25 21:00（北京）起，本机
`gemini-4-argon-trial` 164 个样本——首条 13:00:17Z（重置边界后 17 秒），与 10-26 /
10-27 两个完整本地日的日桶逐 token 对账一致，无采样裁剪。已用价值 **$7.01** =
1.415M uncached input × $2 + 22.49M cacheRead × $0.10 + 192.8K (output+reason) × $10，
对应官方已用 47.4% → $7.01 ÷ 0.474 ≈ $14.8 ≈ **$15**，推算剩余 ≈ $7.8。周期内消费
为单一模型，金额锚与 token 锚（bucketId 的 `wtu`）成严格正比，两种口径互不冲突。

## Context compaction（上下文压缩，调研记录）

> 2026-10-28 观测结论（最近一周 6276 事件 / 34 会话 / 550 turns，27 个独立压缩事件）。
> 非官方契约，随 IDE 版本可能变化；本节只记录发现，不进任何代码路径。

**设计模式：~300K 预判触发 → 压到 ~20K 起步**（中位场景压掉 93%）。

压缩的准确语义是 **`(INPUT + A) → (INPUT + B)`**：`INPUT` ≈ **10.7K**（系统提示 +
工具定义 + 环境上下文等不参与压缩的固定底座，由新会话 turn-1 的 first input 直接测得，
p25/p75 = 9.4K/14.2K——三者合并在 input 水位中不可分离，System Prompt 单独大小无法
从数据侧验证），压缩只作用于其上的历史水位 A。post 众数 19K 的分解：底座 10.7K +
新用户消息 ~1.5K + **Compressed History ≈ 6.8K**：

| 观测量 | 值 |
|---|---|
| 触发时点（pre = INPUT + A） | 129K ~ 298K，p50 = 265K；**预判式**而非固定水位——`当前水位 + 本 turn 预期增量 > ~300K` 即触发，重 turn（单 turn 增幅 +60K~290K 的工具循环）在 130K~230K 提前触发，轻 turn 涨到 290K+ 才触发 |
| 压缩完成（post = INPUT + B + ~1.5K 新用户消息） | 11K ~ 118K，p50 = 19K |
| **标准档 B**（post 直方图主峰 18~20K，扣 INPUT 与新消息后） | **Compressed History ≈ 6.8K，近似固定值、与 A 无关**（真实水位比 B/A ≈ 2.4%~2.7%），A 中位 ~255K、极端 ~287K 仍压到同一形状——**不是等比压缩**，post 与 pre 回归零相关甚至负相关 |
| 松压缩档（长尾 post 42K~118K） | B ≈ 30K~110K，B/A 12%~49%，疑似保留最近若干轮原文较多的模式；6/27 事件 pre < 200K 提前触发多属此类 |
| 表观压缩比（post/pre，含 INPUT 混淆） | 5% ~ 54%，p50 = 7%——仅作粗口径，真实水位比用 B/A |
| 重度会话节奏 | `739a3bba`（10-22）一天 5 次：05:51 从 35K 起步、4h/19 turns 涨到 271K 触顶，之后 37min → 1h35m → 2h10m → 42min 压一次；连环场景 17 分钟内连压 3 次（199K→63K→232K→66K→272K→73K） |

**数据在哪看（复现路径）**：

1. 事件账本：`~/Library/Application Support/LLM-monitor/token-monitor/antigravity.json`
   的 `samplesBySession`——scanner 直读 `.db` `gen_metadata` 得到的全量逐调用样本
   （非采样），每个样本带 `completedAt` / `inputTokens`（cache-inclusive，
   即该轮喂给模型的完整上下文）/ `promptID`（`<session>:turn-N`）。原始 db
   （`~/.gemini/antigravity/conversations/<uuid>.db`）的会话过程流（`steps`/`step_payload`）
   是 protobuf blob，不便直读；但 `gen_metadata` 表是结构化的（见下文 § Token & model data
   ARE in `.db` `gen_metadata`，阶段二b起即 scanner 数据源）。
2. 水位口径：按 `promptID` 聚 turn，**压缩前水位 = pre turn 的 last input**（turn 内
   递增，末次调用 = 完整历史，最后一条 input 已进历史、会被一起摘要，不扣）；
   **压缩完成水位 = 下一 turn 的 first input**（= 摘要 + 保留消息 + 新用户消息）——
   **不要用下一 turn 的 max**：turn 内工具循环会继续推高水位（均值 +15K，极端 +288K），
   混入本 turn 新增。新用户消息用非压缩相邻对的 `first − prev_last` 估计，中位仅 1.5K。
3. 检测：相邻 turn 满足 `prev_last ≥ 120K 且 next_first < prev_last × 0.55` 记为一次压缩。
4. **压缩摘要原文**（`# Resuming from a compaction` 模板）落盘在
   `~/.gemini/antigravity/brain/<session-id>/.system_generated/logs/transcript_full.jsonl`
   的 `type == "CHECKPOINT"` 条目（实测 4 条，时间戳与水位检测的压缩事件逐一吻合，
   6.8K~19.5K 字符）。同文件 `USER_INPUT` 条目是用户输入原文；但 **system prompt 与
   工具定义不落盘**（db 与 transcript 均只存过程流：用户输入 / 模型输出 / 工具结果，
   请求层的 systemInstruction 与 tool schema 不在其中），底座 10.7K 的内部拆分只能靠
   turn-1 first input 总量推断。
5. 陷阱：会话 fork/克隆在 gen_metadata 里表现为**逐秒相同时间戳的副本 session**
   （实测 `739a3bba` 有两个克隆；另有一秒内 47 事件的 302K 快照回放），统计前必须按
   时间戳去重，否则事件数虚高、起步水位失真。

## Config

Full config shape:

```json
{
  "refreshIntervalSeconds": 300,
  "providers": {
    "antigravity": {
      "enabled": true,
      "refreshIntervalSeconds": 300
    }
  }
}
```

Supported provider fields:

| Field | Meaning |
|---|---|
| `enabled` | Enables/disables this provider. |
| `refreshIntervalSeconds` | Optional independent refresh interval. **Provider 未显式配置时默认 300s**（阶段一起远端轮询对齐 IDE 自身 fetchAvailableModels 的约 6 分钟节奏，取代本地 RPC 时代的 60s 档；`AppConfig.defaultProviderRefreshInterval`）。显式配置不受影响。 |
| `allowTokenRefresh` | **强制 false**（bool，缺省 false）：token 由 Antigravity 客户端在钥匙串内自行续期，监控侧没有 refresh 流程。手改 json 为 `true` 属于无效/恶意修改——解码抛 `AppConfig.SchemaError.antigravityAllowTokenRefresh`（沿用配置解码错误呈现路径：启动保留原文件按默认配置运行、热重载保留上次配置）+ log warn，provider 按 false 运行。设置窗口开关可见但恒为关（disabled）。 |
| `displayName` | Optional card title override. |
| `notifyIntervalRestored` etc. (4 fields) | Optional per-event notification channels (5h/weekly × restored/exhausted): `none` / `system` / `barkAndSystem`. Defaults: restored → `system`, exhausted → `none`. See `spec/notifications.md`. |

`authPath`, `apiKey`, and `serverPath` are not used.

> **Note**: `serverPath` was removed in v1.2.0. Old config files that still carry the field decode fine — the JSON key is silently ignored.

## Local Requirements

**Quota path（阶段一 + 2.4.2 本地回退）**：主路径只需要登录钥匙串存在 `gemini` / `antigravity` 凭据条目（用户在 Antigravity 或 agy CLI 登录过一次即有），Antigravity 无需运行；token 未过期时额度照常工作。凭据缺失/过期（本地时钟 `now >= expiry`）或远端 401 时转入**本地回退**：本机运行 Antigravity（或 agy CLI）且本地 RPC 可用则额度照常显示（IDE 运行期间经 host bridge 分发的新凭据在 language_server 内存中，keychain 陈旧不影响本地 RPC）；无本地后端或本地 RPC 也失败时，卡片显示：

```text
token 已过期：打开 Antigravity 可继续监控额度，重新登录可刷新凭据
```

（打开 Antigravity 即恢复本地回退的数据来源；在 Antigravity 中发起对话或重新登录可刷新 keychain 凭据，远端主路径随之恢复。）

**Local-usage path**（阶段二b：直读 `~/.gemini/antigravity/conversations/*.db`）不再要求本地后端运行：

1. Antigravity / agy CLI **无需运行**——`.db` 由 IDE 懒刷新落盘（见 § Lazy .db write），活动中的会话要等下次 flush 才对 scanner 可见。
2. 版本指纹（`gen_metadata` 首行模型名）不过关的 `.db`（旧版 IDE 会话或损坏文件）计一次失败 + log，保留 last-good 并采纳当前指纹短路，不做任何回退。SQLite I/O 类读失败（权限/锁/EIO）则**不**采纳指纹：保留脏状态下一轮重试（瞬时故障恢复后即读回），连续 3 次才按同款策略有界收敛（见 § Local Token Usage Scanner 优化 6）。
3. The conversation directory is optional: without local session files, quota/account data still works and local-history totals remain empty.

If `~/.gemini/antigravity/conversations/` is empty (CLI-only user with no IDE activity) — the local-usage card section degrades to a placeholder:

```text
正在扫描本地 token 用量…            (扫描进行中，带 mini 进度条)
本机未发现 Antigravity 会话数据      (扫描已完成、0 session)
```

## Discovery Flow（回退路径：2.4.2 恢复，primary 用途仍退役）

> 阶段一（2026-11-08）进程发现从额度**主**路径退役（改远端 Google API），阶段二b
> 整文件删除（本地用量改 `.db` 直读）；**2.4.2 起 `AntigravityProcessDiscovery.swift`
> 按「keychain 过期回退」用途复活**（从 aafbae0^ 恢复，删除了无消费者的
> `defaultMetadataServers()`）：仅当凭据缺失/过期或远端 401 时才 pgrep / lsof / CSRF。
> 本节描述按回退口径恢复为运行时事实；本地用量路径不消费进程发现。

The fetcher scanned for **two** kinds of Antigravity backends and picked the best one (app-embedded `language_server` first, then CLI).

`Antigravity IDE.app` is no longer a supported backend: commands matching `AntigravityFetcher.isUnsupportedIDEAppCommand` (the `Antigravity IDE.app` bundle path, `--app_data_dir antigravity-ide`, or its arch-suffixed `language_server_<suffix>` binaries) are rejected before classification.

### 1. `pgrep -fal language_server` (app-embedded candidates)

For each match, run `classify(command:)`:

- Must contain the bare `language[-_]server` binary as a basename (path-anchored, followed by whitespace or end-of-string; `.exe` allowed) — `Antigravity.app`（无空格，独立应用），路径示例 `/Applications/Antigravity.app/Contents/Resources/bin/language_server`
- The lowercased command must also contain `antigravity` (typically via `--app_data_dir <antigravity path>` or the install path `/Applications/Antigravity.app/...`)
- App processes must additionally have `--csrf_token` in their command line; otherwise the candidate is rejected (tokenless matches are not used — a later valid one is preferred)

### 2. `pgrep -fal agy` / `antigravity-cli` (CLI candidates)

For each match, run `isAntigravityCliBinary(lowerCommand)`:

- Matches `agy`, `agy.exe`, `antigravity-cli`, `antigravity_cli`
- Path-anchored: must appear at start of command or after `/` or `\` (so `stragy` / `imagery` never match)
- CLI does **not** require `--csrf_token`

### 3. Sort + port discovery

Candidates are sorted:

1. `ide` before `cli` (IDE typically has the full quota)
2. Within a kind, by `processRank()`: `workspace + lsp + csrf` > `lsp + csrf` > `csrf` > other
3. Within a rank, by PID (lower first)

For each candidate, `lsof -nP -a -p <pid> -iTCP -sTCP:LISTEN` finds the first `127.0.0.1:<port>` listening socket. The chosen `ServerInfo` carries the CSRF token (if any) and the discovered `kind` for diagnostics.

The consumers of discovery:

- **Quota fetch 回退（2.4.2 恢复）** — 主路径走远端 Google API，不消费进程发现；
  凭据缺失/过期或远端 401 时 `fetchLocalFallback` 经注入 seam 调
  `discoverServerAsync()` 拿单个 server，随后本地 RPC（见 § Local RPCs）。
  `serverStillOwnsEndpoint` 同步复活为本地 POST 前的 TOCTOU 复查（2.4.2 起在
  每次本地 POST 前执行，与原 rawPost 逐 POST 复查口径一致）。
- **Local-usage scan（阶段二b退役）** — 曾经 `defaultMetadataServers()` 收集全部可用候选、scanner 复用一份快照拉所有脏 session 的 metadata 页；阶段二b起 scanner 直读 `.db`，`getTrajectoryMetadata` 与 `defaultMetadataServers` 一并删除（后者无消费者，未随 2.4.2 复活）。

`hasLocalAuth()` deliberately returns `true` without probing (it runs on the menu / settings hot path); the real probe is the async `checkLocalAuth()` → 读一次钥匙串凭据（`AntigravityKeychain.readCredential()`，条目存在且结构可解析即视为可用，token 过期不在此判定）。

## Remote Quota Path (Phase 1, 2026-11-08；2.4.2 增加本地回退)

额度/账号路径的运行时事实（实测依据见文末 § 已验证的远端配额与本地凭据事实）：

**额度抓取决策树**（`AntigravityFetcher.fetch`，2.4.2 定稿）：

1. 读凭据（经注入 seam）→ 解析成功且未过期 → **远端主路径**（本节其余内容，不变）
2. 凭据缺失/过期，或远端配额返回 401（轮询间隙 keychain token 恰好过期）→
   **本地回退**：进程发现（§ Discovery Flow）→ 本地 `RetrieveUserQuotaSummary`
   （§ Local RPCs；`response` 包装形状，group/bucket 归一化与远端共用），回退时
   账号信息用本地 `GetUserStatus`（email/tier，仅 `.full`，可选失败不致命，
   tier 回退链照 § Local RPC Response Shapes）；本地 RPC 成功后不再打远端
3. 回退失败时：凭据缺失或已过期 → `QuotaError.credentialExpired`（新文案，见
   § Local Requirements）；远端 401 起始且无本地后端 → 同样该文案；其余错误
   （远端 401 origin 下本地 RPC 报错、远端非 401 错误等）按现有错误路径上抛；
   取消错误永远原样上抛（AppState/CancellationFilter deferred 路径）

**来源标记 + UI 展示（2.4.3）**：两条成功路径给返回的 `QuotaInfo` 打来源标记
`antigravityQuotaSource: AntigravityQuotaSource?`（`Models/QuotaInfo.swift`）——
远端成功 → `.remoteCloudCode`，本地回退成功 → `.localLanguageServer`；其他
provider 恒 nil，可选字段经 synthesized `decodeIfPresent` 解码，旧持久化数据自动
兼容。`AntigravityFillingMissingMerger` 对来源标记**不**沿用账号/套餐的保留语义：
额度（连同其来源）每一拍都重新抓取，background 拍也采纳本次值——否则 keychain
在两次 full 之间过期转本地回退时，展示行最长滞后一个 full 周期仍显示「远端」；
某拍两路
皆败保留 last-good 时，来源随 `lastSuccess` 整体保留（AppState 直通，与 last-good
同生命周期）。设置窗口 Antigravity pane 在「允许监控刷新 Token」开关下方以只读行
展示当前路径（行标签「额度来源」，文案与布局见 [`spec/ui/settings.md`](../ui/settings.md)
§ Antigravity pane 的「额度来源」行）；设置页「立即刷新」走 `.full`，完成后本行
立即反映当次实际路径。

**凭据**：`AntigravityKeychain.readCredential()` 读登录钥匙串条目
（service=`gemini`，account=`antigravity`，等价 `security find-generic-password -s gemini -a antigravity -w`），
值 `go-keyring-base64:<base64>` → JSON（解析见 `AntigravityCredential`；只消费
`access_token` / `expiry` / `id_token_email`，`refresh_token` 有意不建模、禁止用于任何
网络刷新）。测试侧约定：`AntigravityFetcher` 的 `credentialReader` 注入点是唯一凭据
来源，测试一律注入 fixture（`AntigravityCredentialFixtures`，有效/过期/nil）；且
`AntigravityKeychain.readKeychainValue()` 在 xctest 进程内直接返回 nil——xctest 二进制
每次构建都在变化、不在条目 ACL 内，真实读取会每次弹系统授权框，护栏兜底让漏注入的
测试只走「无凭据」路径（`XCTestConfigurationFilePath` 环境变量 + XCTest 框架加载
双信号识别，SwiftPM `swift test` 不设置该变量，框架加载检测是关键信号）。本地过期判定：`now >= expiry` 即过期，**过期时不发任何远端请求**，转入本地
回退（决策树第 2 步）。本地路径另有三个注入 seam：`localServerDiscovery`（发现）、
`localPostOverride`（本地 POST 传输，headers 已含 Content-Type 与按需 CSRF）、
`localOwnershipChecker`（TOCTOU 复查，默认 `serverStillOwnsEndpoint`）——测试注入
本地 POST override 时必须同时注入发现与复查 stub，绝不触达真实 pgrep / lsof
（`AntigravityLocalFallbackTests` 的 `makeFixture` 是参考写法；
`AntigravityRefreshCadenceTests` 统一注入「无本地后端」发现 stub）。

**请求**（两个端点同头同 UA、body 均为 `{}`）：

```text
POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary
POST https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist      # 仅 .full

Content-Type: application/json
Authorization: Bearer <access_token>
User-Agent: antigravity/hub/<version> (aidev_client; os_type=darwin; arch=arm64)
```

版本取 `/Applications/Antigravity.app/Contents/Info.plist` 的
CFBundleShortVersionString，读不到回退 `2.26.0`（`fallbackHubVersion`）。hub 身份 UA
是实测要求——裸 `antigravity/cli/…` 身份拿不到 Gemini 4 Argon 等分组。

**主机回退**：`daily-cloudcode-pa.googleapis.com` → `cloudcode-pa.googleapis.com` →
`daily-cloudcode-pa.sandbox.googleapis.com`。**仅 401 终止**主机回退并转入本地回退
（2.4.2；无本地后端时与本地过期落到同一 `credentialExpired` 提示）；其余非 2xx 与
传输失败换下一主机，全部失败抛最后一台的错误（不做本地回退）。传输走
`HTTPClient`（Services/Infra，glm/minimax 同款），响应上限 8 MiB
（`standardQuota`），超时复用 `HTTPTimeouts.antigravityRequest`（15s）。

**响应解析**：quota 响应 `{groups:[…]}` 与本地 RPC 同形但**没有 `response` 包装**
（`RetrieveUserQuotaSummaryResponse` 直接解码；本地回退经
`RetrieveUserQuotaSummaryEnvelope` 剥 `response` 包装后复用同一模型），group/bucket
归一化、缺 bucket 跳组、`remainingFraction` 校验等解析逻辑两路共用。tier 响应无
包装，取 `currentTier.name` → `paidTier.name` → `paidTier.id`（首个非空 trimmed 值，
`LoadCodeAssistRemoteResponse.tierName`）；loadCodeAssist 失败不影响主额度（对齐旧
`postOptional` 语义）。email 直接取 Keychain `id_token_email`。本地回退路径的
GetUserStatus / GetLoadCodeAssist 见 § Local RPCs；`planStatus.planInfo` 细节展示名
仅存在于回退路径的 GetUserStatus（远端无对应字段）。

**调度节奏**：quota 每拍（provider 未显式配置间隔时默认 300s）；tier 仅 `.full`
（「次要信息频率」）。本地回退沿用同一节奏（quota 每拍、账号/tier 仅 `.full`）。
`AntigravityFillingMissingMerger` 保留 background 时的上次账号/套餐，full 采用本次
结果（含 nil）——语义与本地 RPC 时代一致。

## Local RPCs（额度回退路径：2.4.2 恢复三件套；trajectory RPC 保持退役）

用量设置的 Antigravity Provider 贡献按共享额度池拆组，适用于 Antigravity、Agy 及 OpenCode 等 Harness。`AntigravityModelKind.pool(forSampleModelName:)` 是样本分类入口：先识别 Argon，再识别 Claude / GPT（含 anthropic / openai 别名），再识别普通 Gemini；展示名来自同类型的 `displayName`，与额度卡一致。同一池的 5h / 周不重复分组。未知模型与留存样本未覆盖的日桶差额进入「未归属额度池」，不按模型估算其差额金额或速度；权威日桶总量保留。额度窗口对未知模型沿用 Gemini 的历史兜底，分组不改变该统计口径。

> 2.4.2 起，本地 RPC `RetrieveUserQuotaSummary` / `GetUserStatus` / `GetLoadCodeAssist`
> 作为**额度回退路径**恢复（仅凭据缺失/过期或远端 401 时调用，见 § Remote Quota Path
> 决策树）；`GetCascadeTrajectoryGeneratorMetadata` 的唯一消费者（scanner）阶段二b改
> 直读会话 `.db`（见 § Local Token Usage Scanner），保持退役。

`RetrieveUserQuotaSummary` runs on every fallback refresh. Account/tier calls
(`GetUserStatus` and `GetLoadCodeAssist`) run only on `.full`, following 「次要信息频率」.
On `.full`, all three run in parallel via `async let`; on `.background`, only quota is
requested. The non-quota calls use `localPostOptional` — they return `nil` on failure
(legacy servers may not support them), and the quota call is the only fatal one.
`AntigravityFillingMissingMerger` retains the previous account/tier during `.background`
while applying fresh quota and `fetchedAt`; `.full` adopts the current metadata, including
nil, so an old account/tier does not survive a new full query. A first refresh with no
previous metadata still displays quota normally. `.background` 回退时账号邮箱回退
Keychain 凭据的 `id_token_email`（有过期凭据时仍可携带邮箱；凭据缺失则为 nil，merger
保留旧值）。

```text
https://127.0.0.1:<httpsPort>/exa.language_server_pb.LanguageServerService/GetUserStatus
https://127.0.0.1:<httpsPort>/exa.language_server_pb.LanguageServerService/GetLoadCodeAssist
https://127.0.0.1:<httpsPort>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary
```

Required request headers:

```http
Content-Type: application/json
x-codeium-csrf-token: <csrf_token>   # only set when server has one
```

Bodies:

- `GetUserStatus`: `{ "metadata": { "ideName": "antigravity", "extensionName": "antigravity", "ideVersion": "unknown", "locale": "en" } }`
- `GetLoadCodeAssist`, `RetrieveUserQuotaSummary`: `{}`

The session trusts localhost TLS for `127.0.0.1` and `localhost`（共享 session 的
`LocalhostTrustDelegate`，远端 Google API 不命中 localhost 分支）。

Response caps and timeouts (`ResponseByteLimits` / `HTTPTimeouts`, enforced by
`CappedDownloader`): every fallback call is capped at **8 MiB** (`standardQuota`);
request timeout 15s, resource timeout 20s. Exceeding the cap cancels the download and
surfaces as `QuotaError.responseTooLarge`.（trajectory RPC 专属的 64 MiB
`antigravityTrajectory` 上限随阶段二b退役一并删除，未随回退复活。）

## Local RPC Response Shapes

> 2.4.2 起，`GetUserStatus` / `GetLoadCodeAssist` / `RetrieveUserQuotaSummary`（quota）
> 的本地形状随额度回退路径恢复为**运行时事实**（触发条件见 § Remote Quota Path
> 决策树）；`GetCascadeTrajectoryGeneratorMetadata` 阶段二b起退役（scanner 改直读
> `.db`），其小节保持历史记录。

### GetUserStatus

Used for account metadata（2.4.2 起为回退路径运行时事实：仅本地回退 `.full` 时调用，
可选失败不致命；失败时邮箱回退 Keychain `id_token_email`）.

Observed response shape:

```json
{
  "userStatus": {
    "email": "alice@example.com",
    "userTier": { "name": "Free" },
    "planStatus": {
      "planInfo": {
        "planDisplayName": "Pro Max",
        "displayName": "Pro Plan",
        "productName": "Antigravity Pro",
        "planName": "pro-monthly",
        "planShortName": "Pro"
      }
    }
  }
}
```

Tier name resolution (first non-empty wins):

1. `userStatus.userTier.name` (trimmed)
2. `userStatus.planStatus.planInfo.planDisplayName` (trimmed)
3. `userStatus.planStatus.planInfo.displayName`
4. `userStatus.planStatus.planInfo.productName`
5. `userStatus.planStatus.planInfo.planName`
6. `userStatus.planStatus.planInfo.planShortName`
7. `GetLoadCodeAssist.currentTier.name` (fallback for older servers)

Empty / whitespace-only strings are treated as missing at every step.

Email is `userStatus.email` trimmed; treated as missing if empty/whitespace.

| Response field | Model field |
|---|---|
| `userStatus.email` | `QuotaInfo.accountEmail` |
| `userStatus.userTier.name` (or fallbacks above) | `QuotaInfo.planLabel` |

### GetLoadCodeAssist

Used for tier name fallback when `GetUserStatus` is missing or incomplete
（2.4.2 起为回退路径运行时事实：仅本地回退 `.full` 时调用，可选失败；本地响应经
`LoadCodeAssistLocalEnvelope` 剥 `response` 包装，内层复用远端
`LoadCodeAssistRemoteResponse` 模型）.

Observed response shape:

```json
{
  "response": {
    "currentTier": {
      "id": "free-tier",
      "name": "Free"
    }
  }
}
```

| Response field | Model field |
|---|---|
| `response.currentTier.name` | `QuotaInfo.planLabel` (only if no value from `GetUserStatus`) |

### RetrieveUserQuotaSummary

Observed response shape（本地响应带 `response` 包装，`RetrieveUserQuotaSummaryEnvelope`
剥包装后与远端共用 `RetrieveUserQuotaSummaryResponse` 及其下游归一化；2.4.2 起为
回退路径运行时事实）:

```json
{
  "response": {
    "groups": [
      {
        "displayName": "Gemini Models",
        "buckets": [
          {
            "bucketId": "gemini-weekly",
            "window": "weekly",
            "remainingFraction": 0.846885,
            "resetTime": "2026-07-11T16:50:25Z"
          },
          {
            "bucketId": "gemini-5h",
            "window": "5h",
            "remainingFraction": 1,
            "resetTime": "2026-07-08T13:09:12Z"
          }
        ]
      },
      {
        "displayName": "Claude and GPT models",
        "buckets": [
          {
            "bucketId": "3p-weekly",
            "window": "weekly",
            "remainingFraction": 1,
            "resetTime": "2026-07-15T08:09:12Z"
          },
          {
            "bucketId": "3p-5h",
            "window": "5h",
            "remainingFraction": 1,
            "resetTime": "2026-07-08T13:09:12Z"
          }
        ]
      },
      {
        "displayName": "Gemini 4 Argon",
        "description": "For paid Pro plans, Argon quota is separate. Higher Argon quota (included as part of the larger Gemini quota bucket) is available on Ultra plans.",
        "buckets": [
          {
            "bucketId": "gemini-argon-wtu-weekly",
            "displayName": "Gemini 4 Argon Weekly Limit",
            "window": "weekly",
            "remainingFraction": 1,
            "resetTime": "2026-07-15T08:09:12Z"
          }
        ]
      }
    ]
  }
}
```

Current parser behavior:

| Response field | Model field |
|---|---|
| `groups[].displayName` | normalized synthetic model id, then mapped back to display names |
| `buckets[].remainingFraction` | percent = `fraction * 100` |
| `buckets[].resetTime` | `intervalResetsAt` or `weeklyResetsAt` |
| `window == "5h"` | interval window |
| `window == "weekly"` | weekly window |

`bucket(for:in:)` resolves a window by `window`（大小写不敏感）**或** by a `bucketId` that
contains the window string, so responses carrying only `bucketId: "gemini-5h"` /
`"3p-weekly"` still resolve. Group normalization looks at `displayName`, `description`,
and `buckets[].bucketId` / `buckets[].displayName`: an `argon` hit → `gemini_argon`
(checked **before** generic `gemini`), otherwise a `gemini` hit → `gemini_models`,
otherwise a `claude` / `gpt` hit → `claude_and_gpt_models`, otherwise the raw
`displayName` is kept. Parsed groups are sorted in fixed order:
`gemini_models (0) < gemini_argon (1) < claude_and_gpt_models (2) < other (3)`.

Failure is per group: a group whose `remainingFraction` is missing, non-finite or
outside `[0, 1]` is skipped with a `logWarn` (mirroring `localPostOptional`'s
partial-availability semantics) and the remaining groups still produce a card;
only when **no** group survives does the fetcher throw.

Window status is normalized from bucket presence: an existing bucket maps to
`QuotaWindowStatus.present`, including `remainingFraction = 0`; a missing bucket maps to
`.absent`. The shared UI and health logic never interprets provider-specific raw status values.

Current normalized internal names (display names match the API-returned `displayName` across all groups):

| Group | Internal `modelName` | Display name |
|---|---|---|
| `Gemini Models` | `gemini_models` | `Gemini Models` |
| `Gemini 4 Argon` | `gemini_argon` | `Gemini 4 Argon` |
| `Claude and GPT models` | `claude_and_gpt_models` | `Claude and GPT models` |

Returned `ModelQuota` values keep count fields at `0`, because the current local RPC only exposes fractions and reset times.

### GetCascadeTrajectoryGeneratorMetadata（已退役，历史记录）

> 阶段二b起 scanner 不再调用该 RPC；逐调用 token/模型/时间戳改由 `.db` 直读提供
> （`gen_metadata` ↔ `steps` 连接，见 § Token & model data ARE in `.db` `gen_metadata`）。
> 以下解析口径记录保留为历史。

Used by `AntigravityLocalUsageScanner` to extract per-event token usage for a single session (cascade).

Request body:

```json
{
  "cascadeId": "<sessionId>",
  "includeMessages": false
}
```

Response shape (field names may vary between Antigravity versions; parser walks the tree recursively and matches key names against regex patterns). `chatModel` additionally carries the per-call native durations (Protobuf Duration strings):

```json
{
  "generatorMetadata": [
    {
      "timestamp": "2026-07-15T10:30:00Z",
      "model": "gemini-2.5-pro",
      "chatModel": {
        "timeToFirstToken": "11.669597334s",
        "streamingDuration": "0.891494208s"
      },
      "inputTokens": 100,
      "outputTokens": 50,
      "cacheReadTokens": 20,
      "cacheWriteTokens": 5,
      "reasoningTokens": 10,
      "totalTokens": 185,
      "stepIndices": [58, 59]
    },
    {
      "timestamp": "2026-07-15T10:31:12Z",
      "model": "claude-sonnet-4.5",
      "inputTokens": 200,
      "outputTokens": 80,
      "cacheReadTokens": 30,
      "cacheWriteTokens": 0,
      "reasoningTokens": 0,
      "totalTokens": 310,
      "stepIndices": [60, 61]
    }
  ]
}
```

Field name resolution (case-insensitive, snake_case or camelCase both accepted):

| Detected name pattern | Mapped to |
|---|---|
| `^(input\|prompt).*token` (covers `inputTokens` and `input_tokens`) | `inputTokens` |
| `^(output\|completion).*token` (covers `outputTokens` / `output_tokens`) | `outputTokens` |
| `cache.*read.*token` (covers `cacheReadTokens` / `cache_read_tokens`) | `cacheReadTokens` |
| `cache.*write.*token` (covers `cacheWriteTokens` / `cache_write_tokens`) | `cacheWriteTokens` |
| `(reasoning\|thinking).*token` (covers `reasoningTokens` / `reasoning_tokens`) | `reasoningTokens` |
| `totalTokens` or `total_tokens` | `totalTokens` (used or ignored depending on how many component patterns matched — see "Total caliber" below) |
| `stepIndices` or `step_indices` | `stepIndices` (used for best-effort turn inference) |
| `apiProvider` or `api_provider` | model fallback when no higher-priority model field is present |

Matching is `regularExpression` `range(of:)` (substring semantics, **no** trailing
anchor) on the lowercased key, so the same pattern serves camelCase and
snake_case. Only non-negative integers count; a match is recorded even when the
value is `0` (field present = matched — see "Total caliber").

Per token category the parser keeps the **maximum** value found anywhere in the
tree instead of summing layers: several RPC versions repeat the same counters in
the wrapper and in a nested usage object, and one generator-metadata entry is a
single LLM call, so summing would double-count. Recursion is depth-capped at 32.

**Timestamp** candidates are a strict key whitelist, ranked by semantics (so
`duration` / `latency` / `time_to_first_token` never participate) and then by
nesting depth: `timestamp` / `timestampMs` / `timestampSeconds` (0) >
`eventTimestamp` (1) > `createdAt` (2) > `created` (3) > `time` (4). Epoch numbers
above 20 000 000 000 are read as milliseconds, and every candidate date must fall
in `[2000-01-01, 2100-01-01)`.

Model candidates are ranked the same way — key semantics first, nesting depth
second, so `metadata.chatModel.model` beats an outer descriptive field:
`model` (0) > `response_model` (1) > `model_name` (2) > any other key containing
`model` (3) > `apiProvider` (4). Values prefixed with `MODEL_PLACEHOLDER_` are
dropped (so unrelated strings such as placeholders are not misread as the model
name); remaining ties at the same priority and depth break lexicographically, so
JSON field order never decides.

**Per-call duration (`UsageEvent.durationSeconds`)**. Each `chatModel` natively
carries two Protobuf Duration strings, `timeToFirstToken` + `streamingDuration`
(present on 100% of 60,373 events measured across 271 local sessions; their sum
matches the `steps` table `DONE − createdAt` to sub-millisecond). The parser
extracts both with a dedicated key match (`AntigravityFetcher.nativeCallDurationComponent`):
the key is normalized to letters only (camelCase / snake_case / kebab-case
alike) and fully matched against `timetofirsttoken` / `streamingduration` — the
same normalization `timestampPriority` uses, so these keys deliberately never
enter the timestamp whitelist and never pollute any token regex (the values are
strings such as `"11.669597334s"`, parsed by stripping the trailing `s`; bare
numbers are accepted as seconds). Duplicate carries across wrapper layers take
the max, mirroring the token strategy. The event's `durationSeconds` is the sum
of the two components and is `nil` when both are missing, a value is
non-positive / unparseable, or the sum is ≤ 0. It flows through
`AntigravityLocalUsageAggregation.makeSample` into
`LocalTokenUsageSample.durationSeconds` (the token/s numerator/denominator
contract in `spec/accounting.md`); the `.distantPast` fallback sample for a
timestampless event deliberately carries no duration.

Events with no token data at all (just a timestamp + model) are skipped — the
guard is `finalTotal > 0 || cacheWriteTokens > 0`, so an entry carrying only
cache-write bookkeeping still counts while a pure metadata entry does not.

**Total caliber.** `cacheWrite` is bookkeeping and never counts toward the exposed
total. Some RPC versions fold it into `totalTokens`, so the server value cannot be
trusted blindly; the *reverse* mistake is just as bad — after a field rename only a
subset of the four component patterns may still match, and trusting the component
sum then reports a systematically low total. The rule is therefore three-way on the
number of component patterns that **matched** (a match means the field was read, even
when its value is 0):

| Component hits | `totalTokens` used | Why |
|---|---|---|
| all four | no — component sum wins | the sum excludes `cacheWrite`; server values may not |
| some (1–3) | yes, when non-zero | the sum is known-incomplete; the server is authoritative. If the server total is absent or 0, fall back to the sum rather than scoring a real event as 0 |
| none | yes | the components carry nothing; this is the original behavior |

A partial-hit event carries its missing component names on
`UsageEvent.missingComponents`; the scanner aggregates them per session and logs one
summary line per distinct set (persisted in `partialHitWarnedBySession`) instead of one
line per event, so a renamed field cannot flood the rotating log.

**Timestampless events**: the scanner first tries to recover a missing timestamp for
SQLite sessions from the matching `steps.step_type=15` metadata selected by
`stepIndices`. Token values still come only from RPC. If no fallback is available
(including `.pb` sessions), the event cannot be assigned to a local calendar day and
is excluded from daily tokens, turns, rounds, and samples. `eventCount` uses the same
population — it counts only events that successfully entered the daily statistics
(`AntigravityLocalUsageScanner.accountedEventStats`).

### Incremental trajectory metadata（已退役，历史记录）

> 阶段二b起 offset 增量拉取与下文 § Bounded convergence 的全部状态机随 RPC 数据源
> 一起退役——本地读便宜且确定性，脏了就全量重读。本节保留为历史。

The local `language_server` implementation exposes more request fields than the
current monitor sends. The request accepted by
`GetCascadeTrajectoryGeneratorMetadata` is:

```json
{
  "cascadeId": "<session-id>",
  "generatorMetadataOffset": 0,
  "includeMessages": false
}
```

`cascadeId` is required. `generatorMetadataOffset` is an offset into the
`generatorMetadata` sequence, not a generic `stepIndex` and not a timestamp. On a
local Antigravity 2.15.1 instance, the same cascade returned:

| `generatorMetadataOffset` | returned metadata entries |
|---:|---:|
| 0 | 69 |
| 1 | 68 |
| 10 | 59 |
| 68 | 1 |
| 69 | 0 |
| 1000 | 0 |

This confirms suffix-style incremental retrieval: after successfully consuming
`N` raw generator metadata entries (including entries that may be filtered out of
the app's `UsageEvent` list), the next request can use
`generatorMetadataOffset: N` to retrieve only later entries. The monitor uses this
field after the cached mtime/size/WAL fingerprint marks a session dirty, so
append-only changes fetch only the suffix.

The same local service also exposes offset-based companion RPCs:

| RPC | request range field | verified behavior |
|---|---|---|
| `GetCascadeTrajectory` | full trajectory request | returns trajectory plus total step/metadata counts |
| `GetCascadeTrajectorySteps` | `stepOffset` | suffix retrieval; observed 147 entries at 0 and 47 at 100 |
| `GetCascadeTrajectoryExecutorMetadatas` | `executorMetadataOffset` | offset-based executor metadata retrieval |
| `GetAllCascadeTrajectories` | `excludeSubtrajectories` | trajectory summaries, no metadata offset |
| `GetUserTrajectory` | `trajectoryId` | single trajectory lookup |

No evidence has been found for timestamp ranges, `pageToken`, `pageSize`, `limit`,
`since/until`, or an independent delta token. Strings such as
`GetGeneratorMetadatasPageBounds` and `GetStartGeneratorMetadataIndex` were found in
the binary, but have not been confirmed as public RPC endpoints.

These observations were made against the locally installed arm64 Antigravity
`2.15.1` (`/Applications/Antigravity.app/.../language_server`) using its binary
descriptors and live localhost RPC responses. This is a private, version-sensitive
interface; future Antigravity versions may change field names or semantics.

#### Revised monitor strategy（已退役，历史记录）

> 阶段二b起 offset 增量策略整体退役（本地直读便宜且确定性，脏了就全量重读）。
> 保留为历史。

The monitor used offset-based fetching before generic JSON streaming:

1. Persist, per session, the number of successfully accounted generator metadata
   entries (and enough metadata to detect a reset/rewrite).
2. On a dirty session, request `generatorMetadataOffset` from that count instead of
   requesting the full sequence.
3. Append only the returned suffix to the session's aggregate/sample state, with
   a full fallback when the session or WAL shrinks. An empty suffix on a
   non-shrinking dirty file keeps the session dirty and is retried under a 30s
   throttle; after two consecutive empty suffixes the session escalates to an
   offset=0 verification full and can converge as a success — see
   "Bounded convergence" below.
4. Keep `includeMessages: false`; message bodies are not needed for token, model,
   timestamp, or turn/round accounting.
5. Retain a bounded response cap and adaptive concurrency. The response envelope is
   walked incrementally and each generator-metadata entry is decoded independently,
   so a large full response does not create a second full `[AnyJSON]` tree.

The offset must be treated as a raw generator-metadata count, not derived from the
number of parsed usage events or the maximum `stepIndex`. The persisted offset must
advance by the returned raw entry count, and only after the suffix has been parsed,
aggregated, and saved successfully.

#### Bounded convergence（已退役，历史记录）

> 阶段二b起全部打击/收敛状态机（`consecutiveEmptySuffixes` / `lastEmptySuffixAt` /
> `emptyFullStrikesBySession` / `zeroAccountedFullStrikesBySession` /
> `offsetRegressionStrikesBySession` / `calendarRebuildPendingSessions` /
> `partialHitWarnedBySession` 与 per-session 的 offset 字段）随 RPC 数据源退役，
> index v9 不再有这些字段。本地直读的失败收敛按错误类别两路：probe 结构化
> 不兼容（表缺失/乱数据/无模型名/非 SQLite）在失败轮内即记一次失败并采纳当前
> 文件指纹（保留 last-good），下一轮指纹已匹配、不再重读；SQLite I/O 类可重试
> 失败不采纳指纹、下一轮自然重试，连续 3 次后采纳指纹有界收敛（条目可选字段
> `consecutiveReadFailures` 计数，成功/收敛即清零）——现行语义见 § Local Token
> Usage Scanner 优化 6。本节保留为历史。

Two server-side failure modes used to be unbounded retry loops that pinned
`failedSessionCount ≥ 1` forever and (via the all-or-nothing calendar signature)
dragged every session through full-plan RPC rounds each scan:

- **A. Empty suffix forever**: the file fingerprint changed (IDE touching mtime, a
  non-usage write) but the server's metadata total never moved, so the same
  suffix offset returned empty on every retry.
- **B. Zero-metadata full forever**: a full result with `metadataEntryCount == 0`
  (wrong server/workspace, or a language server restart that lost trajectory
  memory) is not trustworthy, so the session never got an index entry / stayed
  dirty and re-ran the full RPC every scan.

Both are now finite windows with terminal states. The persisted state is additive
and optional in `index.json` (version 8 since the durationSeconds / thinking-caliber
rebuild — unknown keys are ignored by old
readers, and new fields decode with defaults via `decodeIfPresent`):

| New state | Where | Meaning |
|---|---|---|
| `consecutiveEmptySuffixes` | `sessions[id]` | consecutive empty suffix responses |
| `lastEmptySuffixAt` | `sessions[id]` | 30s retry throttle for empty suffixes (existed before) |
| `emptyFullStrikesBySession` | top level | per-session consecutive zero-metadata full count |
| `zeroAccountedFullStrikesBySession` | top level | per-session consecutive "page had raw metadata but zero accountable events" count (full **and** incremental pages) |
| `offsetRegressionStrikesBySession` | top level | per-session consecutive "non-verification full page reported fewer raw entries than the cached offset" count |
| `calendarRebuildPendingSessions` | top level | sessions whose last-good daily buckets are still grouped under a superseded calendar |
| `partialHitWarnedBySession` | top level | per-session set of already-logged missing-component sets (log de-duplication only) |

All five are optional top-level maps decoded via `decodeIfPresent`, so an older
`index.json` simply decodes without them. The three strike counters are written on the
paths that accumulate a strike, which `continue` **before** `sessions[id]` is created —
a brand-new session whose very first page comes back empty writes a strike count and
returns without ever creating an entry. Session removal must therefore consider the
union of `sessions.keys` and all of these maps' keys — see `trackedSessionIDs(in:)`.
Considering `sessions.keys` alone leaves a strike count behind forever; the same id
reappearing then resumes from the stale count, converges one or two rounds early into a
terminal empty entry, and silently drops that fingerprint cycle's data. The other two
maps are included in the union defensively; they are written in rounds that also create
the session entry.

**A. Empty suffix → offset=0 verification full.** Empty suffixes keep the session
dirty under the existing 30s throttle and increment `consecutiveEmptySuffixes`.
At 2 (`emptySuffixVerificationThreshold` — two suffixes across at least one
throttle window, giving a lagging server two chances to catch up) the next dirty
plan is an offset=0 *verification* fetch (`DirtySessionPlan.isVerification`; on
the wire it is an ordinary full request):

- `metadataEntryCount == cached.generatorMetadataOffset` → "确无新事件" confirmed.
  The scan **converges as a success**: the file fingerprint (mtime/size + WAL)
  advances to the current file, `consecutiveEmptySuffixes` / `lastEmptySuffixAt`
  reset, `failedSessionCount` is *not* incremented, and the cached daily /
  samples / offset state is untouched. The re-delivered events are deliberately
  discarded — they are already accounted for, and re-aggregating would
  double-count.
- any other non-zero total (server caught up or truncated) → the normal full
  path runs: the offset=0 refetch re-aggregates and replaces the day buckets
  wholesale, which is correct by construction.
- zero entries → handled by strike rule B below.

**B. Zero-metadata full → 3-strike terminal state.** A full (or verification)
page with `metadataEntryCount == 0` retains last-good data and increments
`failedSessionCount` (it genuinely did not succeed), and increments
`emptyFullStrikesBySession[sessionId]`. At 3 (`zeroMetadataFullStrikeLimit`) the
session converges as a success for that round:

- **with last-good data** (`sessions[id]` exists): the entry is rewritten with
  the *current* file fingerprint while `eventCount`, `generatorMetadataOffset`,
  daily buckets and samples keep their last-good values — zero metadata never
  clears user-visible history. (For migrated v6/v7 entries `offset` may stay 0;
  the next real file change then takes the full-plan path, the correct re-fetch
  form.)
- **with no data at all**: a terminal empty entry (`eventCount: 0`, `offset: 0`,
  current fingerprint, empty samples) is written so the session stops being
  dirty.

Any later non-zero metadata result clears the strike count, and a converged
session whose file changes again is planned normally (suffix when
`generatorMetadataOffset > 0`, full otherwise), so real new events are picked
up as usual.

**Residual risk for A (bounded, accepted):** if the server publishes the events
only *after* the verification full and the file never changes again, those
events stay missing until any later file change, the settings-page hard full,
or a calendar rollover rebuild re-triggers a scan. The same bounded acceptance
applies to a B-converged session: any file change re-plans it normally.

**C. Page with raw metadata but zero accountable events → 3-strike terminal state.**
A page can report a non-zero `metadataEntryCount` while producing **no** accountable
event — every entry fails to parse (a renamed / relocated token field), or every event
lacks a recoverable timestamp. The trustworthiness gate is deliberately keyed on the
*raw* count (raw entries may legitimately carry no token fields, and the offset must
advance by raw count), so this case slips past it.

It must therefore be caught before the full page replaces anything. The check is
hoisted **above the full/incremental fork** and covers both page types:

- full page: the wholesale replacement of `dailyBySession[id]` / `samplesBySession[id]`
  would zero the session's visible history, and the offset would then jump past the
  whole page so no incremental fetch ever revisits it;
- incremental page: the merge is additive, but the offset would still advance past
  entries that were never accounted, so a later parser fix could never recover them.

Rounds 1 and 2 count as failures (`failedSessionCount` increments, last-good is kept
untouched) and bump `zeroAccountedFullStrikesBySession[id]`. At 3
(`zeroAccountedFullStrikeLimit`) the session converges for the round: the current file
fingerprint is adopted while `eventCount`, `generatorMetadataOffset`, daily buckets and
samples keep their last-good values — and the offset is **deliberately not advanced**,
so a later file change re-fetches the same page with a possibly-fixed parser. With no
cached entry at all, a terminal empty entry is written instead. A page that produces
accountable events clears the count on both page types.

What does **not** clear the count: a transport failure, and an empty suffix page. Both
carry no evidence about parse quality — the first never delivered a page, the second
delivered zero raw entries to parse. Letting either reset the streak would let a
session alternating between "raw non-zero but unparseable" and "empty suffix" reset the
count forever, never reach the limit, keep `failedSessionCount > 0` permanently, and so
block the signature forever — exactly the invariant the strike mechanism exists to
protect. That alternation is the natural shape of a real failure: a session with a
renamed token field is "unparseable" while the model is in use and "empty" while idle,
so an intermittently used session would never converge. The recovery evidence is a page
that produces accountable events — plus the verification-convergence page, which is an
offset=0 full fetch confirming the server total is unchanged; its events are already
accounted for and discarded, so the parse result does not bear on the "no new events"
conclusion and it does count as evidence.

**D. Offset regression → 3-strike terminal state.** A full or verification page whose
`metadataEntryCount` is *smaller* than the cached `generatorMetadataOffset` means the
server lost data, truncated, or answered from a different workspace. Treating it as a
normal full replacement would overwrite good local history with a smaller aggregate and
then advance the offset backwards. Such a page counts as a failure and bumps
`offsetRegressionStrikesBySession[id]`; at 3 the session converges as a success with the
current fingerprint and the full last-good state (including the offset) preserved. Two
cases never reach this check because an earlier branch already settled them: a
zero-entry page is strike rule B, and a verification page whose count *equals* the
cached offset converges as "no new events" in rule A. Incremental pages are excluded
outright — they consume by raw count and have no count-versus-offset relation to
reconcile. A regression page is rejected before any parsing or aggregation, so it also
clears the zero-metadata and zero-accountable counts for the session.

**E. Why `calendarSignature` needs no per-session signature.**（历史口径，阶段二b
签名推进的唯一阻塞源收敛为枚举不完整，读失败按错误类别两路有界收敛——不兼容当轮
采纳指纹、可重试 I/O 连续 3 次后采纳指纹） The signature
still advances only on a round with `failedSessionCount == 0` (all-or-nothing;
incomplete directory enumeration correctly keeps blocking it). Every persistent
failure source above is now bounded — empty suffixes escalate to verification
after 2 attempts, and zero-metadata fulls, zero-accountable pages and offset
regressions all converge after 3 strikes — and converged
sessions no longer count as failures. So the number of rounds in which
`failedSessionCount > 0` (and therefore *all* sessions re-run the full plan at
batch size 2) is finite, typically ≤ 3, after which the signature advances and
the scanner returns to cheap dirty/offset mode. RPC transport errors and
incomplete enumeration remain ordinary retryable failures by design. A
per-session signature scheme would add a cache migration without buying
anything this bound does not already provide.

## Local Token Usage Scanner

`AntigravityLocalUsageScanner` runs after a settled Provider batch, independent of quota
refresh success. The startup reconcile is a cache-assisted Full Scan: it enumerates every
session and validates fingerprints; unchanged sessions reuse `antigravity.json` without
opening their `.db`. Manual refresh, wake-up, interval refresh and natural-day rollover
use dirty mode after startup. The settings page exposes a separate explicit hard-full
action for rebuilding every non-empty session from its `.db` when the cache is suspect.
The source watcher **stays attached during a scan** (`LocalUsageScannerBase.startScan`
starts it rather than stopping it; a mid-scan event keeps the source dirty for the next
round).

阶段二b（2026-11-08）数据源接线：it scans the (single) supported conversation directory,
accepts **only `.db`** session files (`.pb` 完全忽略)，compares file metadata
(mtime/size plus WAL mtime/size) against a cached index, and re-reads only dirty
sessions via `AntigravitySessionDBReader.probe → readCalls + readUserTurnSteps`（全量读，
本地 db 毫秒级；不再有 offset/suffix 增量）。逐调用 token/模型/时间戳/轮次全部来自
`.db`（`gen_metadata` ↔ `steps` 按 `steps.idx == f20.last_step_index + 1` 连接）；
steps.metadata 缺失（无时间戳）的 Call 沿用旧口径：排除出 daily/turns/rounds/samples。
scanner 不发任何网络请求、不依赖 Antigravity 进程运行。

### Storage layout

```
~/.gemini/antigravity/
├── conversations/                         ← Antigravity native (read-only input)
│   └── {sessionId}.db                      ← discovered/fingerprinted + probe/version-gated 直读
│                                            （`.pb` 自阶段二b起完全忽略：不发现、不指纹、不进 session 集）
└── ...                                    ← scanner 不在客户端目录写缓存

~/Library/Application Support/LLM-monitor/token-monitor/
└── antigravity.json                        ← top-level state and per-session cache (fast load)
```

The one write the scanner still performs inside the client directory is a cleanup
of the pre-v4 leftovers: v3 used to write per-session `rpc-cache/v1/<session>/`
JSONL under `~/.gemini/antigravity/.token-monitor`, which the root migration to
`token-monitor/` never carried over. `ensureCacheDirectoriesExist` deletes that
tree idempotently on every scan (a failure is logged, never fatal).

`index.json` schema（v9，阶段二b）：

```json
{
  "version": 9,
  "lastScannedAt": "2026-07-15T02:00:00Z",
  "calendarSignature": "gregorian|Asia/Shanghai",
  "sessions": {
    "41272769-fe7d-4802-a174-b5b28b526ade": {
      "mtimeMs": 1752542400000.0,
      "sizeBytes": 8421376,
      "walMtimeMs": 0.0,
      "walSizeBytes": 0,
      "fetchedAt": "2026-07-15T02:00:00Z",
      "eventCount": 50
    }
  },
  "dailyBySession": {
    "41272769-fe7d-4802-a174-b5b28b526ade": {
      "2026-07-15": { "dayStart": "...", "inputTokens": 1000, "totalTokens": 1800 }
    }
  },
  "samplesBySession": {
    "41272769-fe7d-4802-a174-b5b28b526ade": [
      { "completedAt": "...", "promptID": "...", "inputTokens": 1000, "outputTokens": 800, "durationSeconds": 12.561091542 }
    ]
  }
}
```

v9（2026-11-08，阶段二b）：数据源从本地 RPC 切换为 `.db` 直读，逐事件增量状态机
整体退役——sessions 条目精简为 `{mtimeMs, sizeBytes, walMtimeMs, walSizeBytes,
fetchedAt, eventCount}`（外加可选 `consecutiveReadFailures`：连续可重试读失败
计数，见下文优化 6 的有界收敛；健康态 nil 不落盘，合成 Codable 经
`decodeIfPresent` 兼容本版本更早落盘的 v9 缓存），顶层
`emptyFullStrikesBySession` / `zeroAccountedFullStrikesBySession` /
`offsetRegressionStrikesBySession` / `calendarRebuildPendingSessions` /
`partialHitWarnedBySession` 全部删除。
**不继承 v8 任何数据**：加载 v8 及更早索引一律重置为空缓存（`ScannerIndexIO` 打
一行「索引版本过旧，重置索引全量重建」），daily/samples 全清，首个扫描轮对全部
session 全量直读重建；`calendarSignature` 冷重建守卫保留。

v8（2026-10-25，历史）：样本新增 `durationSeconds` 且思考口径修正（raw `outputTokens`
含思考，catalog `.reasoningIncluded`）。

`calendarSignature` (`LocalUsageCalendarSignature.make`: `calendar.identifier|timeZone.identifier`)
is optional and gates the cold rebuild: a signature that no longer matches the
current calendar forces a full re-read for every session, and a cold start refuses
to restore cached day buckets while it differs. 签名推进的**唯一阻塞源是枚举不完整**
（`listing.isComplete == false`）：读失败的 session 按错误类别两路有界收敛（不兼容
当轮采纳指纹；可重试 I/O 连续 3 次后采纳指纹），收敛后下轮指纹已匹配、不再重读，
失败状态因此不阻塞签名——否则一个永久不兼容的 session 会让失败永远钉住、
每轮都因 calendarChanged 冷重建全部 session（正是退役的打击状态机要切断的循环）。

`dailyBySession` keeps each session's per-day token breakdown, while `samplesBySession` keeps recent per-event samples. A changed session replaces only its own entries; unchanged sessions remain cached. The source events are not persisted as JSONL — they are re-read from the session `.db` whenever the file fingerprint is dirty. Day buckets are retention-bounded: before each index write-back, buckets strictly older than the 8-day window (`dayStart < now - 8d`, the same predicate as `samplesBySession`) are pruned, along with sessions whose buckets are all pruned. The only consumers of day buckets are the today value and the 7-day window (`computeGlobalDaily` → `filterLast7Days`), and per-session `eventCount` lives in `sessions`, so pruning never changes any reported number.

### Optimizations

The scanner does heavy work in the background and is built for low-cost re-runs:

1. **File + WAL fingerprint diff**: each scan starts with directory/resource metadata only. A `.db` session is re-read when its file mtime/size or WAL mtime/size changes. Startup full is cache-assisted; only the explicit settings-page hard full bypasses this check for every non-empty session. Antigravity also leaves **0-byte placeholder cascades** whose mtime still moves during IDE housekeeping: those only get their fingerprint refreshed locally（不开库）and re-enter the dirty set once the file/WAL actually grows.
2. **Per-session incremental aggregation**: `index.dailyBySession` stores each session's day-keyed breakdown. When a session changes, only that session's cached entry is replaced — other sessions' entries are untouched.
3. **In-flight dedup**: `LocalUsageScannerBase.scan(mode:)` never runs two scans at once — a request arriving while a previous scan is in flight is merged into the pending slot (stronger mode wins), and the in-flight scan's completion immediately runs one more round with the merged mode. The old scan still publishes its own result via `@Published`.
4. **Off-main-thread I/O**: the scanner class is `@MainActor` for state mutation, while the heavy pipeline lives in `nonisolated static performScanPure(...)` and runs through the non-actor-isolated `LocalUsageScanRunner`. It inherits caller cancellation and only assigns the result back on MainActor.
5. **Bounded 直读并发**: dirty sessions are read in batches of four concurrent
   `SQLiteTempCopy` reads（副本按文件大小占内存，小批量归约控制峰值；本地读毫秒级，
   批间串行不构成瓶颈）。Results are reduced in small batches so calls from all
   sessions are not retained until the final read.
6. **Failure is non-fatal, and bounded（两路收敛）**: 读失败按错误类别区分收敛
   策略，两条路径都计一次 `failedSessionCount`（UI 可见）、本轮继续扫其余、
   绝不清空 last-good daily/samples/eventCount：
   - **probe 结构化不兼容**（gen_metadata 表缺失/空表/乱数据/无模型名/非
     SQLite 文件，`.incompatible`）：由文件字节内容决定、同字节重探结果恒定，
     当轮采纳当前文件指纹——下一轮指纹已匹配、不再重读，文件再变化时自然
     重新入账。
   - **可重试 I/O 故障**（SQLite 打开/拷贝/查询类：权限、锁、EIO 等，
     `.retryable`）：**不采纳指纹**，下一轮自然重试——瞬时故障（如实测撤销
     db 读权限再恢复，mtime/size 不变）恢复后即可读回，不会把会话钉在漏计
     状态。有界收敛由条目可选字段 `consecutiveReadFailures` 承载：任何成功
     与指纹收敛都清零，连续
     `retryableReadFailureConvergenceLimit`（3）次失败后按不兼容同款策略采纳
     当前指纹收敛并保留 last-good，防永久故障把同一份字节变成每轮重读、
     `failedSessionCount` 永远钉在 ≥1（freshness 永不 fresh）。首读即失败的
     新 session 写「当前指纹 + 计数」条目，重试由计数条件驱动（否则无缓存
     分支会每轮重读、计数永无机会累计）。
   两条路径下失败轮数都有界，签名只在枚举不完整时被阻塞。
7. **In-flight / offline tolerance**: if every entry in `defaultConversationsDirs` doesn't exist (CLI-only or no IDE activity), `listDBFilesWithStatus()` returns an empty file set (explicitly-missing directory is not an error) and the scan completes cleanly with `sessionCount: 0` — no exception. Permission / TCC / transient I/O failures instead mark the listing `isComplete == false`: already-discovered sessions are still refreshed, but no session may be declared deleted and the calendar signature is held back.
8. **Index parse failure recovery**: a corrupted `index.json` is logged + reset to `.empty` rather than failing the whole scan.
9. **Pipeline serialization via `AsyncMutex` + `lastCommittedGeneration`**: 整个 `performScanPure` 包在 `try await pipelineMutex.withLock { ... }` 里, 旧 worker 跑完整个 pipeline 才让新 worker 开始. 配合 `lastCommittedGeneration` 守门, cancel+rescan 期间旧 worker 即使晚到 mutex, `startedGeneration < lastCommittedGeneration` 时也跳过 saveIndex, 杜绝 cache revert. **P1 invariant**: read + write-to-disk + update 全在 mutex 内 atomic (跨 @MainActor hop `await scanner.read.../write...` 持锁执行), 不能拆到 mutex 外. 详见 `spec/local-usage-reconcile.md` "Scanner Concurrency (本地用量 scanner 的并发模型)" 段.
10. **Generation 守门防 UI flicker**: `runScan` 用 `startedGeneration` 跟 `latestGeneration` 比对, 不一致就丢弃 in-memory result, defer 状态清理也按 generation 守门（`if startedGeneration == self.latestGeneration` 才清 isScanning / inFlightTask）. 防止 cancel+rescan 期间旧任务的 defer 把 UI 的"扫描中"状态清掉.
11. **取消不污染 lastError**: `performScanPure` 的 catch 用 `CancellationFilter.shouldIgnore(error, isTaskCancelled: Task.isCancelled)` 过滤, 取消错误（`Task.isCancelled` / `CancellationError` / `URLError.cancelled`）直接 return, 不写 `self.lastError`. 跟 AppState 的 refresh catch 同语义.

### Per-event field count（四桶 + 时长）

Every call carries 4 token categories (input / cacheRead / rawOutput / reasoning) from
the `.db` usage 子消息（`f4`）。Its consumption `totalTokens` is derived from
`input + cacheRead + output + reasoning`（四桶规范化后）。Raw `outputTokens`
**includes** thinking（db `f3` 恒等 `f10 + f9`，与旧 RPC `outputTokens` 同口径）, so the
normalized `Output` bucket is `outputTokens − reasoningTokens`。

**`cacheWrite` 恒 0**：`.db` 的 usage 子消息不提供 cacheWrite（本就排除在 total 外）
——统一 total、图表与价值估算不受影响，仅日桶诊断字段失去可见性（有意接受）。

Every call additionally carries the native call `durationSeconds`（steps.metadata
`f7 − f1`，见 `spec/harnesses/agy.md` § 单次调用时长）which flows into
`LocalTokenUsageSample.durationSeconds` for the tok/s rate.

In the daily aggregate (`AntigravityDailyUsage`), the 4 categories are summed per day
after the per-event catalog normalization (same entry point as samples:
`AntigravityLocalUsageAggregation.aggregateDaily` / `makeSample`), so `totalTokens` is
the four-bucket day sum and stays conservation-consistent with the samples.

## Session file formats（`.db` only；`.pb` 已忽略）

阶段二b（2026-11-08）起 scanner **只收 `.db`**：会话枚举（`listDBFilesWithStatus`）按
扩展名过滤（`SessionStoreFormat` 枚举随 `.pb` 分支一并删除），`.pb` 文件完全忽略
（不发现、不指纹、不进 session 集）。token/模型/时间戳/轮次全部来自 `.db` 直读
（`AntigravitySessionDBReader`，见下文 § Token & model data ARE in `.db` `gen_metadata`）。

| Extension | Format | Runtime use | R/T computation | Token computation |
|---|---|---|---|---|
| `.db` | SQLite | 文件路径、扩展名、mtime/size 及 WAL 指纹 + `probe` 版本门直读 | `step_type=14` 直计 turns；连接命中 Call 计 rounds | `gen_metadata`（`steps.idx == f20.last_step_index + 1` 连接）|
| `.pb` | Protobuf (wrapper, not raw) | 完全忽略（无 `gen_metadata` 结构；RPC 支持已退役） | — | — |

`protoc --decode_raw` on observed `.pb` files fails with "Failed to parse input" — the wrapper is not standard raw protobuf (likely a length-prefixed stream or a custom envelope around a proto message). The bytes do not look compressed (zstd / lz4 / gzip all reject) or encrypted。

### Directories scanned (`defaultConversationsDirs`)

The scanner walks a single directory:

1. `~/.gemini/antigravity/conversations/` — Antigravity.app (`--app_data_dir antigravity`)

`~/.gemini/antigravity-ide/` (Antigravity IDE.app, `--app_data_dir antigravity-ide`) was previously scanned as a second root but support for it has been removed; the scanner no longer reads that directory. The directory list itself is still an array, kept as a test/injection seam for multi-root enumeration.

## Historical `.db` Schema Insights — Rounds / Turns / Tool calls

The following is historical reverse-engineering material, retained to explain the origin of the current RPC heuristic. It is not a runtime dependency: the scanner no longer opens these SQLite files or uses `step_type` values. Antigravity's `~/.gemini/<antigravity-ide|antigravity>/conversations/{cascadeId}.db` is a SQLite file with an undocumented schema. All `step_type` numbers come from Google's internal `cascade` framework and were verified by reading 21 `.db` files (June–July 2026) and matching against RPC-returned token data.

### One `.db` = one cascade (one Antigravity session)

A cascade ID is a UUID (`{cascadeId}.db`) shared with the RPC `cascadeId` parameter. Each session can span multiple hours (longest observed: 12h40m, 850 LLM calls). The scanner's session set comes from `ls` over `defaultConversationsDirs` (`.db` + `.pb`).

### `steps` table — what each `step_type` means

| `step_type` | Count per session (observed) | Meaning | Used for |
|---|---|---|---|
| **14** | 5–50+ | **USER PROMPT (turn boundary)** | turns |
| **15** | 10–850 | **LLM API call (round)** | rounds |
| 5 | 0–50+ | LLM tool: `replace_file_content` (JSON: Description + Instruction + ReplacementContent) | tool call distribution |
| 7 | 0–50+ | LLM tool: `grep` / `read_file` | tool call distribution |
| 8 | 0–150+ | Tool result (file content) | diagnostic only |
| 21 | 0–50+ | LLM tool: `run_command` (JSON: CommandLine + Cwd + toolAction) | tool call distribution |
| 9, 23, 33, 98, 101 | rare | Other (rare step types, not yet classified) | unused |

> [!NOTE]
> **架构演进（v1.4+ 纯 RPC → 阶段二b `.db` 直读）**：v1.4+ 曾升级为纯本地 RPC
> (`GetCascadeTrajectoryGeneratorMetadata`) 提取 Turns、Rounds 和 Token 数据；阶段二b
> （2026-11-08）起 scanner 改直读 SQLite `.db`（`gen_metadata` + `steps`），本地 RPC
> 退役。`step_type=14/15` 语义重新成为运行时依赖（turns/rounds/时间戳），保留以下
> 历史 Insights 供架构参考。

**历史 `.db` 节点说明**（仅供分析参考）：

**Key trap to avoid**: `step_type=5` and `step_type=21` payloads contain fields named `Description`, `Instruction`, and `ReplacementContent`. These look like user prompts at a glance but they are the **LLM's tool-call instructions to the IDE**, not user input. The actual user prompt is `step_type=14` — its payload embeds the user's literal text (extractable with `[\x20-\x7e\u4e00-\u9fff]{15,}`).

### `step_type=14` payload structure — user prompt

The top-level `step_payload` is a protobuf message. The user prompt content lives at a known fixed path:

```
step_payload
└── field 19 (LEN, 1000-4000 bytes)  ← UserPrompt message
    ├── field 2  (LEN)  ← user's literal text (the actual prompt)
    ├── field 3  (LEN)  ← other metadata (e.g. sentence annotations)
    ├── field 7  (LEN)  ← attached file URI (e.g. `file:///...implementation_plan.md`)
    └── field 12 (LEN)  ← available tool list (read_file / command(*)/mcp(...) / etc.)
```

**For "prompt" extraction**: use `field 19 > field 2`. Field 12 is the catalog of tools the IDE exposed to the LLM for this turn (the `command(./scripts/build_app.sh)` / `read_file(*)` / `mcp(chrome_devtools/...)` strings come from here — not the user's prompt).

**Empty / automated prompts**: a `step_type=14` with no `field 2` text is a **continuation prompt** — the IDE injects it when the user clicks "Continue" with no text. The attached file URI in `field 7` (typically `file:///Users/.../antigravity/brain/<cascadeId>/implementation_plan.md`) is the only payload. Observed ~3% of turns in long sessions.

### `step_type=15` payload structure — LLM round (Type A vs Type B)

The `step_payload` wraps one LLM call. Field 20 is the LLM round message; inside it, the LLM text vs tool call lives at distinct field numbers, and **the protobuf structure tells you whether this round is a working round (Type A) or a final response (Type B)**:

```
step_payload
└── field 20 (LEN, 100-20000 bytes)  ← LlmRound message
    ├── field 1  (LEN)  ← **final user-facing response** (Type B only)
    ├── field 3  (LEN)  ← **LLM thinking out loud** (Type A only)
    ├── field 6  (LEN)  ← tool call ID (UUID with `bot-` prefix)
    ├── field 7  (LEN)  ← tool call JSON data (CommandLine / AbsolutePath / etc.)
    ├── field 8  (LEN)  ← duplicate of field 1 (Type B only)
    ├── field 11 (LEN)  ← timestamp (varint, seconds since epoch)
    ├── field 12 (varint)← always 1 (round index in cascade?)
    └── field 14 (LEN)  ← metadata blob (Type B only)
```

**Two round types, two field shapes** (verified on 98 turns of one production session):

| Type | Has field 1 | Has field 3 | Has field 7 (tool) | Meaning | Typical count per turn |
|---|---|---|---|---|---|
| **A (working)** | ❌ | ✅ (English, "I'm now focused on…") | ✅ (JSON params) | LLM thinks out loud, then calls a tool | 0-20+ |
| **B (final)** | ✅ (Chinese, structured with emoji/headers) | ❌ | ❌ | LLM delivers the user-facing answer | exactly 1 (the last) |

**Why this matters for the OUTPUT**: a `step_type=15` round's "text content" is **either** `field 1` **or** `field 3` — never both, and the wrong one is a totally different content type:

- **`field 1`**: structured Chinese summary, often with `### 🛠️ 1. 双向边界渗透自愈实现` headers, code blocks, Git commit hashes, TP/FP counts. This is the response the user reads in the IDE chat.
- **`field 3`**: terse English commentary like `**Initiating Task Update**\n\nI've established the task list, and now I'm updating task.md, marking the first task as "in progress."` — the LLM's "thinking aloud" before invoking a tool. Shown in IDE debug panels but NOT in the user-facing chat.

**The trap**: extracting `field 3` (or "any LEN text in field 20") gives you the LLM's internal monologue, not the final answer. Extraction code that doesn't know about Type A vs Type B will output working-round noise and miss the final response entirely.

**How to find a turn's final OUTPUT** (the user-facing answer):

1. Walk all `step_type=15` rows with `idx` between this turn's user prompt (`step_type=14`) and the next turn's user prompt
2. The **last** one is the final round
3. If `field 1` is present → that's the final OUTPUT (Type B)
4. Else, the last round with any text is the last working round (Type A only) — the turn has no final summary in the .db (the LLM ended with a tool call and the next user prompt interrupted)

**Sample Python walker** (works on the {cascadeId}.db after copy-isolation; the `field 20 > field 1/3` schema has been stable across 21 .db files observed since June 2026):

```python
def parse_unknown_fields(data): ...   # standard varint walker
def get_user_prompt(payload):
    # top-level field 19 > field 2
    ...
def get_round_text(payload):
    # field 20 > field 1 (final) and field 20 > field 3 (thinking)
    final = thinking = None
    for f20 in parse_unknown_fields(payload):
        if f20.field_num == 20 and f20.wire_type == 2:
            for sub in parse_unknown_fields(f20.value):
                if sub.wire_type == 2 and len(sub.value) > 20:
                    try:
                        text = sub.value.decode('utf-8')
                        if '\x00' in text: continue
                        if sub.field_num == 1 and not final:   final = text
                        elif sub.field_num == 3 and not thinking: thinking = text
                    except: pass
    return final, thinking
```

### Token & model data ARE in `.db` `gen_metadata`（2026-11-08 实测，IDE 2.29.0）

> **历史结论（2026-07，IDE ~2.15–2.2x，已过时）**：当时的 Rosetta-stone 搜索认定 token 数字不存在于任何
> .db 表（`steps` / `gen_metadata` / `executor_metadata` 等），「token 只在 `language_server`
> 进程内存中、重启即失」。该结论对当时版本成立；2026-11-08 在 2.29.0 上被推翻——schema 随版本演进，
> 任何读 `.db` 的实现都必须先过版本指纹门（`AntigravitySessionDBReader.probe`）；probe 不过的
> session 记一次失败并跳过（阶段二b用户裁定：不做 RPC 回退、不做混合）。
>
> **阶段二b（2026-11-08）起本节是 scanner 的运行时数据源**（不再是「数据侧调研」）：
> 每个脏 session 经 `probe → readCalls + readUserTurnSteps` 直读。

`gen_metadata` 表（`idx` INTEGER PK / `data` BLOB / `size` INTEGER）每行对应一次生成调用；
**含模型名（f19）的行与 RPC `generatorMetadata` 事件数组 1:1**（RPC 对原始表做了过滤，表行数可
多于事件数——2026-11-08 实测 `22b4f174` 表 108 行、RPC 侧 102 事件，见 § Round ↔ step index
mapping）。`data` 为 protobuf，解码后顶层字段：

| 字段 | 内容 |
|---|---|
| `f4` (str) | trajectory UUID |
| `f1` (msg) | 事件主消息 |
| `f1.f4` (msg) | **usage 子消息**：`f2`=uncached input、`f5`=cacheRead、`f3`=raw output（**含思考**，恒等 `f10 + f9`）、`f9`=reasoning、`f10`=normalized output；值为 0 的字段常缺省；**cacheWrite 不在其中** |
| `f1.f17` (msg) | 同一 usage 的副本 + `f4`(str)=16-hex **每请求随机 id**（非模型 hash，实测 148 distinct/166 行） |
| `f1.f19` (str) | **模型名字符串**（如 `gemini-3.8-flash-n`） |
| `f1.f20` (repeated) | string→string map：`model_enum`=`MODEL_PLACEHOLDER_Mxxx`（家族级稳定枚举）、`cascade_id` / `root_cascade_id` / `trajectory_id` / `request_id`、`used_claude` / `used_claude_conservative` / `used_non_gemini_model`、`last_step_index` |
| `f1.f21` (str) | 显示名（如 `Gemini 3.8 Flash (Low)`） |

**验证**（monitor 缓存 `samplesBySession` 为 ground truth，按时间序 run-length 对齐）：

- `22b4f174…`（双模型）：切换序列 `flash-n×22 → argon×3 → flash-n×77` **完全一致**；usage 字段多数投票 102/102（cacheRead 命中 92/92）
- `f83f6ecb…`（三模型）：`claude×18 → argon×5 → flash-n×27` **完全一致**
- 部分条目（实测 6/108）**无 `f19` 模型名、但有 usage、且无对应 step 行**（`f20.last_step_index + 1`
  不在 `steps` 表中，自身也无时间戳）——后台/副调用条目。**与 `steps` 表的正确连接键是
  `steps.idx == f20.last_step_index + 1`**（含模型名行 102/102 命中、零冲突、零遗漏）；按序号裸配对
  会从第一条此类行起整体错位，禁止。事件集合 = 「有 f19 且连接命中」的行，其外条目的 token 不计入
  （与退役前的 RPC 口径一致：cache rounds = 102）
- `MODEL_PLACEHOLDER_M318/M319/M402/M418` ↔ 模型映射跨 session 稳定，但为**家族级**（M318 同时对应
  `-n` / `-high`），精确到思考档位以 `f19` 为准
- **turns/rounds 口径抽样**（12 session，2026-11-08）：`rounds` 与 `step_type=15` 计数 11/12 完全
  一致（1 个差 1，懒刷新尾部）；`step_type=14` 与 transcript `USER_INPUT` 的 step_index 逐一对应
  （23/23）。旧 RPC gap 推断 turns 严重虚高：真实会话 +37%~+273%（82→22、46→6、40→11），克隆/后台
  会话（transcript 无 USER_INPUT，如 `67d181b9` 275 rounds）凭空计出 43 turns——阶段二b直读
  （step_type=14 直计）语义正确，切换接受数字回落（用户裁定：以新数据源为准，不考虑历史）

**transcript.jsonl 字段空间穷尽**（357 行全字段清单，2026-11-08）：除 `input_tokens` /
`cache_read_tokens` / `output_tokens` 三个计量键外，只有 `step_index` / `source` / `type` /
`status` / `created_at` / `content` / `tool_calls[]` / `truncated_fields[]`——**没有任何模型名或
id/hash 字段**。模型归因的本地文件来源只有 `gen_metadata`；db 单文件即可同时提供 token 四桶（f4）、
模型（f19）、时长（`steps.metadata` 时间戳，方案 A 见
[`spec/harnesses/agy.md`](../harnesses/agy.md) § 单次调用时长）与轮次（`steps.step_type=14`）。

`.pb` 会话（2026-11-08 本机 3/361）非 SQLite、无此表；阶段二b起完全忽略（RPC 退役后
无可用数据源，不发现、不指纹、不进 session 集）。

### Lazy .db write — sessions don't flush while open

`language_server` (PID discoverable via `ps aux | grep language_server`) holds `.db` file handles while a session is active. Until the session closes, the conversation switch happens, or the IDE exits, **the `.db` mtime does not update** and the scanner cannot see new steps. Implication for users: counts in the app lag the real-time activity by 0 to N hours, where N depends on when Antigravity last flushed. Use `lsof +D ~/.gemini/antigravity/conversations/` to check who holds the file handle.

### Round ↔ step index mapping

For historical sessions whose `.db` steps and RPC response events were in sync:

- `gen_metadata.idx` (table of LLM-call trajectories) is 1:1 with the `events` array index returned by the RPC
- `steps.idx` of `step_type=15` rows in ascending order is 1:1 with the same RPC events array
- Both orderings are by occurrence, not by `idx` value (idx values have gaps for non-LLM-call steps)

This means: a `step_type=15` row at `.db idx = N` is the LLM call that produced `events[N]` in the RPC response. `step_type=14` (user prompt) `idx` values sit *before* the `step_type=15` `idx` for the LLM calls they triggered — using `step_type=14` boundaries to slice events[] gives per-turn token totals.

## Current scanner pipeline（`.db` 直读，阶段二b）

1. **File fingerprint diff** — enumerate `.db` filenames only and compare mtime/size;
   the adjacent WAL mtime/size is also part of the fingerprint（`.pb` 完全忽略）。
2. **`.db` 直读** — for each dirty session: `AntigravitySessionDBReader.probe`
   （版本指纹门：`gen_metadata` 表存在且首行解出非空 `f1.f19` 模型名）→
   `readCalls`（gen 行 ↔ `steps.step_type=15` 行按 `steps.idx == f20.last_step_index + 1`
   连接，产出逐调用 token/模型/双时间戳/时长）+ `readUserTurnSteps`
   （`step_type=14` 用户轮次边界）。全量读，本地 db 毫秒级。
3. **口径映射** — `completedAt` = f7、`durationSeconds` = f7 − f1、`cacheWrite` 恒 0；
   四桶经 `TokenAccountingCatalog.antigravity` 规范化（rawOutput 含思考，与旧 RPC
   同口径）。**rounds** = 带 `completedAt` 的连接命中 Call 数；**turns** =
   `step_type=14` 直计（与 transcript USER_INPUT 23/23 对应；旧的 `stepIndices`
   间隙推断对真实会话虚高 +37%~+273%，已随 RPC 退役），turnIndex ≥ 1 首见开轮、
   turn-0（无前置用户输入的背景/副调用，含克隆会话）不开轮。轮 N 归入该轮第一条带
   时间戳 call 的本地日历日；无时间戳的 Call 排除出 daily/turns/rounds/samples。
   样本 `promptID` = `<session>:turn-N`，N = idx 小于该 Call stepIndex 的
   `step_type=14` 行数（`turnNumber(forCallStepIndex:userTurnStepIndexes:)`）。
4. **Day bucketing** — daily 归属按 `completedAt` 落本地日历日（沿用现有日桶逻辑，
   `aggregateDaily` / `makeSample` 入口不变）。
5. **Cache update** — 直读成功替换该 session 的 daily/sample 缓存并采纳文件指纹；
   读失败按错误类别两路收敛（结构化不兼容当轮采纳当前指纹、可重试 I/O 连续 3 次
   后采纳指纹），两路都计一次失败并保留 last-good（文件再变化时自然重新入账）。
   日历签名只被枚举不完整阻塞。

## Historical SQLite reader investigation

The following SQLite investigation describes the removed implementation and is retained only as background. It must not be read as the current scanner pipeline.

**根因（确认）**：macOS 系统 `libsqlite3.dylib` 跟 CLI `sqlite3` 是**同一 SQLite 源版本（3.51.0）**。但 IDE 写出来的 `-shm` 共享内存文件，**dylib 拒绝 open，CLI 接受**。`sqlite3_open_v2` 成功（打开 .db 文件），但 `sqlite3_prepare_v2` 在 mmap `-shm` 阶段返回 `SQLITE_CANTOPEN (14)` "unable to open database file"。

**实测 21/21**：
- 全 fresh 状态（没 -shm）：dylib 21/21 SUCCESS（自己建 -shm）
- IDE 写完一轮后（每个 .db 都有 32KB -shm）：dylib **5/21 SUCCESS，16/21 CANTOPEN**
- 同 .db 用 CLI 测：21/21 SUCCESS

**为什么 dylib 严格、CLI 宽松**：
- dylib 跟系统 SQLite 一起 backport，对损坏/不规范的 -shm 状态直接 fail
- CLI 走自己的代码路径，对异常 -shm 更鲁棒
- 具体差异点没深挖（可能是 -shm header magic / version / size mismatch），但行为可观察

**为什么最终不采纳"删 -shm 修法"**（2026-07-15 18:30 用户判断）：
- 删 -shm 后 dylib 100% 能 read（实测 5/21 → 20/21）
- 但 IDE 侧需要重建 -shm → 引发额外 I/O + 短暂 WAL 写入抖动
- **不值的为 1/21 收益去打扰 IDE**——主动写 session 的 1/21 删了也立刻被 IDE 重建，救不回来
- 选了"copy 隔离"，稳态 ~21/21 + IDE 完全不被干扰

**历史实现的最终修法**（`SQLiteTempCopy` 公共 helper + `AntigravityDBReader` + `AntigravityLocalUsageScanner.performScanPure`）：

1. **快路径：直接 read 原 .db**（`SQLiteTempCopy.read` 第一次尝试）
   - 默认尝试，0 copy I/O。无 -shm 冲突时省掉 ~16MB/session 的文件复制
   - 实测：IDE 暂停写时 21/21 session 都能走快路径，scan 1455ms vs copy 策略 10059ms
   - **省 6.9x 时间**

2. **兜底：copy .db + .db-wal + .db-shm 到 /tmp 副本上 read**（`SQLiteTempCopy.withTempCopy`）
   - 快路径 open 失败且错误码是 CANTOPEN(14) / BUSY(5) 时自动触发
   - 副本上 SQLite 自由 mmap，不受 IDE 实时 -shm 状态干扰
   - READWRITE 让 SQLite 在副本上完成 WAL recovery（把 -wal pages 写回 .db）
   - `sqlite3_busy_timeout(db, 300)` 应对偶尔的副本竞争
   - 副本不保留，read 完 `defer` 删 .db / .db-wal / .db-shm

3. **错误码过滤：只对 file-level 错误走 copy**（`SQLiteTempCopy.read`）
   - CANTOPEN(14) / BUSY(5) → 走 copy（IDE -shm 状态/锁问题，copy 能解）
   - NOTADB(26) / SQL 错误 → 直接 propagate（copy 也救不了，省 I/O）

4. **单次尝试，失败丢给下次 scan**
   - 不在 scanner 内维护 5s retry timer（额外状态机 + 抢 IDE 资源的本质没变）
   - 失败就 `logInfo` + 保留旧 R/T 数据；下一次 Provider batch settle 后，若 FSEvents
     仍标记 source dirty，再由 reconcile 执行 Dirty Scan
   - IDE 通常那时已暂停写 → .db 副本 copy 成功率高

5. **Off-main-thread**：所有 SQLite 读 + RPC 都在 `nonisolated static performScanPure`
   里通过 `LocalUsageScanRunner` 执行，继承 caller 取消且不阻塞菜单栏 MainActor。
   RPC 是串行的（`fetchAll` 内部 `for` 循环），不是因为怕 IDE 锁竞争，
   而是因为串行 fetchAll 简化了 R/T 配对的 idx 语义；copy 隔离后
   IDE 完全不知道我们在 read。

6. **R/T 数据不能覆盖**（**重要 bug 修复**）
   - 旧代码：scan 失败时 `index.dailyBySession[sessionId] = newDaily` 仍执行
   - newDaily（无 R/T）覆盖了之前成功的 R/T 数据
   - 现象：20/21 → 反复 scan → 10/21（数据被蚕食）
   - 修：`if rtSucceeded || index.dailyBySession[sessionId] == nil` 才更新 index
   - 即 R/T 失败也保留旧 index 的 R/T（merge 而不是 overwrite）
   - **任何"先建 newDict 再覆盖旧 index"模式都要警惕**——read-modify-write 不能用 replace

**实测**（force full scan by touch 所有 .db）：
- 21/21 SUCCESS, 0 failed
- **快路径全命中（0 fallback）**：21 个 session 全部直接 read 成功
- full scan 时间：**1455ms**（vs 之前 always-copy 策略 10059ms，**6.9x 加速**）
- 即使 IDE 当前正在写，快路径失败自动触发 copy 兜底，**21/21 仍能成功**
- 偶尔 IDE 切换 session 时 .db 短暂不可读 → 单次失败 → 下次 scan（60s 内）自然 backfill
- total turns/rounds 持续累积（实测 118/1305+），不停涨

**为什么不采纳的修法**：
- ❌ **删 -shm**（5/21 → 20/21）：让 IDE 重建 -shm I/O 抖动 + WAL 短暂性能抖动，为 1/21 收益打扰 IDE 不值得
- ❌ **bundle 新版 libsqlite3.dylib**：code signing 拒收风险
- ❌ **fallback 到 `Process` 跑 `sqlite3` CLI**：subprocess 启动开销 ~50ms × 21 = 1s，实施成本不匹配
- ❌ **自己 parse .shm/.db 格式**：~500 行新代码，bug 风险高

**未来可选优化**（如确实需要 100% 实时覆盖率）：
- IDE 提供 IPC 接口直接给 R/T 数据（不依赖 .db 文件）——最干净，但等 IDE 团队
- 把 -shm "问题 dylib 版本" 标记为已知限制，靠 IDE 写完一段后自然 backfill

### Historical R/T round-event 配对：按时间排序

旧版 `performScanPure` 曾把 RPC events 跟 `.db` `step_type=15` idx 列表配对时：

| 来源 | 内容 | 顺序保证 |
|---|---|---|
| `.db` `step_type=15` idx | LLM call 序号 | `ORDER BY idx` **严格升序**——稳定 |
| RPC `generatorMetadata` events | 每次 LLM call 的 token + timestamp | **RPC 返回顺序不保证**——会话变长后 payload 排列会漂移 |

如果直接 `events[i]` ↔ `roundIdxs[i]` 按位置配对，RPC 顺序变化时配对错位，部分 round 找不到 timestamp，R/T 当天显示为 "—"。**间歇性失败，看似随机**。

**历史修法**：events 先按 `timestamp` 升序排，再按位置配对 roundIdxs。（RPC 时代与
阶段二b直读都不再做这类按位置配对——直读的连接键是
`steps.idx == f20.last_step_index + 1`，见 § Token & model data ARE in `.db` `gen_metadata`。）

```swift
let sortedEvents = events
    .filter { $0.timestamp != nil }
    .sorted { $0.timestamp! < $1.timestamp! }
let n = min(roundIdxs.count, sortedEvents.count)
for i in 0..<n {
    roundIdxToTs[roundIdxs[i]] = sortedEvents[i].timestamp!
}
```

**配套优化**：
- turn 找"idx 之后第一个 round idx"用 O(log n) binary search（手写 `lo/hi`），不要 `firstIndex(where:)` O(n) 线性扫
- `roundIdxs` 由调用方查询后传入 `perDayTurnsAndRounds(roundIdxs:...)`，避免在两个函数里重复 `SELECT ... WHERE step_type=15`（两次独立读事务，busy_timeout 也只盖单次）

### Historical R/T ratio as a complexity signal

Rounds-per-turn is a strong signal of task complexity. Observed ratios (21 sessions, 6 active days):

| Date | turns | rounds | rounds/turn | What was happening |
|---|---:|---:|---:|---|
| 2026-06-10 | 7 | 24 | 3.4 | First-time setup, mostly trivial turns |
| 2026-06-22 | 11 | 48 | 4.4 | Routine edits |
| 2026-07-09 | 48 | 308 | 6.4 | Mixed work day |
| 2026-07-10 | 7 | 102 | 14.6 | Debug-heavy session |
| 2026-07-14 | 29 | 221 | 7.6 | Normal workday |
| 2026-07-15 | 12 | 388 | 32.3 | First 2 turns dominated, rest were 1-round follow-ups |

Distribution per turn within a single session is highly uneven — first few turns after a context reset often burn 25+ rounds (tool-use loops), then a tail of 1-round confirmations. The 7-day chart should show both totals, not the ratio (it's not meaningful when averaged across heterogeneous turns).

## UI

Card metadata:

| Field | Value |
|---|---|
| `displayName` | `Google Antigravity` (provider name, with brand prefix) |
| `iconSystemName` | `paperplane.circle.fill` |
| `accentColor` | `antigravity` |

**Card title = `displayName`** ("Google Antigravity") and nothing else — the tier
pill was removed from the header row (2026-10 second UI pass) and now lives in the
card's first section. The two text dimensions still carry non-overlapping
information, just in different places:

- **Title** = provider brand (always present, header row, right side is the
  refresh time / state capsule)
- **Pill** = tier / plan identifier (when known, kept short, card section 1)

`planPillLabel` strips the `Google ` / `Antigravity ` prefix, so `Google AI Pro`
becomes `AI Pro`, `Antigravity Pro` becomes `Pro`, and bare names like `Free` pass
through unchanged.

### Account row (card section 1)

`QuotaWindowAccountInfoRow` is a **resident row** in the card's first section
(`QuotaWindowAccountInfo.make` is the single visibility judge), followed by a thin
separator. The old `AccountHoverView` panel — and with it the
`Google Antigravity 账号` header, the "数据来源：本机 Antigravity / agy CLI 的
language_server" note and the "未拿到账号邮箱（首次刷新后会显示）" placeholder — is
gone; a hint that can never resolve is noise in a row that is always on screen.

The row shows:

- Login email (主路径 = Keychain `id_token_email`，随凭据带回；本地回退时
  GetUserStatus.email 优先、Keychain 兜底), monospaced, single line with
  tail truncation and the full text in `.help(...)`
- The tier pill right after it (主路径 = 远端 `loadCodeAssist` tier；本地回退 =
  GetUserStatus/GetLoadCodeAssist tier 回退链，缩短自同一条
  `planPillLabel` 规则)

Antigravity needs **either** field to draw the row; when both are missing (e.g.
the user just logged out and the next refresh hasn't run) the whole row and its
separator are skipped.

This card is also the home of the agy CLI's local usage: `agy`'s transcript frames
carry `quotaProviderID = antigravity` (native mode, not routed through the
`defaultBindings` matrix), so its 7-day usage lands in the same section beside the
IDE `.db` ledger（阶段二b直读） — see `spec/harnesses/agy.md`。

### Local usage (card section 3)

The card is a three-part stack: **1 Account Info** → **2「Plan详情」** (the two
model bars + the quota-window usage block) → **3「最近7天token用量」**, with a card
boundary replacing the old hover divider between quota (now) and local usage
(history). Section 3 renders the `.detail` half of `LocalUsageFooterView`
**inline** — there is no hover panel any more:

- legend `Input` / `Cache` / `Output` / `Reason`
- 7 stacked bars, one per local day, ascending with today last
- a numeric table: 日期 / R/T / Input / Cache / Output / Reason (plus 价值 when a
  per-day price estimate exists)
- freshness lives in the section title row (`dockSectionTitle`): 「最近7天token用量」
  + `LocalUsageFreshnessBadge` (bare `HH:MM` from `scannedAt` — the 「更新于」 prefix
  was dropped 2026-10-13 to match the header timestamp, or 计算中… while scanning).
  The two card timestamps have **split** semantics (2026-10-18 起，见
  `ui/menu-and-cards.md` §Provider Card)：header 的 `ProviderStateLabel`（额度时间戳）
  点击经 `\.cardQuotaRefreshAction` → `AppState.refreshOne(providerID:)` 只重抓本卡
  额度并只重锚其排期；本 badge（用量时间戳）点击经 `\.cardUsageRefreshAction` →
  `AppState.triggerLocalUsageRescan()` 只补拍一次本地用量 reconcile（环境键默认
  nil = 只读）

Source: `AntigravityLocalUsage.dailyTokenUsage` (always the last 7 local days,
missing days back-filled), summed from every session's events whose timestamp
falls in that local day.

Today's number has its own home now: it is the 「今」row of the 「额度窗口」block in
section 2 (`ProviderCardView.todayUsageRow`, same `AntigravityLocalUsage.today`
source) — the standalone "📈 今天 …" footer line was removed together with the rest
of the `.summary` part. `isReady` for Antigravity is simply "there is at least one
day of data", so a partially accumulated week still renders the chart; before any
data exists the section shows a placeholder (`正在扫描本地 token 用量…` while
scanning, `本机未发现 Antigravity 会话数据` once the scan completed with 0 sessions).

### Quota rows

Current row tints:

| Group | Tint |
|---|---|
| `Gemini Models` / `Gemini 4 Argon` | blue |
| `Claude and GPT models` | orange |

Dual-window groups use a combined quota row: the metadata line is
`<model name> … 5h <pct> 周 <pct> <reset time>` (name leading, both window
readings plus the binding window's reset time clustered at the line end), and the
bar is segmented by the group's weekly equivalent multiplier — 4 for
`Gemini Models` (four equal-capacity segments;
`Gemini 4 Argon` Pro 套餐仅返回周窗口，走单窗口路径；若返回双窗口沿用 4),
2 for `Claude and GPT models` (2026-10-13 从 1 调回 2；2026-10 初曾从 3 下调到 1，
周窗口 = 2 × 5h 额度). A 1-segment bar has no equivalent-
weekly reading to draw, and its tooltip says 单一窗口可用进度 instead of
"第 1 格为当前窗口余量；后续 N-1 格为等价周额度余量".

```text
Google Antigravity                                          01:44
alice@example.com  [AI Pro]
───────────────────────────── Plan详情
Gemini Models                          5h 100%  周 85%   <weekly reset time>
[weekly bar in 4 equal segments (capacities 1, 1, 1, 1; integer multiplier → uniform 25-tick segments)]

Gemini 4 Argon                                  周 100%  <weekly reset time>
[single weekly bar]

Claude and GPT models                  5h 100%  周 100%  <weekly reset time>
[weekly bar in 2 segments]

───────────────────────────── 最近7天token用量          02:00
[Input] [Cache] [Output] [Reason] + 7-day stacked bars + usage table
```

The status bar's center gauge uses the same multiplier as its single source of
truth: `min(5h 剩余, 周剩余 × N)` (`ModelQuota.weeklyEquivalentMultiplier` →
`aggregateActualAvailable`).

**聚合排除（2026-10 用户裁定）**：`Claude and GPT models`（`claude_and_gpt_models`）与
`Gemini 4 Argon`（`gemini_argon`）组不参与跨 model 聚合读数 —— 状态栏 iconDuo、边缘窗圆环与
provider 综合健康度经 `QuotaInfo.aggregateQuotaModels(providerKind:)` 取聚合 model 集合，
`ModelQuota.isExcludedFromQuotaAggregation` 把这两组排除（与 minimax `video` 同规则），
只以主力 `Gemini Models`（`gemini_models`）代表 Antigravity 的聚合水位；卡片三组行、
通知检测不受影响。滤后为空的退化场景回退 `activeModels`。

卡片第 2 段「额度窗口用量」表格的 **5h / 周** 同样严格走 `aggregateQuotaModels`，仅统计
主力 `Gemini Models` 的窗口用量与重置倒计时，不与 Argon / Claude 跨池混淆或被副池的倒计时误导；
而表格的「**今**」行则取全量日账本，统计今日账号下调用的所有模型（含 Gemini、Argon、Claude）。

## Error Handling

**Quota path（阶段一：Keychain 凭据 + 远端 Google API；2.4.2 起过期/401 转本地回退）**：

| Situation | Current behavior |
|---|---|
| Keychain 条目不存在 / 不可解析 | 不再直接报错：转入本地回退（`网络错误：未读取到 keychain 凭据…` 仅 log）；本地 RPC 成功 → 额度照常；回退失败 → `credentialExpired`（`token 已过期：打开 Antigravity 可继续监控额度，重新登录可刷新凭据`）。auth probe 仍只看钥匙串可读性（false → `.notConfigured` 提示，不影响 fetch 决策树） |
| 本地过期判定 `now >= expiry` | **不发任何远端请求**，转入本地回退；回退失败 → `credentialExpired`（同上新文案） |
| 远端配额接口返回 401 | 主机回退链立即终止，转入本地回退：本地 RPC 成功 → 额度照常（不再打远端）；无本地后端 → `credentialExpired`（同上新文案）；本地 RPC 报错 → 按本地错误原样上抛（见下两行） |
| 远端 tier（loadCodeAssist）返回 401 / 其他失败 | 不影响主额度（可选元数据，`.full` 采 nil） |
| 非 401 的非 2xx（远端） | 换下一主机（Daily → cloudcode-pa → sandbox）；全部失败抛最后一台的 `HTTP <status>: 响应 <N> bytes`（body 只按大小摘要，不回显内容），不做本地回退 |
| 传输层失败（超时 / 连接失败等，远端） | 同上换下一主机（HTTPClient 包装为 networkError，可回退） |
| 本地回退：未发现进程 / 进程未监听端口 | 抛 `credentialExpired`（三种回退 origin 同文案） |
| 本地回退：TOCTOU 复查失败（pid 不再监听端口） | `网络错误：Antigravity 本地服务身份已变化（pid=…, port=…），请重试刷新`；凭据缺失/过期 origin 下进一步落 `credentialExpired`，远端 401 origin 下原样上抛 |
| 本地回退：RPC 传输失败 / 非 2xx / 解析失败 / 响应超 8 MiB | 凭据缺失/过期 origin → `credentialExpired`（同上文案）；远端 401 origin → 按现有路径原样上抛（`networkError` / `httpError` / `解析失败…` / `responseTooLarge`）；本地 RPC 报错永不触发远端重试 |
| 取消（URLError.cancelled / CancellationError） | 原样上抛（含本地回退路径），走 AppState/CancellationFilter 的 deferred 路径，不记失败 |
| quota JSON decode fails | `解析失败：Antigravity 响应无法解析，响应 <N> bytes`（本地回退路径同款，凭据缺失/过期 origin 下进一步落 `credentialExpired`） |
| One quota group has an invalid / missing `remainingFraction` | That group is skipped with a warn; the other groups still render |
| No quota groups survive parsing | `解析失败：Antigravity quota 响应里没有可用 bucket` |
| 响应超过字节上限 | `响应过大（上限 N bytes）：<redacted path>` (`QuotaError.responseTooLarge`) |
| config 手改 `allowTokenRefresh: true` | 解码抛 `AppConfig.SchemaError.antigravityAllowTokenRefresh`（启动保留原文件按默认配置运行、热重载保留上次配置）+ log warn；provider 按 false 运行 |

**Local-usage path（阶段二b：`.db` 直读，scanner 专用）**：

| Situation | Current behavior |
|---|---|
| `.db` 未通过版本指纹（`probe .incompatible`：无 `gen_metadata` 表 / 表空 / 首行不可解码或无模型名）或 SQLite I/O 失败 | `failedSessionCount` +1（log warn 带原因），本轮继续扫其余；采纳当前文件指纹并保留 last-good（无 last-good 写空终结条目），下一轮指纹匹配不再重读；文件再变化时重新入账 |
| Scanner: every entry in `defaultConversationsDirs` missing | Scan completes with `sessionCount: 0`; the local-usage section shows the "本机未发现 Antigravity 会话数据" placeholder |
| Scanner: conversations enumeration hit a permission / TCC / I/O error | `isComplete = false` → no session is declared deleted, the calendar signature does not advance, and the round counts as one failure |
| Scanner: session `.db` 直读成功但无连接命中的 Call（如纯后台/克隆会话） | 正常写空缓存（eventCount 0 / 空 samples）并采纳指纹 |
| Scanner: `index.json` corrupted or version ≤ 8 | Logged at warn/info level + reset to `.empty`（v8 及更早整体重置，全量重建）; next scan rebuilds from scratch |

## Cross-Provider Cache Semantics (Antigravity vs Codex)

> Companion section: see `codex.md` § Cross-Provider Cache Semantics for the Codex side of this comparison.

Antigravity and Codex report cache reads using **incompatible semantic models**. Any code that aggregates token usage across both providers must be aware of these differences, or it will double-count or mis-attribute.

### Antigravity model: `inputTokens` and `cacheReadTokens` are MUTUALLY EXCLUSIVE

`inputTokens` is **only the uncached input**. Tokens that were served from the cache are reported as `cacheReadTokens`, not as part of `inputTokens`. The two are separate buckets; their sum is the total input that the model "saw":

```swift
// Models/TokenAccounting.swift — TokenAccountingCatalog.antigravity is
// TokenAccountingDefinition(input: .uncachedOnly, output: .reasoningIncluded):
// raw outputTokens already includes thinking, so the catalog splits it
// (Output = rawOutput − reasoning, Reason = reasoning) and the raw counters
// map to conservation-safe buckets without any per-provider arithmetic:
let buckets = TokenAccountingCatalog.antigravity.normalizedBuckets(
    rawInput: event.inputTokens,
    cacheRead: event.cacheReadTokens,
    rawOutput: event.outputTokens,
    rawReasoning: event.reasoningTokens
)
buckets.cacheInclusiveInput   // = input + cacheRead（sample 层的兼容口径）
buckets.totalTokens          // = input + cacheRead + output + reasoning
//                             ^ cacheWriteTokens intentionally excluded
// LocalDailyTokenUsage.cacheHitRate = cacheRead / (cacheRead + input)
```

`cacheWriteTokens` is bookkeeping (writes to a future read cache) and is **never** part of `totalTokens`. Raw `outputTokens` already includes reasoning (`outputTokens == thinkingOutputTokens + responseOutputTokens` on 100% of measured events); the catalog's `.reasoningIncluded` relation splits it so the normalized `Output` bucket excludes thinking.

### Codex model: `cachedInputTokens` is a SUBSET of `inputTokens`

`inputTokens` is the **full** input that the API charged for, and `cachedInputTokens` is the subset of those tokens that were served from cache. Adding them together double-counts. See `codex.md` for the full breakdown.

### Comparison table

| Dimension | Antigravity | Codex |
|---|---|---|
| Cache bucket | Independent, parallel to `inputTokens` | Subset of `inputTokens` |
| Total input = | `inputTokens + cacheReadTokens` | `inputTokens` (already includes cached) |
| `cacheWrite` | `.db` 直读后恒 0（usage 子消息不提供；本就不进 `totalTokens`，仅诊断可见性损失） | **Not reported** |
| Cache hit rate | `cacheRead / (cacheRead + input)` | `cached / input` (mathematically equivalent) |
| Per-round data | 4 fields per LLM call（db usage 子消息；cacheWrite 不提供） | 4 fields per `token_count` event (`input_tokens`, `cached_input_tokens`, `output_tokens`, `reasoning_output_tokens`) |
| Data source | Local `.db` `gen_metadata`（阶段二b直读；原 RPC `GetCascadeTrajectoryGeneratorMetadata` 已退役） | Local JSONL `~/.codex/sessions/**/*.jsonl` (near-realtime) |
| Data lag when source idle | 懒刷新落盘延迟（IDE 关闭/切换会话才 flush `.db`，见 § Lazy .db write） | None — CLI flushes JSONL continuously |
| Reasoning vs output | Raw `outputTokens` includes reasoning; normalized `Output = rawOutput − reasoning` | Summed into `outputTotal = output + reasoning` |
| Total tokens formula | `input + cacheRead + outputTokens`（raw output 已含思考，规范化后 = 四桶和；excludes `cacheWrite`） | `input + output + reasoning` (already includes cached) |

### Why this matters in practice

- **UI stacked bars render differently.** Antigravity renders 4 effective segments (`input`, `cacheRead`, `output`, `reasoning`——`cacheWrite` 恒 0 的诊断段随 `.db` 数据源退化); Codex has 4 (`uncached = input - cached`, `cached`, `output`, `reasoning`). Drawing them with the same `totalSegments` assumption misaligns colors and widths.
- **Total computation differs.** A naive `total = input + cached + output + reasoning` over-counts Codex by `cached`.
- **cacheWrite asymmetry.** Antigravity's "future cache" segment is just absent on the Codex side; the UI either hides the segment or shows 0 for Codex.
- **Cross-provider sum**: only `input (uncached)`, `cacheRead/cached`, `output`, `reasoning` are comparable. `cacheWrite` is Antigravity-only.

### Recommended normalized abstraction (cross-provider view)

To compare or sum daily usage across both providers, normalize both into a single shape at the provider boundary. The model below is what `CodexFetcher` and `AntigravityLocalUsageScanner` should produce (or what a view-layer adapter should derive) before any aggregation:

```swift
/// Provider-agnostic daily token usage.
/// All four `input`/`cacheRead`/`output`/`reasoning` categories are
/// MUTUALLY EXCLUSIVE (parallel buckets) regardless of source.
struct NormalizedDailyUsage: Equatable, Sendable, Identifiable {
    let dayStart: Date
    let uncachedInput: Int   // Antigravity: inputTokens;            Codex: inputTokens - cachedInputTokens
    let cacheRead: Int       // Antigravity: cacheReadTokens;        Codex: cachedInputTokens
    let cacheWrite: Int      // Antigravity: cacheWriteTokens;       Codex: 0
    let output: Int          // Antigravity: outputTokens;           Codex: outputTokens
    let reasoning: Int       // Antigravity: reasoningTokens;        Codex: reasoningOutputTokens
    let turns: Int           // Antigravity: inferred turn count; Codex: user prompt count
    let rounds: Int          // Both: LLM call count

    var id: Date { dayStart }
    var totalInput: Int { uncachedInput + cacheRead }
    var totalOutput: Int { output + reasoning }
    var totalTokens: Int { uncachedInput + cacheRead + output + reasoning }
    var cacheHitRate: Double? {
        let denom = totalInput
        guard denom > 0 else { return nil }
        return Double(cacheRead) / Double(denom)
    }
}
```

**Mapping rules** (apply at the provider boundary, before persistence):

| From provider | → `uncachedInput` | → `cacheRead` | → `cacheWrite` | → `output` | → `reasoning` |
|---|---|---|---|---|---|
| Antigravity `AntigravityDailyUsage` | `inputTokens` | `cacheReadTokens` | `cacheWriteTokens` | `outputTokens` | `reasoningTokens` |
| Codex `DailyTokenUsage` | `max(inputTokens - cachedInputTokens, 0)` | `cachedInputTokens` | `0` | `outputTokens` | `reasoningOutputTokens` |

After normalization, cross-provider sum, average, and chart rendering can treat the two providers as a single data source.

## Recent Issues & Fixes (July 2026)

> 本节三条均为本地 RPC 时代的历史修复记录（多 workspace server 快照、空 RPC 保留、
> 纯 RPC turns 推断）；阶段二b起 scanner 直读 `.db`，其中第 2 条的 v8 迁移语义被
> v9 整体重置取代（见 § Local Token Usage Scanner 的 index schema）、第 3 条的
> stepIndices 间隙推断被 `step_type=14` 直计取代。

### 1. Multi-Workspace & Multi-Instance Port Discovery
- **Issue**: When running multiple workspaces, each spawns its own isolated `language_server` process listening on a random port, and token usage metadata lives in the memory of the process running that workspace. The original implementation only queried the first process returned by `discoverServer()`, so the other workspaces reported 0 events.
- **Fix**: The metadata path now lists **all** usable servers (`defaultMetadataServers()` behind `discoverMetadataServers()`) and the scanner reuses that one snapshot for every dirty session. `getTrajectoryMetadata(sessionId:offset:servers:)` queries them in order and returns the first page with `metadataEntryCount > 0`; a server that doesn't own the cascade is skipped and logged at info level, so a mismatching server no longer floods the log with `trajectory not found` HTTP 500s. (The quota path intentionally still stops at the first server that exposes a port — `discoverServerAsync()`.)

### 2. Empty-RPC retention and cache migration
- **Issue**: A session queried against the wrong workspace server, or a server that is not ready yet, can return an empty event list. Treating that response as a successful empty session would freeze the cache at zero.
- **Fix**: Empty RPC responses are not trustworthy success: the scanner retains last-good daily/samples data, does not advance the file fingerprint, and retries on a later scan — now bounded by the three-strike / two-strike convergence rules documented above. Cache indexes are migrated to **v8** (`loadIndex` accepts v2…v7); the migration clears per-event samples (`samplesBySession`) so every existing session is forced through one offset=0 full RPC — originally because v5 and earlier samples could come from the removed SQLite path, and since v8 because samples gained `durationSeconds` and the thinking-caliber fix (raw output includes reasoning) requires rebuilding both samples and daily buckets.

### 3. Pure-RPC Turn/Round approximation
- **Issue**: The removed SQLite implementation could count `step_type=14/15` directly, but it did not work uniformly across `.db` and `.pb` formats and required reading the IDE's database files.
- **Fix**: The current scanner reads only file metadata and obtains token events plus `stepIndices` through `GetCascadeTrajectoryGeneratorMetadata` for both formats. Rounds count timestamped RPC events; turns are inferred from step-index gaps and are explicitly best-effort.

---

## 已验证的远端配额与本地凭据事实（2026-11-08，阶段一实施依据）

> 以下实测记录是 § Remote Quota Path (Phase 1) 的实施依据；阶段一起 runtime 额度
> 路径已是「Keychain 凭据 + 远端 Google API」（`fetchAvailableModels` 仍未接入运行时，
> 保留为调研记录）。

**Keychain 凭据**（service=`gemini`，account=`antigravity`）：值为 `go-keyring-base64:` 前缀 +
base64 → JSON：`token.{access_token, token_type, refresh_token, expiry(ISO 带时区), expires_in=3599}`、
`auth_method="consumer"`、`id_token_email`、`writer_id`。活动 token 由运行中的客户端自行刷新；
`~/.gemini/jetski-standalone-oauth-token` 仅账户切换时落盘（会过期，本机实测滞后 5 天）；
`antigravity-cli/antigravity-oauth-token` 本机不存在——agy CLI 与 IDE 共用该 Keychain 条目。

**远端配额端点**（用 Keychain access_token 实测 HTTP 200）：

- `POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`，body `{}`，
  UA 必须为 hub 身份 `antigravity/hub/<version> (aidev_client; os_type=darwin; arch=arm64)`——裸
  `antigravity/cli/…` 身份拿不到 Gemini 4 Argon 等分组（AntigravityManager 记录版本下限
  `HUB_CLIENT_MIN_VERSION = 2.26.0`）；主机回退序 Daily → 生产 `cloudcode-pa` → sandbox，
  仅 401 终止。响应 `{groups:[…]}` 与本地 RPC 同形（只少一层 `response` 包装）。
- `POST …/v1internal:fetchAvailableModels`：返回 26 个模型的目录（modelId + displayName +
  `quotaInfo.{remainingFraction, resetTime}` + `supportsThinking`）及 `deprecatedModelIds` 迁移
  通道；bare 与 hub UA 结果一致（含 Argon）。注意 displayName 有 rebrand 错位
  （`gemini-2.5-flash` 标 "Gemini 3.5 Flash Lite"），归池/计价以 modelId 为准；配额值是**组级
  广播**（同组模型同值同 resetTime），相对 quota summary 无逐模型增量信息。
- IDE 自身行为佐证：language_server log（`~/.gemini/antigravity/log/cli-*.log`）每约 6 分钟打一次
  `fetchAvailableModels`——若改走远端轮询，频率参照应 ≥300s（当前 provider 配置 60s 不适用）。

**刷新语义**：access_token 有效期约 1 小时，由客户端在 Keychain 内自行续期；监控侧不做
refresh_token 流程。读到 `token.expiry` 已过期不发远端请求、转入本地回退（2.4.2）；
远端 401 落到同一回退；回退也失败才抛 `credentialExpired`
（「token 已过期：打开 Antigravity 可继续监控额度，重新登录可刷新凭据」）。

## Helper Script

For raw quota export outside the menu app:

```bash
./scripts/export-antigravity-quota.sh /tmp/antigravity-quota.json
```

阶段一起（2026-11-08）脚本与 app 同路径（不再依赖 Antigravity 运行、不走进程发现）；
**2.4.2 起脚本仍不做本地回退**（保持纯远端直连，过期文案与 app 同步）：

1. `security find-generic-password -s gemini -a antigravity -w` 读登录钥匙串凭据，
   `go-keyring-base64:` 前缀 + base64 → JSON（python3 解析；凭据原文经环境变量传给
   python，token 不出现在 argv），取 `token.access_token` 与 `token.expiry`
2. 本地判过期：`now >= expiry` 直接报错退出（提示「token 已过期：打开 Antigravity
   可继续监控额度，重新登录可刷新凭据」），不发任何网络请求
3. 未过期则 POST `v1internal:retrieveUserQuotaSummary`，UA / 请求头与主机回退序同
   § Remote Quota Path (Phase 1)（版本读 `/Applications/Antigravity.app/Contents/Info.plist`
   的 CFBundleShortVersionString，读不到回退 2.26.0；仅 401 终止，报错文案同第 2 步）
4. prints or writes the raw JSON（带路径参数时原子落盘 0600）

> 核对基线：2026-11-08 · 代码 02a9f30
