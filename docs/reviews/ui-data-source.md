# 界面展示数据 · 数据源分类梳理

## 1. Review 信息

- Review 分支：`2.0.0`（自 `main` @ `bd26c3a` 新建）
- Review 日期：2026-10-23
- Review 范围：**界面展示的所有数据**，按「最终从哪个载体读出来」分类
- Review 口径：见 §2
- 证据基准：`Sources/LLM-monitor/` @ `bd26c3a`，spec 交叉核对 `spec/overview.md` / `runtime.md` / `source-map.md` / `ui/*`

## 2. 口径定义（本次分类的边界）

本次要回答的是**处理后**的展示数据**落在哪里**，不是数据在上游从哪来。

| 问 | 不问 |
|---|---|
| 界面上的这个数字，最终是从哪个**本地载体**读出来的？ | 这个数字在业务上源自哪个模型 / 哪个客户端 / 哪个远端 API |
| SQLite 数据库？文件？远端接口？还是纯内存算出来的？ | 各 provider / 各 client 的数据来源链路 |

判定规则：

- **归到载体的是「最后一步读盘/发请求的位置」**，不是中间加工环节。
- 打包进 `.app` 的资源（价格表、节假日表、图标）单独归为**打包资源**——它们不是用户数据，但确实决定界面上的数值。
- 远端 HTTP 与本机 loopback RPC 分开算：Antigravity 走的是 `127.0.0.1` 上的 IDE 进程，性质上更接近「本地服务」而非「远端」。
- App 自己写的缓存副本（`token-monitor/*.json` 等）单独归为**缓存副本**——它们是派生结果，不是权威数据源。

---

## 3. 结论速览

**界面上的数据分成三大块，边界很干净：**

| 数据块 | 界面位置 | 载体性质 |
|---|---|---|
| **① 本地用量**（token / 命中率 / 金额 / 7 天柱图） | 菜单主区、设置页客户端 tab、popover 卡片下半 | **3 个 token SQLite 账本 + 3 类文件 token 账本 + Antigravity 本机 RPC**；另有 2 个辅助 SQLite 库 |
| **② provider 远端额度**（剩余 %/ 重置时间 / 余额 / 高峰） | 边缘窗双环、菜单底部状态条、菜单栏图标、popover 卡片上半 | **4 家 provider 的公网 HTTP 接口**（同一 provider 可有多个端点）+ **1 个本机 RPC**，只在内存 |
| **③ 配置 / 系统 / 资源** | 设置页表单、状态栏配色、节日倍率、图标 | `config.json` + 系统 API + 打包资源 |

**最关键的一条结构事实：一张 popover 卡片同屏混着三类载体**，代码用一条分隔线显式切开——

```
ProviderCardView.swift:252-263  「上面来自 provider 接口、下面来自本地扫描」
```

上面「Plan 详情」= provider HTTP 或 Antigravity 本机 RPC；下面「额度窗口」表 + 「最近 7 天 token 用量」卡 = SQLite / 文件 / Antigravity 本机 RPC / 打包价格表。

**价格表来自打包的 `Resources/ModelPricing.json`**，不是代码常量，也不是远端——所有「金额」类读数都由它决定。

---

## 4. 全部落盘载体总表

### 4.1 SQLite 数据库（5 个库，其中 3 个承载真实 token 数据，2 个为辅助库）

