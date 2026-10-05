# Source Map — 文件职责全表

本文件是**机械对账用**的全量文件职责表：每行对应源码树（`Sources/` / `Tests/` / `scripts/`）里的一个文件，登记 `path → 职责`。按路径 grep 用，**不作为阅读材料**——任务从 `overview.md` §Spec 地图与任务路由 进入对应主题文件，需要核对某个文件职责时才来这里查。

## Source Map

| Path | Responsibility |
|---|---|
| `Sources/LLM-monitor/LLMMonitorApp.swift` | App entry point, lifecycle delegate, `FetcherDescriptor` registry, fixed menu bar label |
| `Sources/LLM-monitor/Services/AppInstanceLock.swift` | Per-user single-instance lock held for the process lifetime |
| `Sources/LLM-monitor/Fetchers/FetcherDescriptor.swift` | `FetcherDescriptor` (provider 注册元信息 single source of truth) |
| `Sources/LLM-monitor/Models/ProviderClientModel.swift` | quota Provider / Client IDs、显式绑定、provider 中立 usage projection 与设置页摘要模型 |
| `Sources/LLM-monitor/Models/ClientIdentity.swift` | 身份语汇（QuotaProviderID / ClientID / ClientDescriptor / ClientProviderBinding）与默认绑定矩阵字面量（单一事实源） |
| `Sources/LLM-monitor/Models/UsageFrameExtractors.swift` | 帧抽取注册表 `usageFrameExtractors`（各 harness 的 ProviderStatus 字段 → `HarnessUsageFrame`，L1 适配） |
| `Sources/LLM-monitor/Models/UnifiedDailyTokenUsage.swift` | provider 中立日桶与当日 max 修补（`UnifiedDailyUsageNormalizer`） |
| `Sources/LLM-monitor/Models/MixedCurrencyEstimate.swift` | 跨 provider 金额汇总的统一折算类型（USD ×7 → CNY） |
| `Sources/LLM-monitor/Services/ClientUsageAggregation.swift` | L3 视图模型纯函数：设置页客户端拆行、菜单 `HarnessTodaySummary`、`ProviderStatusStrip` 投影、`HarnessSummaryCache` |
| `Sources/LLM-monitor/Services/LayoutMetrics.swift` | Services 与 Views 共读的排版常量（图表宽 / 卡片列与内容层内边距） |
| `Sources/LLM-monitor/Models/ModelPricingCatalog.swift` | 计价引擎：加载 `Resources/ModelPricing.json`（首条命中 / exact / matchAll / zhipu 兜底 / 下划线归一化）并应用 DeepSeek 高峰倍率 |
| `Sources/LLM-monitor/Resources/ModelPricing.json` | 价格数据：随 app 打包的唯一价格源（`ModelPricingJSONTests` 守门 schema 完整性） |
| `Sources/LLM-monitor/Models/ProviderStatus.swift` | UI-facing provider state + `ProviderKind` / `AccentColor` 枚举 |
| `Sources/LLM-monitor/Models/QuotaInfo.swift` | Provider-neutral quota 和 reset-credit 模型 |
| `Sources/LLM-monitor/Models/QuotaWindowStatus.swift` | Provider 无关的额度窗口存在性（`.present` / `.absent`）；fetcher 在边界归一化 raw 状态码 |
| `Sources/LLM-monitor/Models/AntigravityModelKind.swift` | Antigravity 模型族分类 enum（`gemini_models` / `claude_and_gpt_models` wire 值的 single source of truth） |
| `Sources/LLM-monitor/Models/AppMetadata.swift` | 版本 / build 号（读 Info.plist，设置页「关于」展示） |
| `Sources/LLM-monitor/Models/AnyJSON.swift` | 弱类型 JSON（Antigravity 递归解析用） |
| `Sources/LLM-monitor/Models/LocalUsageDaily.swift` | Antigravity / Agy / Codex / Minimax / GLM / DSH / OpenCode 共享的 7-day chart 协议 + 默认实现 |
| `Sources/LLM-monitor/Models/LocalDailyTokenUsage.swift` | 六个本地数据源共享的单日 token 聚合结构（统一收口原 `XxxDailyUsage`，on-disk JSON 键兼容） |
| `Sources/LLM-monitor/Models/LocalTokenUsageSample.swift` | Provider 中立的单次模型调用 sample（cache-inclusive input 口径 + `TokenUsageBuckets` 规范化入口） |
| `Sources/LLM-monitor/Models/TokenAccounting.swift` | harness raw input / output 计数口径的元数据枚举（cacheInclusive / uncachedOnly 等） |
| `Sources/LLM-monitor/Models/ReasoningCharSplit.swift` | 「思考字符数 → 思考 token 数」的守恒拆分纯函数（`reasoning + output == 账面 output` 恒成立）；5 处调用方：GLM/ZCode（`GlmZcodeDBReader`）、MiniMax Code（`MinimaxLocalUsageAggregation`）、Dsh M3（`DshLocalUsageScanner`）、OpenCode（`OpencodeDBReader`）、Agy（`AgyLocalUsageAggregation`） |
| `Sources/LLM-monitor/Models/LocalUsageRetentionWindow.swift` | 本地用量「落盘前保留窗口」的唯一口径（`LocalUsageRetentionWindow`，Antigravity / Agy / DSH / GLM-ZCode / Minimax / OpenCode 六个 scanner 共享）；刻意区别于展示层 7 天窗口，契约由 `ScannerRetentionContractTests` 锁定 |
| `Sources/LLM-monitor/Models/LocalUsageFreshness.swift` | 本地用量数据新鲜度（clean / dirty / scanning / failed），刻意独立于额度健康度 |
| `Sources/LLM-monitor/Models/DisplayOrder.swift` | Stable-ID ordering helper for configurable Provider cards and alphabetical fallback lists |
| `Sources/LLM-monitor/Models/OpencodeLocalUsage.swift` | OpenCode provider 分片、今日 / 7 天聚合与逐次 samples |
| `Sources/LLM-monitor/Models/UsageProjectionKernel.swift` | Provider × Harness 投影内核：`HarnessUsageFrame` 适配（clientID/sourceKey/quota 归属）→ `UsageProjectionKernel.project` 出 per-client × per-provider 投影（daily + per-model 桶 + 名义价值）；promptID 命名空间规则表（`UsageSampleNamespace`）与 DSH 帧适配（`DshHarnessFrames`）在此，旧 `DshUsageMerger` / `OpencodeUsageMerger` 已吸收删除 |
| `Sources/LLM-monitor/Models/GlmLocalUsage.swift` | GLM ZCode 本地 token 用量聚合模型（单源、原生 reasoning / turn_id、闲时窗口挂载、非智谱 provider 分片挂载） |
| `Sources/LLM-monitor/Models/ZcodeProviderSlice.swift` | ZCode 非智谱 provider 分片枚举（`minimax` / `deepseek` 前缀谓词、quota 卡映射与样本 promptID 命名空间） |
| `Sources/LLM-monitor/Models/DshLocalUsage.swift` | DeepSeek Harness session token 数据模型与 provider 分片 |
| `Sources/LLM-monitor/Services/DshLocalUsageScanner.swift` | 读取 `~/.dsh/sessions` 的 JSONL/zstd session 日志，按 provider 聚合 7 天用量 |
| `Sources/LLM-monitor/Models/AgyLocalUsage.swift` | agy CLI 本地 transcript token 用量快照模型（`isPartial` 出相等 / `isTruncated` 入相等的设计注释） |
| `Sources/LLM-monitor/Services/AgyLocalUsageScanner.swift` | 读取 `~/.gemini/antigravity-cli/brain/` 的 transcript JSONL + cli log 模型名时间线，聚合 7 天用量（预算截断 / 指纹缓存） |
| `Tests/LLMMonitorTests/AgyLocalUsageScannerTests.swift` | agy scanner 回归护栏（MODEL 行解析 / 去重 / 模型名 join / 缓存短路 / 预算截断 / 帧投影命名空间） |
| `Sources/LLM-monitor/Models/ProviderLocalUsage.swift` | Antigravity / minimax 共享的本地用量数据模型（保留历史类型别名） |
| `Sources/LLM-monitor/Fetchers/QuotaFetcher.swift` | `QuotaFetcher` protocol + 默认实现 |
| `Sources/LLM-monitor/Services/Infra/QuotaError.swift` | 统一错误类型 |
| `Sources/LLM-monitor/Fetchers/MinimaxTokenPlanFetcher.swift` | minimax Token Plan API 抓取 |
| `Sources/LLM-monitor/Fetchers/CodexFetcher.swift` | ChatGPT Plan API 抓取 + 本地 JSONL 解析 |
| `Sources/LLM-monitor/Fetchers/AntigravityFetcher.swift` | Antigravity 进程发现 + 本地 RPC + protobuf-like 解析 |
| `Sources/LLM-monitor/Fetchers/AntigravityProcessDiscovery.swift` | Antigravity 后端进程发现（IDE `language_server` / `agy` CLI 双形态、端口与 CSRF token 提取） |
| `Sources/LLM-monitor/Fetchers/AntigravitySchemas.swift` | Antigravity RPC request / response 的 Encodable 编码 schema 与解码模型 |
| `Sources/LLM-monitor/Fetchers/GlmCodingPlanFetcher.swift` | GLM Coding Plan 额度与 reset time 抓取 |
| `Sources/LLM-monitor/Fetchers/DeepseekFetcher.swift` | DeepSeek 账户余额抓取（`/user/balance`）+ 解析 |
| `Sources/LLM-monitor/Models/PeakWindow.swift` | GLM / DeepSeek 共用的参数化高峰窗口判定（`slots` × `weekdaysOnly`；GLM 本机时区单窗口可配置，DeepSeek 北京时间双窗口固定、高峰永不含周末） |
| `Sources/LLM-monitor/Services/AppState.swift` | 全局状态派生、config reload 接线（`configStore.startWatching()`，watcher 本体在 ConfigStore）、scanner wire-up、Provider batch/LocalUsage reconcile 与睡眠健康边界接线 |
| `Sources/LLM-monitor/Services/QuotaUpdateNotifier.swift` | 额度通知引擎：`QuotaEventDetector`（四类窗口事件边沿判定）+ `QuotaEventBatch`（按模型×渠道合并）+ 系统通知渠道 + `CompositeQuotaUpdateNotifier` 渠道扇出 |
| `Sources/LLM-monitor/Services/BarkNotifier.swift` | Bark 推送渠道：POST JSON 传输、稳定覆盖 id、锁屏/亮屏跳过判定、有界串行发送队列（冷却 / 重试 / 可取消） |
| `Sources/LLM-monitor/Services/TriggerStateStore.swift` | 通知触发器基线持久化（`notification-state.json`），检测 previous 的跨重启单一来源 |
| `Sources/LLM-monitor/Services/LastRefreshStore.swift` | `last-refresh.json` 的 actor 化持久化（合并窗口 + encode/fsync 移出 MainActor） |
| `Sources/LLM-monitor/Services/AppLog.swift` | stdout / 文件 (5MB rotate) / os.Logger (`.private`) 三路日志 |
| `Sources/LLM-monitor/Services/ConfigStore.swift` | config.json 读写 + 内容指纹跟踪 + 模板生成 + **单文件 `DispatchSource` watcher**（`startWatching()` / `startConfigWatcher()`，debounce + 原子替换后重开 fd + 退避重试，由 `AppState.start()` 调用） |
| `Sources/LLM-monitor/Services/LoginItemService.swift` | `SMAppService.mainApp` 包装 + 状态显示 |
| `Sources/LLM-monitor/Services/Formatters.swift` | token / percent / 时间 / codex window 标签格式化；相对时间类（`formatRelativeShort` / `formatResetSuffix`）的 `now:` 必填——视图层显式传宿主展示时钟，不取渲染时墙钟 |
| `Sources/LLM-monitor/Services/Infra/HTTPClient.swift` | 共享 HTTP 客户端（minimax / codex 三个 fetch 路径）；`ResponseByteLimits` 响应体硬上限（标准额度 8 MiB / Antigravity trajectory 64 MiB）由 `CappedDownloader.data` 在**响应体返回后**校验——超限抛 `responseTooLarge`，该错误为非瞬时（不重试、不进通知冷却）。async `session.data(for:delegate:)` 不向 per-task delegate 投递 `didReceive response` / `didReceive data` 内容回调（macOS 27 实测：URLProtocol 桩与真实网络均不触发），因此 `CappedDownloadDelegate` 的流式计数在当前调用方式下**不执行**，真正的拦截点是后置字节校验；delegate 保留待将来改用回调系任务。峰值内存仍由 URLSession 缓冲决定——该上限保证超限响应不进入调用方解析链路，不保证单次响应不被完整缓冲 |
| `Sources/LLM-monitor/Services/LocalUsageCoordinator.swift` | scanner 协议 + Combine wire-up 容器 |
| `Sources/LLM-monitor/Services/ProviderRefreshScheduler.swift` | 循环 A（额度循环）：单一 Task 管理所有 Provider 的 quota 定时排期，睡眠至最早截止时间，并发刷新 + 条目级隔离 |
| `Sources/LLM-monitor/Services/ManualRefreshGate.swift` | 手动 full refresh 与 in-flight background refresh 的合并协议（pending 登记 / 取消撤销 / 一次性补跑） |
| `Sources/LLM-monitor/Services/LocalUsageOrchestration.swift` | LocalUsage reconcile：按触发原因分层为 `.dirty` / `.full`（cache-assisted） / `.hardFull`（绕过各 provider 自己的 fingerprint / offset / cache），请求按 `dirty < full < hardFull` 优先级折叠成一次；`.hardFull` 只在启动首拍、日历签名失效与 `bypassesProviderCache` 时触发。Provider batch settled 后每拍都投递一次 reconcile（scanner 内部指纹短路决定是否真扫），不持有 Timer |
| `Sources/LLM-monitor/Services/LocalFSEventsWatcher.swift` | 可复用的单 scanner FSEvents 封装；每个 scanner 自己持有 watcher 与源路径，不维护全局路径表 |
| `Sources/LLM-monitor/Services/LocalVnodeWriteWatcher.swift` | 文件级 write/extend vnode watcher（持续增长的日志文件 dirty 标记；只报 dirty，扫描仍归 provider 循环） |
| `Sources/LLM-monitor/Services/AuthProber.swift` | 异步探测本地服务（antigravity）是否还活着 + 缓存 + 离/在线变化回调 |
| `Sources/LLM-monitor/Fetchers/RefreshResultMergers.swift` | `CodexFillingMissingMerger` 等 per-provider 合并策略（Minimax 使用默认 `IdentityRefreshResultMerger`） |
| `Sources/LLM-monitor/Services/Infra/DateParser.swift` | ISO8601 / unix timestamp 统一解析 |
| `Sources/LLM-monitor/Services/Infra/StringUtilities.swift` | 字符串小工具（trim / firstTrimmed） |
| `Sources/LLM-monitor/Services/Infra/ProcessRunner.swift` | 同步短命令子进程执行器（pgrep / lsof / pmset / zstd / node；持续排空 pipe + 超时与取消检查） |
| `Sources/LLM-monitor/Models/SaturatingArithmetic.swift` | 非负计数饱和算术（负值归零、溢出封顶 `Int.max`），聚合入口防损坏输入 |
| `Sources/LLM-monitor/Services/LocalUsageDayKey.swift` | `yyyy-MM-dd` day key（跟 SQLite `strftime` 对齐） |
| `Sources/LLM-monitor/Services/LocalUsageCalendarSignature.swift` | 决定本地日桶的日历输入签名（`LocalUsageCalendarSignature.make(calendar)`），随 provider 缓存落盘；冷启动时源文件没变也不会把按旧时区分组的快照当成当前数据 |
| `Sources/LLM-monitor/Services/TokenMonitorPaths.swift` | 全部本地用量 scanner 的共享落盘位置（`~/Library/Application Support/LLM-monitor/token-monitor/<provider>.json`）+ Antigravity 旧缓存目录 `legacyAntigravityCacheDir` |
| `Sources/LLM-monitor/Services/Infra/SQLiteConnection.swift` | SQLite3 通用连接层（三层读策略：无 -shm 且无 dirty WAL 时 immutable=1 直读；活跃时共享内存只读；异常由 SQLiteTempCopy 走 /tmp 副本 recovery） |
| `Sources/LLM-monitor/Services/Infra/SQLiteTempCopy.swift` | `/tmp` 副本 fallback：回退白名单 CANTOPEN / BUSY / READONLY 家族 / IOERR 家族 / CORRUPT，以及 immutable 直读打开后复检发现 `-shm`/`-wal` 出现的 `lostImmutableRace`（直读前提失效，非扫描失败）。副本读取同样 CORRUPT 时按源指纹（db/-wal/-shm 的 mtime+size，进程内不落盘）记忆为持久损坏，后续轮次跳过全量拷贝快速失败，指纹变化即失效恢复重拷——并发 checkpoint 撕裂页的重拷自愈路径不受影响。拷贝循环逐文件校验源指纹：db 拷完立即复验，失效即放弃本轮 wal/shm 拷贝，最多 3 轮后抛 `sourceChangedDuringSnapshot` |
| `Sources/LLM-monitor/Views/Color+Theme.swift` | 品牌色常量 |
| `Sources/LLM-monitor/Services/MenuBarRightClickHandler.swift` | 状态栏按钮右键菜单（best-effort） |
| `Sources/LLM-monitor/Services/StatusBarQuotaMetrics.swift` | 状态栏额度指标结构（`QuotaRingMetrics` / `StatusBarQuotaMetrics`），由 Icon Duo 仪表盘消费；原 App 图标 SVG 生成器已随「App 图标」改用固定设计稿而删除 |
| `Sources/LLM-monitor/Services/IconDuoSVGBuilder.swift` | Icon Duo 状态栏额度仪表盘的参数化 SVG 生成（左右额度弧 / 中心扇形 / 底部模型健康点 / 顶部节能点） |
| `Sources/LLM-monitor/Services/MinimaxDBReader.swift` | 读 minimax v2 `local_runtime_token_usage` 表 |
| `Sources/LLM-monitor/Services/MinimaxLocalUsageScanner.swift` | minimax v2 `runtime-state.sqlite` 单源 scanner（AsyncMutex + lastCommittedGeneration 串行化）|
| `Sources/LLM-monitor/Services/MinimaxLocalUsageAggregation.swift` | minimax reasoning 字符分摊比例回写 sample 与 per-day 聚合纯函数 |
| `Sources/LLM-monitor/Services/AgyLocalUsageAggregation.swift` | agy transcript MODEL 行解析、跨文件去重、thinking 字符守恒分摊与日聚合纯函数 |
| `Sources/LLM-monitor/Services/GlmZcodeDBReader.swift` | ZCode `model_usage` 表 SQL 读取 + Method A reasoning 归类 + per-day 聚合与 samples + 非智谱 provider 分片聚合（`ZcodeProviderSliceAggregate`） |
| `Sources/LLM-monitor/Services/GlmZcodeOffPeakReader.swift` | `~/.zcode/v2/tasks-index.sqlite` 闲时任务时间窗口读取（额度窗口排除依据） |
| `Sources/LLM-monitor/Services/GlmZcodeBalanceLogReader.swift` | ZCode 余额轮询日志解析（活动套餐 balances，`parseZcodeBalanceLog` 开关） |
| `Sources/LLM-monitor/Services/GlmZcodeLocalUsageScanner.swift` | GLM ZCode `db.sqlite` 单源 scanner（AsyncMutex + lastCommittedGeneration 串行化） |
| `Sources/LLM-monitor/Services/AntigravityLocalUsageScanner.swift` | Antigravity 纯 RPC 架构 scanner（AsyncMutex + lastCommittedGeneration 串行化，不用 SQLite .db 读表）|
| `Sources/LLM-monitor/Services/AntigravityFilesystem.swift` | `AntigravityLocalUsageScanner` 的文件系统侧 extension：conversations roots 枚举、`.db` / `.pb` 双格式识别与指纹、`isComplete` 语义（权限 / TCC / 瞬时 I/O 不得据此删缓存） |
| `Sources/LLM-monitor/Services/AntigravityLocalUsageCache.swift` | `AntigravityLocalUsageScanner` 的缓存与 index 类型 extension（与上面的 scanner 同类型，按职责拆文件） |
| `Sources/LLM-monitor/Services/AntigravityLocalUsageAggregation.swift` | Antigravity per-day turns / rounds 聚合与 sample 组装（纯函数，unit-testable） |
| `Sources/LLM-monitor/Services/AntigravityStepTimestampReader.swift` | Antigravity SQLite step 的 protobuf Timestamp 读取（RPC 事件缺 `createdAt` 时的回退） |
| `Sources/LLM-monitor/Services/OpencodeDBReader.swift` | 读取 OpenCode `message` 表并按 provider / day 聚合 |
| `Sources/LLM-monitor/Services/OpencodeUsageScanner.swift` | OpenCode DB 指纹、缓存、7 天窗口与 provider slice snapshot |
| `Sources/LLM-monitor/Services/Infra/AsyncMutex.swift` | actor-based async-aware mutex（scanner pipeline 互斥；支持 caller cancellation propagation — acquire 前 / 排队中 / acquire 后执行前三阶段均检查取消）|
| `Sources/LLM-monitor/Services/CancellationFilter.swift` | 统一"取消错误"判断（`Task.isCancelled` / `CancellationError` / `URLError.cancelled`），AppState 与 LocalUsageScanRunner 的两个 catch 入口共用 |
| `Sources/LLM-monitor/Services/Infra/FileManagerBox.swift` | `FileManager` 的 `@unchecked Sendable` 包装 + `fileManager` 字段 `private`（同文件 extension 之外不能直接拿到底层 `FileManager`）。`Tests/LLMMonitorTests/ConfigStoreTests.swift` 验证该访问约束 |
| `Sources/LLM-monitor/Services/Infra/HTTPTimeouts.swift` | HTTP timeout 集中地（国内 domestic 10s / 海外 overseas 15s / antigravity 本机回环），改一处全局生效 |
| `Sources/LLM-monitor/Services/LocalUsageScanRunner.swift` | 本地用量 scanner 共享的 lifecycle helper（generation 守门 / cancellation filter / defer generation 守门），消除镜像 boilerplate |
| `Sources/LLM-monitor/Services/SingleDBSnapshotScanner.swift` | 单库全量快照 scanner 基座（db + WAL 双维指纹与缓存 index；GLM / OpenCode scanner 复用） |
| `Sources/LLM-monitor/Services/DailyUsageAggregation.swift` | minimax / antigravity 共享的 per-day 聚合（补零填充 + 跨 source 合并） |
| `Sources/LLM-monitor/Services/ScannerIndexIO.swift` | minimax / antigravity 共享的 versioned `index.json` 读写（版本迁移 / 不匹配 reset） |
| `Sources/LLM-monitor/Services/ScannerFileError.swift` | scanner 共用的「明确不存在」错误判断（权限 / TCC / 瞬时 I/O 不误判为删除，保护 last-good cache） |
| `Sources/LLM-monitor/Services/LocalUsageScannerBase.swift` | 本地用量 scanner 的状态、generation、取消与 in-flight 去重基座 |
| `Sources/LLM-monitor/Services/LocalUsageSourceLifecycle.swift` | 本地用量源的 FSEvents/vnode 生命周期与 dirty 事件桥接 |
| `Sources/LLM-monitor/Services/CodexLocalUsageScanner.swift` | Codex session JSONL 本地用量缓存与窗口汇总 |
| `Sources/LLM-monitor/Models/SleepHealthModels.swift` | 「节能」模块 UI 与服务实现之间的稳定数据契约（断言快照 / 电源参数 / 健康度结果） |
| `Sources/LLM-monitor/Services/SleepHealthService.swift` | 睡眠健康度快照、防休眠断言与周期健康边界刷新 |
| `Sources/LLM-monitor/Services/SleepHealthEvaluator.swift` | 睡眠锁与系统电源参数的健康度评估 |
| `Sources/LLM-monitor/Views/MenuBarLabel.swift` | 菜单栏 label 视图（可见输入签名去重重绘 + 分钟时钟监听，App 图标 / Icon Duo / SF Symbol 多样式） |
| `Sources/LLM-monitor/Views/MenuContentView.swift` | 主面板（header / content / footer）+ 高度桥 `MenuPanelHeightBridge`（`contentMaxSize` = 屏幕可见高 × 0.70）+ `MenuHairline`；展示时钟经 `\.displayDate` 注入卡片 |
| `Sources/LLM-monitor/Views/DisplayClock.swift` | 跨宿主共享的展示时钟：`DisplayClock` + `DisplayClockScope` + `\.displayDate` 环境键；菜单内容 / hover 浮层 / dock 浮层各自持有实例、随宿主显隐 start/stop 并注入环境 |
| `Sources/LLM-monitor/Views/HarnessUsageMenuView.swift` | 菜单的 Harness（客户端）视角：顶部一屏全局今日汇总（`HarnessUsageMenuView`）→ 按客户端分段（`HarnessSectionView`）→ 段内按模型一行（`HarnessModelRowView`）→ 底部 provider 兜底状态条（`ProviderStatusStripView`，hover 出完整卡片）。与 `ProviderCardView` 并列而非替代；模型行的 328pt 宽度预算（菜单 360pt / 内容 336pt）由 `HarnessUsageMenuViewTests` 钉住 |
| `Sources/LLM-monitor/Views/MenuTypography.swift` | 菜单面板与悬浮层统一排版常量（语义角色，禁止散落硬编码字号） |
| `Sources/LLM-monitor/Views/MenuWindowAutoCloseBridge.swift` | 失焦立即关 + 30s 无交互关闭（菜单内 mouse/scroll/key 重置计时）|
| `Sources/LLM-monitor/Views/ProviderCardView.swift` | provider 卡片 + `ProviderStateLabel` + `QuotaSummary`（卡内状态点已随菜单改版移除，状态由 `ProviderStateLabel` 胶囊承载） |
| `Sources/LLM-monitor/Views/QuotaViews.swift` | 各种 quota 行 + 进度条（`CombinedQuotaWindowRow` / `CombinedQuotaBar` / `SingleQuotaBar` / `ModelQuotaDockBlock` / `OffPeakUsageFootnote` / `DeepseekBalanceRow` / `ChatGPTPlanModelRow` / `CompactResetCreditsRow` / `QuotaBarTooltip`）；重置倒计时与过期判定随宿主展示时钟推进（`\.displayDate`） |
| `Sources/LLM-monitor/Views/QuotaWindowUsageViews.swift` | 「额度窗口用量」区块族：模块标题 / 细分隔线、四桶绝对值与三个比率（`QuotaWindowUsageMetrics`）、双段 capsule 切换（`QuotaWindowUsageSegmentControl` / `QuotaWindowUsageSegment`）、reset credits 明细（`ResetCreditsDetailList`）与合并统一 7 列 Grid 骨架的总段 `QuotaWindowUsageSection`；重置日期格倒计时随宿主展示时钟推进（`\.displayDate`） |
| `Sources/LLM-monitor/Views/QuotaHoverViews.swift` | 仅剩 `UsageMetricHoverSummaryView`（额度用量指标 hover 摘要，input/cached 与 prompts/rounds 固定分行）；旧 `QuotaWindowsHoverView` 族已随 menuLayout 死分支整体删除 |
| `Sources/LLM-monitor/Views/HoverPanel.swift` | `HoverInfoRow` / `HoverPanelController` / 浮层管理；浮层显隐驱动共享展示时钟（经 `DisplayClockScope` 注入） |
| `Sources/LLM-monitor/Models/EdgeDockEntry.swift` | `EdgeDockEntry` + `EdgeDockProjection`：已启用 Provider → 双环条目（外环=5h 有效额度 min(5h, 周×N) 与状态栏同口径、原始 5h 字段供 hover 文案对照、内环=原始周 各自最低 + 健康档位 + 品牌 kind），纯函数 |
| `Sources/LLM-monitor/Models/EdgeDockConfig.swift` | `DockEdge` / `EdgeDockConfig`：贴边方向 + 归一化位置（存比例不存绝对坐标），含手改值归一化 |
| `Sources/LLM-monitor/Services/EdgeDockGeometry.swift` | 边缘窗纯几何：行高/尺寸、贴边 frame、offset 往返换算、最近边吸附、行/圆矩形推算（兜底用）、popover 定位、沿边拖拽换算、贴屏侧直边的非对称标签形状 |
| `Sources/LLM-monitor/Services/EdgeDockDisplay.swift` | 屏幕稳定身份（`EdgeDockDisplay`，display UUID）：边缘窗跨屏只记 UUID，不记 `NSScreen` 对象 / 数组下标 / 几何位置 |
| `Sources/LLM-monitor/Services/FullscreenProbe.swift` | 当前 Space 全屏判定（`CGWindowList` 只读窗口边框 + 桌面装饰是否存在，fail-open，不需要辅助功能权限） |
| `Sources/LLM-monitor/Services/EdgeDockController.swift` | 边缘窗控制器本体：状态与配置（`applyRuntimeConfig` 是运行时改配置的唯一入口，`config` 的 setter 保持 private）+ 接线（`attach` / `teardown`） |
| `Sources/LLM-monitor/Services/EdgeDockController+Window.swift` | `NSPanel` 建/拆、按条目数与形态算窗口尺寸、贴到目标屏那一侧、"为什么没出现 / 出现在哪"的日志签名 |
| `Sources/LLM-monitor/Services/EdgeDockController+Mouse.swift` | 鼠标穿透与悬停接管：monitor 装卸、2Hz 轮询节拍、命中后的接管与释放、hover / 展开 / 收起的挂起任务 |
| `Sources/LLM-monitor/Services/EdgeDockController+Popover.swift` | Provider 卡片浮层（与 dock 两个独立窗口）：定位、显隐、鼠标停在浮层上时的接管保持（`ignoresMouseEvents = false` 接收交互并注入 `quotaWindowSegmentEditable = true`），并经 `DisplayClockScope` 注入随显隐 start/stop 的展示时钟 |
| `Sources/LLM-monitor/Services/EdgeDockController+Drag.swift` | 沿贴靠边滑动拖拽：阈值判定、跨屏换屏 UUID、落点吸附与位置持久化 |
| `Sources/LLM-monitor/Services/EdgeDockController+Fullscreen.swift` | 全屏门控：判定变化后重排窗口，以及窗口进出场动画期间的阶梯补测 |
| `Sources/LLM-monitor/Services/EdgeDockController+HitTesting.swift` | 边缘窗命中判定纯函数（`circleIndex` 圆命中 + `resolveRowRects` / `resolveCircleRects` 实测优先、几何兜底），`nonisolated static`，不读实例状态 |
| `Sources/LLM-monitor/Views/EdgeDockContentView.swift` | 边缘窗视图（外环=5h 有效额度、内环=周、中心=Provider 品牌图标，刘海式背景） |
| `Sources/LLM-monitor/Views/TokenChart.swift` | 7-day 柱图基础组件（`StackedTokenBar` / `TokenChartScale`） |
| `Sources/LLM-monitor/Views/TokenBucketBar.swift` | 水平三段占比条（input / cacheRead / billableOutput，reasoning 并入 output），输入为 `TokenAccounting` 归一化四桶；桶色与 7 天柱图一致 |
| `Sources/LLM-monitor/Views/AccountHoverViews.swift` | 账号信息值类型 + 行（`QuotaWindowAccountInfo` / `QuotaWindowAccountInfoRow`）：卡片第一段「Account Info」常驻行，取代已删除的折叠区与 `AccountHoverView` 浮层 |
| `Sources/LLM-monitor/Views/GlmPeakIndicatorView.swift` | GLM 高峰期提示行（倒计时 + 三档颜色） |
| `Sources/LLM-monitor/Views/GlmActivityPlanBalancesView.swift` | GLM 活动套餐余额展示行（`🎁 套餐名 94% (283M/300M) 08-31 09:00`，balances 空则不渲染） |
| `Sources/LLM-monitor/Views/DeepseekPeakIndicatorView.swift` | DeepSeek 高峰期提示行（北京时间倒计时，内嵌余额行右侧） |
| `Sources/LLM-monitor/Views/PeakIndicatorView.swift` | 高峰提示行公共组件（`TimelineView` 外壳 + `formatDuration`，GLM / DeepSeek 共用） |
| `Sources/LLM-monitor/Views/BrandLogoView.swift` | provider 品牌 logo 资源加载 + SF Symbol fallback |
| `Sources/LLM-monitor/Views/LocalUsageHoverViews.swift` | 7-day 泛型 chart + 泛型 footer |
| `Sources/LLM-monitor/Views/SegmentedQuotaProgressBar.swift` | 5h / 周额度分段条、窗口颜色与 reset 标记 + `EquivalentQuotaAllocation`（binding constraint 文案与 `bindingWindow` 判定） |
| `Sources/LLM-monitor/Views/SettingsEnergyPane.swift` | 设置页节能 pane：睡眠健康度、防休眠与电源参数矩阵 |
| `Sources/LLM-monitor/Views/SleepAssertionOffender+RowText.swift` | 「阻止休眠的第三方应用」行文案（`SleepAssertionOffender` 的行格式化 extension）+ 主面板 header 悬浮清单 `SleepOffendersHoverView`，两处共用同一份格式 |
| `Sources/LLM-monitor/Views/SettingsClientsPane.swift` | 设置页「客户端」tab：本地客户端用量诊断 + client ↔ quota 绑定开关（从 SettingsView 拆出） |
| `Sources/LLM-monitor/Views/ClientSegmentedControl.swift` | 设置页「客户端」切换条：原生 `NSSegmentedControl` 包装（段宽按文字测量写死，客户端变多时整体变宽并横向滚动，不压成省略号） |
| `Sources/LLM-monitor/Views/SettingsComponents.swift` | 设置窗口共享组件与统一字体角色（`SettingsTypography` / `SettingsSection` / `SettingsControlRow` / `SettingsPaneHeader`） |
| `Sources/LLM-monitor/Views/SettingsSaveTransaction.swift` | 设置保存事务：login item 更新 + config 保存的失败回滚语义 |
| `Sources/LLM-monitor/Views/SettingsView.swift` | 设置面板 |
| `scripts/build-app.sh` | Release arm64 `.app` bundle build（dSYM 导出 + strip）和 ad-hoc signing |
| `scripts/build-release.sh` | 发行编排入口：依次 build-app.sh → build-dmg.sh 并产出 SHA-256 校验和，签名 / notarization 变量透传 |
| `scripts/test-build-config.sh` | `build-app.sh` 构建期常量的 shell 冒烟测试（BUNDLE_ID 等「格式对但值被改」的回归护栏，自带框架） |
| `scripts/build-dmg.sh` | DMG packaging from the built `.app` |
| `scripts/test.sh` | 运行 `swift test`；仅显式设置 `INCREMENT_BUILD_NUMBER=1` 时递增 build 编号 |
| `scripts/audit.sh` | Shell syntax、Package、测试、Release 和 Swift 6 门禁 |
| `scripts/archive-source.sh` | 从 Git HEAD 生成源码归档 |
| `scripts/export-antigravity-quota.sh` | 导出 Antigravity 本地 quota 数据 |
| `scripts/generate-icns.sh` | 从源图生成 AppIcon.icns（由 sync-icon-assets.sh 调用，也可独立使用） |
| `scripts/sync-icon-assets.sh` | 图标资产唯一同步入口：IconPreview 副本 + 回退 icns 重生成 + sidecar 新鲜度记录；`--check` 供构建前置校验 |

## Test Suite

- 规模：`Tests/LLMMonitorTests/` 按主题一文件组织（2026-10 重组后 ~120 文件 / ~1060 用例）。
- **串行执行是既定选择**：`swift test --parallel` 实测（2026-10-02，5 连跑 3 败）不可用——`SQLiteTempCopyTests` 的临时副本断言扫描跨进程共享目录，并行 worker 互相误判；且慢测试为睡眠型，并行的 wall 收益仅 ~4s。并行化前提：先给 SQLiteTempCopy 的副本目录引入进程级隔离，再复评。
- 慢用例的等待注入缝已建立：调度器（now/sleep）、Bark 退避（retryDelay）、vnode 合并窗口（coalescingWindow 参数）；新增耗时敏感测试时优先走注入缝，不要写死真实 sleep。

> 核对基线：2026-10-05 · 代码 c7d9afa