| 数据库路径 | 表 | 归属 | 打开位置 | 服务于哪些界面读数 |
|---|---|---|---|---|
| `~/.minimax/v2/sqlite/runtime-state.sqlite` | `local_runtime_token_usage`（token 主账本）<br>`local_runtime_message_rows`（思考/输出字符）<br>`local_runtime_sessions`（session 元信息 + 模型名 join） | MiniMax Code · **token 账本** | `MinimaxLocalUsageScanner.swift:58-64`<br>`MinimaxDBReader.swift:103,116,253,419` | minimax 卡今日/7 天 token、round/turn、reasoning 守恒分摊、模型名 |
| `~/.zcode/cli/db/db.sqlite` | `model_usage`（token 主账本）<br>`part`（reasoning 文本） | ZCode · **token 账本，多 provider 共享** | `GlmZcodeLocalUsageScanner.swift:43-49`<br>`GlmZcodeDBReader.swift:82,162` | GLM 卡本地用量；**同库同表**按 provider 前缀 LIKE 切出 minimax / deepseek 分片行 |
| `~/.zcode/v2/tasks-index.sqlite` | `off_peak_tasks` | ZCode · **辅助库** | `GlmZcodeLocalUsageScanner.swift:61-66`<br>`GlmZcodeOffPeakReader.swift:14,23` | GLM 卡「闲」行（闲时任务时间窗口）；本身不承载 token 数 |
| `~/.local/share/opencode/opencode.db` | `message`<br>`part` | OpenCode · **token 账本** | `OpencodeUsageScanner.swift:20-26`<br>`OpencodeDBReader.swift:30,90,207` | 经 `clientBindings[]` 并入各 provider 卡的本地用量投影（opencode 自身不是 provider） |
| `~/.gemini/antigravity/conversations/<id>.db` | `steps`（仅 `step_type=15`） | Antigravity · **辅助库** | `AntigravityFilesystem.swift:66`<br>`AntigravityStepTimestampReader.swift:28,32` | 只在 RPC 事件缺时间戳时回填时间；不承载 token 数，见 §6 陷阱 ① |

统一读策略：`SQLiteConnection`（`Infra/SQLiteConnection.swift:125`），脏 WAL / 锁冲突时退到 `$TMPDIR/llm-monitor-sqlite/` 副本（`Infra/SQLiteTempCopy.swift:198-200`）。

### 4.2 文件型载体

| 路径 | 格式 | 读取者 | 服务于哪些界面读数 |
|---|---|---|---|
| `~/.codex/sessions/**/*.jsonl`<br>`~/.codex/archived_sessions/**/*.jsonl` | JSONL | `CodexLocalUsageScanner.swift:776-777,860` | ChatGPT 卡「本地 token 明细」行（`ChatGPTPlanModelRow`） |
| `~/.codex/auth.json` | JSON（JWT payload） | `CodexFetcher.swift:72-88,347-357` | 卡片 Account Info 的账号邮箱 / 套餐档位；`hasLocalAuth()` 决定「未配置」状态 |
| `~/.dsh/sessions/**/session.jsonl`<br>`**/*.jsonl.zstd`、`*.jsonl.zst` | JSONL / zstd 压缩 | `DshLocalUsageScanner.swift:62-72,120-134,738` | 经投影并入各 provider 卡的本地用量 |
| `~/.gemini/antigravity-cli/brain/<id>/transcript.jsonl`<br>`chunks/transcript/*.jsonl` | 明文 JSONL | `AgyLocalUsageScanner.swift:126-131,603` | Antigravity 卡的 agy 用量段 |
| `~/.gemini/antigravity-cli/log/cli-YYYYMMDD_HHMMSS.log` | 纯文本 go log | `AgyLocalUsageScanner.swift:135-140,482` | **agy 的模型名**（`Resolving model <name>` 正则，按文件名时间线 join 回 transcript） |
| `~/.minimax/v2/sessions/<rel>/llm-call.json` | JSON | `MinimaxSessionModelResolver.swift:62-68` | **minimax 的真实模型名**（账本 `model` 列已被 schema migration 清空，不读它会把 M3.1 Flash 记成 M3）→ 直接决定定价 |
| `~/.zcode/v2/logs/YYYY-MM-DD.log` | 纯文本 + 行尾 JSON | `GlmZcodeBalanceLogReader.swift:9-12,160-175` | GLM 卡的**活动套餐余额**（🎁 套餐名 94% (283M/300M) 到期） |
| `~/.gemini/antigravity/conversations/*.{db,pb}` | SQLite / protobuf | `AntigravityFilesystem.swift:30-44,149-153` | 两种格式都用于指纹 diff；`.db` 还可回填 RPC 缺失的 timestamp，`.pb` 不解析内容 |

### 4.3 远端 HTTP 接口（额度数据，只在内存，不落盘）

| provider | 端点 | 位置 | 填充的字段 |
|---|---|---|---|
| ChatGPT Plan | `GET https://chatgpt.com/backend-api/wham/usage` | `CodexFetcher.swift:37` | 5h/周窗口剩余 %、重置时间、账号邮箱、套餐档位 |
| ChatGPT Plan | `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` | `CodexFetcher.swift:38` | 重置卡清单（数量 / 最近到期 / 逐张明细） |
| GLM Coding Plan | `GET https://open.bigmodel.cn/api/monitor/usage/quota/limit` | `GlmCodingPlanFetcher.swift:51` | 5h/周窗口剩余 %、`nextResetTime`、套餐档位 |
| MiniMax Token Plan | `GET https://www.minimaxi.com/v1/token_plan/remains` | `MinimaxTokenPlanFetcher.swift:44` | 双窗口剩余 %、窗口起止 |
| DeepSeek | `GET https://api.deepseek.com/user/balance` | `DeepseekFetcher.swift:35` | 余额明细（充值/赠金）、`planLabel` |
| 节假日源 | `GET https://cdn.jsdelivr.net/npm/chinese-days/dist/chinese-days.json` | `HolidayCalendar.swift:205` | 节假日表 → **高峰/闲时窗口判定** → 峰谷定价倍率 |

### 4.4 本机 RPC（非公网，Antigravity 专用）

Antigravity 通过 IDE / agy CLI 的 `language_server` 进程暴露 gRPC-over-HTTPS，端口由 `lsof` 运行时探测（`AntigravityProcessDiscovery.swift:221-234`），端点无静态 URL。

| 路径 | 位置 | 填充的字段 |
|---|---|---|
| `POST /exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary` | `AntigravityFetcher.swift:81` | 额度（5h/周 %、重置时间）、`planLabel` |
| `POST .../GetUserStatus` | `AntigravityFetcher.swift:67` | 账号邮箱、用户状态 |
| `POST .../GetLoadCodeAssist` | `AntigravityFetcher.swift:77` | 套餐/账号补充信息 |
| `POST .../GetCascadeTrajectoryGeneratorMetadata` | `AntigravityFetcher.swift:207` | **Antigravity 本地 token 用量的唯一来源**（per-event token、turn/round 推算），响应上限 64 MiB |

### 4.5 打包资源（随 app 发布，决定界面数值）

| 资源 | 位置 | 决定什么 |
|---|---|---|
| `Sources/LLM-monitor/Resources/ModelPricing.json` | `ModelPricingCatalog.swift:167-172` | **所有金额**（今日总额 / 段金额 / 行金额 / 7 天价值列 / 未定价清单） |
| `Sources/LLM-monitor/Resources/ChinaHolidays.json` | `HolidayCalendar.swift:127` | 高峰/闲时判定 → 高峰指示器 + 峰谷倍率 |
| `Resources/BrandLogos/*`、`IconPreview/*` | `BrandLogoView.swift:36-39`、`MenuBarLabel.swift:227-229` | 卡片 logo、菜单栏图标、边缘窗圆心 |

### 4.6 配置文件与缓存副本

| 路径 | 性质 | 界面用途 |
|---|---|---|
| `~/Library/Application Support/LLM-monitor/config.json` | **权威配置** | provider 开关 / API Key / 绑定矩阵 / 状态栏配色 / provider 顺序 / 边缘窗形态 / Bark / 节假日源 |
| `.../token-monitor/{antigravity,minimax,glm-zcode,opencode,dsh,agy}.json` | 派生 scanner 快照（`TokenMonitorPaths.swift:18-28`） | scanner 构造时读取完整快照，作为冷启动 `lastResult`；扫描时用于 fingerprint 命中、复用或增量重建。它是生产读路径，但不是原始账本，也不能单凭缓存恢复证明本次扫描已验证 |
| `.../last-refresh.json` | 派生缓存（`AppState.swift:188-196`） | 菜单 footer「更新于 HH:mm」跨重启延续 |
| `.../notification-state.json` | 派生缓存 | 通知边沿检测基线，**不上界面** |
| `.../holidays-cache.json` | 缓存副本 | 节假日表缓存（权威是 CDN / 内置 bundle） |
| `.../log.txt`、`instance.lock` | 运行时 | 日志 / 单实例锁，**不上界面** |

### 4.7 系统 API（既非文件也非 HTTP）

| 来源 | 界面读数 |
|---|---|
| IOKit `IOPMCopyAssertionsByProcess` | 菜单 header「N 个应用正在阻止休眠」、设置页节能 pane 的睡眠锁明细 |
| IOKit `IOPMCopyPMPreferences` / `/usr/bin/pmset -g custom` | 电源参数矩阵、AC 自动休眠分钟数 |
| `SMAppService.mainApp` | 菜单 footer「自启 ✓/✗」、设置页登录项状态 |
| `Bundle.main` Info.plist | 设置页「版本 X（Y）」 |

---

## 5. 按界面面的数据元素清单

### 5.1 主菜单面板（`MenuContentView` + `HarnessUsageMenuView`）

| 显示元素 | 渲染位置 | 载体 | 具体路径/表/端点 |
|---|---|---|---|
| 今日总 token | `HarnessUsageMenuView.swift:67` | 内存派生 | ← `HarnessTodaySummary.summarize` (`ClientUsageAggregation.swift:539`) ← 各本地账本 |
| 缓存命中率 | `HarnessUsageMenuView.swift:74` | 内存派生 | `cacheRead/(input+cacheRead)` (`ClientUsageAggregation.swift:557-563`) |
| 总金额（跨币折算） | `HarnessUsageMenuView.swift:80` | 内存派生 × 打包资源 | `ModelPricing.json` × token；USD→CNY 硬编码 ×7 (`MixedCurrencyEstimate.swift:17`) |
| 三段占比条 | `HarnessUsageMenuView.swift:98` | 内存派生 | `TokenBucketBar.swift:60-71` |
| 新鲜度时钟「计算中…」/ `HH:mm` | `HarnessUsageMenuView.swift:91-94` | 内存派生 | `projection.scannedAt` ← scanner 快照时间 |
| 客户端段名 / 段 token / 段金额 | `HarnessUsageMenuView.swift:169,174,177` | 内存派生 | `ClientUsageAggregation.swift:526-527` |
| 截断提示「部分较早会话未计入」 | `HarnessUsageMenuView.swift:191-216` | 内存派生 | scanner 预算位（DSH `DshLocalUsageScanner.swift:326`、agy `AgyLocalUsageScanner.swift:426`） |
| 模型行：名称 / 条 / token / 命中率 / 金额 | `HarnessUsageMenuView.swift:408-425` | 内存派生 × 打包资源 | 名称来自账本样本；金额来自 `ModelPricing.json` |
| 底部 provider 状态胶囊（`HH:mm` / 需重试 / 未配置） | `HarnessUsageMenuView.swift:367` | **远端 HTTP** | `status.lastRefreshedAt` + `status.state` |
| 「+N」折叠计数 | `HarnessUsageMenuView.swift:328` | 内存派生 | `ProviderStatusStrip.snapshot` (`ClientUsageAggregation.swift:653-671`) |
| provider 排列顺序 | `MenuContentView.swift:240` | 配置文件 | `config.json` → `providerCardOrder` |
| footer「更新于 / 下次 / 就绪」 | `MenuContentView.swift:414-421` | 内存 + 派生缓存 | `last-refresh.json` + scheduler |
| footer「自启 ✓/✗」 | `MenuContentView.swift:427` | 系统 API | `SMAppService` |
| 「N 个应用正在阻止休眠」 | `MenuContentView.swift:138-140` | 系统 API | IOKit |

**菜单面板完全没有 provider 远端额度明细**——正文区只回答「哪个客户端今天烧了多少 token」，额度读数在底部一行状态条里，展开成卡片才看得到。

### 5.2 边缘状态窗（`EdgeDockContentView` + popover）

**常驻面（双环）—— 100% 远端额度，零本地账本：**

| 显示元素 | 渲染位置 | 载体 |
|---|---|---|
| 外环弧长（5h 有效额度 = min(5h, 周×N)） | `EdgeDockContentView.swift:249-267` | 远端 HTTP → `EdgeDockEntry.swift:134-136,168-171`（读 `status.lastSuccess`） |
| 外环颜色 / 内环弧长（周剩余，不乘倍率） | `EdgeDockContentView.swift:262-282` | 远端 HTTP → `EdgeDockEntry.swift:156-160,220-226` |
| 圆心品牌图标 | `EdgeDockContentView.swift:289` | 打包资源 |
| 圆心「周更紧」升级点 | `EdgeDockContentView.swift:291-306` | 内存派生 |
| 环底槽（灰环） | `EdgeDockContentView.swift:366-388` | 常量 |
| 环色三档 / 圆环顺序 | `EdgeDockContentView.swift:53-55,45-51` | 配置文件（`statusBarHealthColors` / `providerCardOrder`） |

**popover 卡片—— 同屏混三类载体：**

| 卡片区段 | 显示元素 | 载体 |
|---|---|---|
| 卡片头 | provider 名 | 配置文件 |
| 卡片头 | 额度新鲜度胶囊 | 远端 HTTP（`fetchedAt`）+ 派生缓存（`last-refresh.json`） |
| 卡片头 | Account Info 邮箱 / 套餐档位 | 文件（`~/.codex/auth.json` JWT）/ 本机 RPC（Antigravity） |
| **上半「Plan 详情」** | 每 model 5h/周剩余 %、周瓶颈括号值、重置时刻+倒计时、分段进度条、高峰倒计时行 | **远端 HTTP**（`ProviderCardView.swift:252-263` 明写「上面来自 provider 接口」） |
| 上半 | GLM 活动套餐余额 | **文件** `~/.zcode/v2/logs/YYYY-MM-DD.log` |
| 上半 | DeepSeek 余额行 | 远端 HTTP |
| 上半 | 重置卡清单 | 远端 HTTP（reset-credits 端点） |
| **下半「额度窗口」表** | 5h / 周 行 token | **SQLite + 文件 + Antigravity 本机 RPC**（各客户端来源） |
| 下半 | 「今」行四桶 + token | SQLite + 文件 + Antigravity 本机 RPC |
| 下半 | 「闲」行（GLM 闲时） | **SQLite** `~/.zcode/cli/db/db.sqlite` |
| 下半 | 命中 / 产出比 / 思考占比 | 内存派生 |
| 下半 | 「价值」金额 | **打包资源** × 内存派生 |
| 下半 | 「重置日期」格 | **混合**：5h/周行 = 远端 HTTP；今/闲行 = 恒 `—`（`ProviderCardDerived.swift:266,274`） |
| **下半「最近 7 天 token 用量」卡** | 7 天柱图 / 日表格 / 价值列 | SQLite + 文件 + Antigravity 本机 RPC + 打包资源 |
| 下半 | 本地用量新鲜度胶囊 | 内存（scanner 快照时间） |

**同一个「重置日期」列跨了两种载体**——这是本表里最容易踩的一处。

### 5.3 设置窗口

| 区域 | 显示元素 | 载体 |
|---|---|---|
| 常规 pane | 版本号 / 构建号 | `Bundle.main` Info.plist |
| 常规 pane | 状态栏图标预览（6 张） | 打包资源 + SF Symbol（内存合成） |
| 常规 pane | 节假日状态行（年份 / 抓取于 / 来源） | 缓存文件 `holidays-cache.json` + 打包 `ChinaHolidays.json` |
| 常规 pane | 开机自启状态文案 | 系统 API `SMAppService` |
| 常规 pane | Bark 测试推送结果 | 远端 HTTP |
| provider pane | 高峰时段定义（GLM 14–18 / DeepSeek 双窗 2×） | 代码常量 |
| provider pane | GLM「解析活动套餐余额日志」开关 | 配置文件（开关开启后才读 `~/.zcode/v2/logs/`） |
| provider pane | 「立即刷新」在飞指示 | 内存态 |
| **客户端 tab** | 客户端 tab 条 + provider 计数 | 内存派生 |
| **客户端 tab** | 每 provider 总 Token / 7 天柱图 / 汇总 token·命中率·价值 / Input·Cache·Output·Reason 分项 / 未定价清单 / 最近扫描时间 / 截断提示 | **SQLite + 文件 + Antigravity 本机 RPC + 打包资源**（与菜单同源） |
| 节能 pane | 睡眠健康度 / 睡眠锁明细 / 电源参数矩阵 | 系统 API + `/usr/bin/pmset -g custom` |

**设置窗口不显示任何 provider 配额/余额快照**——provider pane 只有表单 + 按钮 + 只读高峰口径文案。

### 5.4 菜单栏图标（`MenuBarLabel`）

| 显示元素 | 载体 |
|---|---|
| 右下状态点（绿/橙/红） | 远端 HTTP（各 provider 抓取状态聚合，`AppState+Metrics.swift:16-61`） |
| Icon Duo 左右额度弧 / 中心扇形 / 底部三点 | 远端 HTTP（`QuotaInfo` 窗口剩余比例） |
| 顶部节能点 | 系统 API（睡眠健康度） |
| 「App 图标」样式底图 | 打包资源 |

---

## 6. 分类上的关键陷阱

### ① Antigravity 的本地用量 token **来自本机 RPC，不来自 DB 或会话文件**

它的 `.db` / `.pb` 会话文件用于发现、指纹比较；token / turn / round 全部来自 `GetCascadeTrajectoryGeneratorMetadata` 本机 RPC（`AntigravityFilesystem.swift:51` 明确写 "Token values remain sourced exclusively from the RPC response"）。SQLite 只在 RPC 事件缺时间戳时读 `steps` 表 `step_type=15` 做回填；`.pb` 格式不解析内容，只 stat 指纹。这个本机 RPC 同时承载用量与配额相关的不同请求，不能把 Antigravity 本地 token 归入数据库或文件账本。

把它归成「SQLite 来源」是错的。

### ② MiniMax Code 的一个数字横跨数据库与文件

token 数在 SQLite `local_runtime_token_usage`；**真实模型名在文件** `~/.minimax/v2/sessions/<rel>/llm-call.json`（账本 `model` 列已被 schema migration 清空）。不读那个文件，M3.1 Flash 的用量会被归到 M3 名下——**定价直接算错**。

### ③ ZCode 一个库喂三张卡

`~/.zcode/cli/db/db.sqlite` 的 `model_usage` 表同时供给 GLM 卡、MiniMax 卡、DeepSeek 卡的 provider 分片行（同库同表，换 provider 前缀 LIKE）。

### ④ GLM 活动套餐余额是「日志副产物」

权威响应由 ZCode 自己轮询产生并落进 `~/.zcode/v2/logs/`，App 只是**读日志的旁路观察者**（`GlmZcodeBalanceLogReader.swift:5-7`）。日志轮转 / 清理会让余额消失，且只回退到昨天。

### ⑤ 所有金额的源头是打包资源

`Resources/ModelPricing.json` 是唯一价格源（`ModelPricingCatalog.swift:167-172`），不是代码常量也不是远端。改价目表 = 改 app 资源，不是改配置。

### ⑥ 缓存副本是冷启动与复用读路径，但不代表本次已验证

`token-monitor/*.json` 是 scanner 的派生落盘快照。多个 scanner 在构造时调用 `loadCachedResult`，把恢复出的完整用量结果设为 `LocalUsageScannerBase.lastResult`（例如 `MinimaxLocalUsageScanner.swift:124-131`、`LocalUsageScannerBase.swift:98-100`）；GLM / OpenCode 的 `SingleDBSnapshotScanner` 也在构造时加载缓存（`SingleDBSnapshotScanner.swift:93-103`）。后续扫描还会读取索引并按 fingerprint 复用或重建。因此缓存确实进入生产读路径；但缓存恢复不等于当前源已扫描验证，展示可先用缓存，作为同步上报的权威快照则要另看当前 reconcile 的验证与完整度。

### ⑦ Codex 本地用量没有磁盘缓存

其余 6 个 scanner 都有 `token-monitor/*.json`，Codex 没有（进程内 `CodexUsageDetailsCache` + LRU，容量 16）。冷启动必须重扫 JSONL。

### ⑧ 节假日表会间接改变金额

高峰/闲时判定读 `HolidayCalendar.shared`（缓存文件 / 内置 bundle / CDN），而高峰倍率会乘进 `ModelPricingCatalog.estimate`——**节假日表换了，界面上显示的金额也会变**。

### ⑨ 日级总量与模型样本明细的完整度不同

日桶可以在样本列表截尾前完成聚合；Codex scanner 会先聚合日用量，再把 `recentSamples` 限制到 `maxRecentSamples`（`CodexLocalUsageScanner.swift:390-411`）。所以完整的日级四桶不保证模型行完整，模型金额也可能只覆盖保留样本。Fleet 上报与展示应分别携带日总量完整度和模型明细/金额覆盖度；不能用模型行重算日总量，也不能由完整日桶推导完整的七日模型金额。

---

## 7. spec 与代码的出入

以代码为准，记录在案（本次未改 spec）：

| # | 位置 | 偏差 |
|---|---|---|
| 1 | `spec/config.md:124` | 写 `ModelPricingCatalog.lastUpdated` 为 `2026-10-01`，代码实为 `2026-10-20`（`Resources/ModelPricing.json:2`） |
| 2 | `spec/ui/edge-dock.md:626` + `spec/providers/antigravity.md:1151` | 称 popover 头时间戳点击触发 `AppState.refreshAll` 并经 `\.cardManualRefreshAction`——该符号**只存在于 spec，`Sources/` 里 0 命中**，实际是 `cardQuotaRefreshAction`（`ProviderCardView.swift:86,120`）→ `AppState.refreshOne(providerID:)` |
| 3 | `spec/ui/edge-dock.md:13` | `edgeDock` 字段集不全，代码另有 `screenUUID` / `compactSize` / `independentRingColors` |
| 4 | `spec/ui/menu-and-cards.md:152` | ASCII 布局图里的长截断句已过时，代码渲染短句「部分较早会话未计入」，长句只在 `.help` tooltip |
| 5 | `spec/ui/settings.md:190` | 「Toggle label」记作 `开机自启动`，代码的 toggle 行文案是「开启开机自启动」（`SettingsGeneralPane.swift:191`；「开机自启动」是 section 标题，同文件 `:190`） |

**spec 覆盖缺口**（不是冲突，是没写）——以下载体在 `spec/` 各文档中均未登记具体路径：

- `~/.minimax/v2/sqlite/runtime-state.sqlite`（及其 3 张表）
- `~/.dsh/sessions/*.jsonl.zstd` / `.jsonl.zst`
- `~/.gemini/antigravity-cli/brain/`
- `~/.zcode/v2/logs/YYYY-MM-DD.log`
- `~/.minimax/v2/sessions/**/llm-call.json`

`spec/accounting.md` 只登记了 promptID 命名空间（`antigravity:` / `minimax-code:` / `zcode:` / `agy:`），没给载体路径。

---

## 8. 对 2.0 大版本的输入

按这次梳理，界面上有两处结构性混装，任何一方改动都要跨介质对齐：

1. **popover 卡片同屏混载体**（provider HTTP / Antigravity 本机 RPC / SQLite / 文件 / 打包价格表）。本机 token 数来自 **3 个 SQLite 账本、3 类 JSONL 文件账本和 Antigravity 本机 RPC**；另有 `tasks-index.sqlite` 与 Antigravity conversation DB 两个辅助库。动「额度窗口」需按实际 provider/client 数据源核对，不能把辅助库计作 token 账本；动「Plan 详情」涉及 provider 配额请求。
2. **金额是跨介质的合成值**：账本 token（DB/文件） × 单价（打包 JSON） × 峰谷倍率（节假日表，可能来自缓存文件 / bundle / CDN）。三处任一变化都会让界面上所有金额同步变化，且三者更新节奏完全不同（打包资源随版本、节假日表按周、token 按秒）。

**Fleet Sync 设计输入（用户裁定与当前设计方案，2026-10-24；以下均为设计输入，不代表已实现）：**

- **【用户确认】节点身份：**UUID 首次生成后存入 Keychain 并复用，不启用 iCloud 同步；用户更换 UUID 时按新节点处理，不按 hostname 自动合并。
- **【用户确认】同步存储边界：**上报记录与 hub 回传快照使用应用自有、独立的同步表；不写入 Codex、ZCode、OpenCode 等客户端原表，也不往现有本机用量数据模型添加同步来源字段。
- **【当前设计命名】同步存储：**独立 SQLite 文件命名为 `fleet.sqlite`，表命名为 `sync_records`。这是当前实现方案的名字，不是用户另行指定的文件名或表名。
- **【当前协议字段与归并规则】窗口：**副节点报告窗口的 `startAt` / `endAt`；hub 只相加 provider、model、kind 和窗口范围都相同的记录，不由 hub 下发或重新解释窗口。
- **来源与完整度：**Fleet DTO 从本机已投影的内存状态构建，原始账本文件和 `token-monitor/*.json` 缓存文件本身不传输。缓存可恢复完整 `lastResult` 供冷启动展示，但恢复值不等于当前 reconcile 已验证；上报必须带来源验证/完整度语义，不能用未验证或 partial 结果当作权威零值覆盖 hub 状态。日级总量与模型级明细分开表达完整度：Codex 等 scanner 的日聚合可能在 `recentSamples` 截尾前已完成，而模型行与金额由样本派生，可能覆盖不足；不得从模型样本明细推导日总量，也不得宣称日桶自动提供完整七日模型金额。

另有几处已知不一致可作为大版本的清理项：Codex 无持久 scanner 快照（冷启动成本不对称）、ZCode 余额依赖外部日志留存、`notification-state.json` / `holidays-cache.json` 这类派生文件没有统一命名与生命周期约定。
