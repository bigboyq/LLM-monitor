# Source Map — 文件职责全表

本文件是**机械对账用**的全量文件职责表：每行对应源码树（`Sources/` / `Tests/` / `scripts/`）里的一个文件，登记 `path → 职责`。按路径 grep 用，**不作为阅读材料**——任务从 `overview.md` §Spec 地图与任务路由 进入对应主题文件，需要核对某个文件职责时才来这里查。

## Source Map

| Path | Responsibility |
|---|---|
| `Sources/LLM-monitor/LLMMonitorApp.swift` | App entry point, lifecycle delegate, `FetcherDescriptor` registry（含 CodexFetcher 多 Key forwarding makeFetcher）、fixed menu bar label, single-instance public provider-detail Window |
| `Sources/LLM-monitor/Services/AppInstanceLock.swift` | Per-user single-instance lock held for the process lifetime |
| `Sources/LLM-monitor/Fetchers/FetcherDescriptor.swift` | `FetcherDescriptor` (provider 注册元信息 single source of truth) |
| `Sources/LLM-monitor/Models/AppConfig.swift` | 应用配置与 Provider 配置契约模型（Codex 多 Key 模型 `CodexAdminKeyConfig`、`adminApiKeys` 与 `effectiveAdminKeys` 双模式向后兼容回退；`SyncConfig` 的逐字段容错、推送周期 effective 值、本机系统通知声音偏好、`StatusBarIconStyle` / `StatusBarHealthColors` / `BarkConfig` / `AppConfig` / `ProviderConfig`，从 ConfigStore.swift 解耦） |
| `Sources/LLM-monitor/Models/StatusBarQuotaSelection.swift` | 状态栏 Provider + 独立额度来源的持久身份与选项契约（主套餐 / API Key / 活动权益） |
| `Sources/LLM-monitor/Models/ProviderClientModel.swift` | provider 中立 usage projection 与 Harness 自动归因（区分日总量源级截断与模型 / 窗口样本截断，含无贡献时的 DSH 源级状态）与设置页摘要模型 |
| `Sources/LLM-monitor/Models/SyncModels.swift` | Fleet Sync wire DTO（NodeUsageReport / FleetSnapshot 等）、FleetCodec（iso8601 唯一编解码入口与整秒窗口边界匹配）、通道级报告校验（含 ASCII / Gregorian 日键校验）、日桶/窗口合并与额度选举纯函数（FleetMerger）、归因指纹（SHA256 前 8 hex）、SyncRole 单源派生 |
| `Sources/LLM-monitor/Services/Sync/FleetStore.swift` | 应用自有 fleet.sqlite 单表 sync_records 的事务存储：报告通道独立落库、本机 seq 与节点 high-water、窗口 upsert / 过期及坏行清理（可见清理同步递增 generation）、副节点快照缓存（scope = upstreamKey+hubUUID 隔离） |
| `Sources/LLM-monitor/Services/Sync/DeviceIdentityStore.swift` | Fleet Sync 本机节点身份 UUID 持久化；在 config 同目录独立读写 `.deviceId`，不继承 config 中旧 `sync.nodeID` |
| `Sources/LLM-monitor/Services/Sync/HubServer.swift` | NWListener 上的 HTTP/1.1 最小子集 hub 服务：定长 body、4MiB/2MiB 上下限、路径白名单、每 nodeID 1s 限流、连接看门狗；业务全部委托 HubServerHandlers |
| `Sources/LLM-monitor/Services/Sync/SyncClient.swift` | node 侧 HTTP 客户端（复用 Infra/HTTPClient）：POST 报告推+取一次往返、GET 快照兜底、GET /v1/health 学习 hubUUID；upstreamKey 归一化 |
| `Sources/LLM-monitor/Services/Sync/UsageReportBuilder.swift` | 从启用 Provider 的 `usageProjection` 构建 NodeUsageReport：七日日桶、同样本计价的模型明细与窗口行、有效 lastSuccess 额度通道；按实际 client/provider 隔离失败、扫描或预算截断来源，健康日桶行继续上报，不可用来源显式标记并由 Store 保留旧值；对应 provider 窗口仍省略 |
| `Sources/LLM-monitor/Models/FleetUsageModels.swift` | Fleet UI 投影（L3）：FleetScope、FleetEffectiveQuota（本机优先→elected + 来源标注）、FleetCardUsage / FleetWindowUsageRow（全 provider 日桶、provider-filtered 窗口及历史窗口选择 / 部分计价提示 / stale 日桶贡献提示）；DayValue 保留数值 estimate 与部分标记供历史趋势消费，FleetMenuSummary、FleetCardContext |
| `Sources/LLM-monitor/Services/LANAddressResolver.swift` | 本机局域网地址异步探测与挑选：view 不等待阻塞探测；采集（`getifaddrs`，排除回环 / 未 UP / 虚拟前缀 / 与 `bridge0` 同 MAC 的雷雳桥腿；正确处理 `sockaddr_dl` 中可变长度接口名偏移以解析 MAC）+ 硬件分类缓存（Network.framework 的 `NWPathMonitor`）+ 挑选（Wi-Fi → 有线 → 其它，不拿 127.0.0.1 兜底） |
| `Sources/LLM-monitor/Views/SettingsSyncPane.swift` | 设置页「多机联动」pane：角色字段（写穿持久化）、复制局域网地址（探测在 `LANAddressResolver`）、已连接节点列表（移除 → removeNodeFromFleet）、全局摘要、各 provider 额度来源、归因指纹不一致提示、字段独立防抖草稿 controller 与逐字段保存错误 / 重试 |
| `Sources/LLM-monitor/Services/Sync/SyncCoordinator.swift` | 多机联动运行时编排（@MainActor ObservableObject）：由 `DeviceIdentityStore` 提供稳定 nodeID（持久化成功才采用；启用前不创建、读写错误不降级成临时身份）、hub/node 生命周期与监听 ready/failed、热配置重启/重排与非法上游修正后的 node runtime 恢复、hub 本机报告合并与 generation 维护、node 周期+唤醒推送、health 握手、409 序号自愈、快照缓存与当前 POST 序号确认的 hub 数据库恢复 |
| `Sources/LLM-monitor/Models/DerivedValueMemo.swift` | 渲染期派生值的**值键 memo**（`Slot` 分槽、每槽只留最近一次、条目数有界）：键逐字相等才复用，刻意不做脏标记广播——漏一次失效等于界面静默显示过期数字；重算在锁外 |
| `Sources/LLM-monitor/Models/ClientIdentity.swift` | 身份语汇（QuotaProviderID / ClientID / ClientDescriptor / ClientProviderBinding）与默认绑定矩阵字面量（单一事实源） |
| `Sources/LLM-monitor/Models/UsageFrameExtractors.swift` | 帧抽取注册表 `usageFrameExtractors`（各 harness 的 ProviderStatus 字段 → `HarnessUsageFrame`，L1 适配） |
| `Sources/LLM-monitor/Models/UnifiedDailyTokenUsage.swift` | provider 中立日桶与当日 max 修补（`UnifiedDailyUsageNormalizer`） |
| `Sources/LLM-monitor/Models/MixedCurrencyEstimate.swift` | 跨 provider 金额汇总的统一折算类型（USD ×7 → CNY） |
| `Tests/LLMMonitorTests/MixedCurrencyEstimateTests.swift` | 跨 provider 金额折算（USD ×7 → CNY）、文案格式化与零金额兜底 |
| `Sources/LLM-monitor/Services/ClientUsageAggregation.swift` | L3 视图模型纯函数：设置页按共享额度池拆行及权威日桶差额保留、菜单 `HarnessTodaySummary` 与今日占比条段 `HarnessClientSegment`、`HarnessSummaryCache` |
| `Sources/LLM-monitor/Services/LayoutMetrics.swift` | Services 与 Views 共读的排版常量（图表宽 / 卡片列与内容层内边距） |
| `Sources/LLM-monitor/Models/ModelPricingCatalog.swift` | 计价引擎：加载 `Resources/ModelPricing.json`（首条命中 / exact / matchAll / zhipu 兜底 / 下划线归一化）并应用 DeepSeek 高峰倍率；资源 bundle 整体缺失时先过 `ResourceBundleProbe`、降级为空目录并记 error（不再启动即崩），bundle 在而 JSON 缺失 / 解析失败仍 preconditionFailure |
| `Sources/LLM-monitor/Models/ResourceBundleProbe.swift` | 资源 bundle 探测：按 SwiftPM 生成的 accessor 同序候选路径判断 `Bundle.module` 是否可用（`probe` 可注入、`isResourceBundleAvailable` 进程内缓存），供定价 / 节假日资源加载在缺失时走降级而不是 fatalError |
| `Sources/LLM-monitor/Resources/ModelPricing.json` | 价格数据：随 app 打包的唯一价格源（`ModelPricingJSONTests` 守门 schema 完整性） |
| `Sources/LLM-monitor/Resources/ChinaHolidays.json` | 法定节假日快照：随 app 打包的静态离线数据（`holidays` ∪ `inLieuDays` 日期并集，年份 [当前年-1, …]），由 `scripts/sync-holiday-data.sh` 生成，`HolidayCalendarTests` 守门 |
| `Sources/LLM-monitor/Models/ProviderStatus.swift` | UI-facing provider state + `ProviderKind` / `AccentColor` 枚举 |
| `Sources/LLM-monitor/Models/QuotaInfo.swift` | Provider-neutral quota 和 reset-credit 模型（ChatGPT 多 Key 独立额度 `openAIApiCreditsList` / `allOpenAIApiCredits` 与 `OpenAIApiCreditDetails` 字段及错误隔离；裁剪无引用方法） |
| `Sources/LLM-monitor/Models/QuotaWindowStatus.swift` | Provider 无关的额度窗口存在性（`.present` / `.absent`）；fetcher 在边界归一化 raw 状态码 |
| `Sources/LLM-monitor/Models/AntigravityModelKind.swift` | Antigravity 共享额度池 enum、展示名及样本模型分类（`gemini_models` / `gemini_argon` / `claude_and_gpt_models` 单一事实源，Argon 优先） |
| `Sources/LLM-monitor/Models/MinimaxModelKind.swift` | MiniMax 模型族与用量分类 |
| `Sources/LLM-monitor/Models/AppMetadata.swift` | 版本 / build 号（读 Info.plist，设置页「关于」展示） |
| `Sources/LLM-monitor/Models/AnyJSON.swift` | 弱类型 JSON（原 Antigravity RPC 递归解析用；阶段二b解析器退役后暂无生产调用方，类型与测试保留） |
| `Sources/LLM-monitor/Models/LocalUsageDaily.swift` | Antigravity / Agy / Codex / Minimax / GLM / DSH / OpenCode 共享的 7-day chart 协议 + 默认实现 |
| `Sources/LLM-monitor/Models/LocalDailyTokenUsage.swift` | 六个本地数据源共享的单日 token 聚合结构（统一收口原 `XxxDailyUsage`，on-disk JSON 键兼容） |
| `Sources/LLM-monitor/Models/LocalTokenUsageSample.swift` | Provider 中立的单次模型调用 sample（cache-inclusive input 口径 + `TokenUsageBuckets` 规范化入口；可选 `durationSeconds` / `ttftSeconds` 增强字段）；`PromptSpeedStatistics` 按 Prompt 聚合速度分布与最新值；TTFT 聚合（`CallTTFTStatistics` P50 / 窗口均值 / Σ-Σ 合并中间量）；额度窗口快照携带可选 Fleet 金额说明 `costText` |
| `Tests/LLMMonitorTests/PromptSpeedStatisticsTests.swift` | Prompt 多轮合并、缺失时长整组排除、最新值不回退、奇偶 P50、时间并列与零速率回归 |
| `Sources/LLM-monitor/Models/TokenAccounting.swift` | harness raw input / output 计数口径的元数据枚举（cacheInclusive / uncachedOnly 等） |
| `Sources/LLM-monitor/Models/ReasoningCharSplit.swift` | 「思考字符数 → 思考 token 数」的守恒拆分纯函数（`reasoning + output == 账面 output` 恒成立）；5 处调用方：GLM/ZCode（`GlmZcodeDBReader`）、MiniMax Code（`MinimaxLocalUsageAggregation`）、Dsh M3（`DshLocalUsageScanner`）、OpenCode（`OpencodeDBReader`）、Agy（`AgyLocalUsageAggregation`） |
| `Sources/LLM-monitor/Models/LocalUsageRetentionWindow.swift` | 本地用量「落盘前保留窗口」的唯一口径（`LocalUsageRetentionWindow`，Antigravity / Agy / DSH / GLM-ZCode / Minimax / OpenCode 六个 scanner 共享）；刻意区别于展示层 7 天窗口，契约由 `ScannerRetentionContractTests` 锁定——该契约逐条覆盖其中五个（Antigravity / Minimax / DSH / Opencode / GLM-ZCode），Agy 尚无逐条断言 |
| `Sources/LLM-monitor/Models/LocalUsageFreshness.swift` | 本地用量数据新鲜度（clean / dirty / scanning / failed）与独立的首次核对标记；LocalUsageSource.clientID 与 LocalUsageConsumer 映射 scanner 到 client/provider，用于 Fleet 来源隔离 |
| `Sources/LLM-monitor/Models/DisplayOrder.swift` | Stable-ID ordering helper for configurable Provider cards and alphabetical fallback lists |
| `Sources/LLM-monitor/Models/OpencodeLocalUsage.swift` | OpenCode provider 分片、今日 / 7 天聚合与逐次 samples |
| `Sources/LLM-monitor/Models/UsageProjectionKernel.swift` | Provider × Harness 投影内核：`HarnessUsageFrame` 适配（clientID/sourceKey/quota 归属）→ `UsageProjectionKernel.project` 出 per-client × per-provider 投影（daily + per-model 桶 + 名义价值）；promptID 命名空间规则表（`UsageSampleNamespace`）与 DSH 帧适配（`DshHarnessFrames`）在此，旧 `DshUsageMerger` / `OpencodeUsageMerger` 已吸收删除 |
| `Sources/LLM-monitor/Models/GlmLocalUsage.swift` | GLM ZCode 本地 token 用量聚合模型（单源、原生 reasoning / turn_id、闲时窗口挂载、非智谱 provider 分片挂载） |
| `Sources/LLM-monitor/Models/ZcodeProviderSlice.swift` | ZCode 非智谱 provider 分片枚举（`minimax` / `deepseek` 前缀谓词、quota 卡映射与样本 promptID 命名空间） |
| `Sources/LLM-monitor/Models/DshLocalUsage.swift` | DeepSeek Harness session token 数据模型与 provider 分片；分别记录扫描预算截断、样本数量截断、样本上限与最新遗漏样本时刻 |
| `Sources/LLM-monitor/Services/DshLocalUsageScanner.swift` | 读取 `~/.dsh/sessions` 的 JSONL/zstd session 日志，按 provider 聚合 7 天用量；样本 cap 完整性元数据、旧缓存 / 上限变化重建及 cached rebase 老化恢复 |
| `Sources/LLM-monitor/Models/AgyLocalUsage.swift` | agy CLI 本地 transcript token 用量快照模型（`isPartial` 出相等 / `isTruncated` 入相等的设计注释） |
| `Sources/LLM-monitor/Services/AgyLocalUsageScanner.swift` | 读取 `~/.gemini/antigravity-cli/brain/` 的 transcript JSONL + cli log 模型名时间线，聚合 7 天用量（预算截断 / 指纹缓存） |
| `Tests/LLMMonitorTests/AgyLocalUsageScannerTests.swift` | agy scanner 回归护栏（MODEL 行解析 / 去重 / 模型名 join / 缓存短路 / 预算截断 / 帧投影命名空间） |
| `Tests/LLMMonitorTests/FleetScopeSwitcherTests.swift` | Fleet scope 控件阈值、全局/本机/节点选项、分段与紧凑菜单切换及文案截断 |
| `Tests/LLMMonitorTests/LANAddressResolverTests.swift` | 局域网地址候选与挑选、接口类别优先级、MAC 偏移边界、虚拟与桥接网卡排除 |
| `Tests/LLMMonitorTests/SettingsSyncPaneTests.swift` | Fleet Sync 设置 pane 渲染、上游地址 / 端口校验、局域网地址检查、字段级草稿防抖 / rebase / 离开 pane flush、真实写盘失败的逐字段反馈和跨 pane 重建保留草稿 |
| `Tests/LLMMonitorTests/UsageReportBuilderTests.swift` | Fleet 日桶/窗口构建、失败空贡献标记不可用并省略对应窗口、健康来源继续上报、DSH 失败恢复及 binding 关闭、截断空帧不覆盖旧值、部分计价经合并仍保留 |
| `Tests/LLMMonitorTests/SyncModelsTests.swift` | Fleet DTO / 校验 / 合并、ASCII Gregorian 日键与跨系统日历生成、legacy 不完整日桶拒收、来源感知 partial 校验及金额覆盖度保留 |
| `Tests/LLMMonitorTests/FleetUsageModelsTests.swift` | Fleet 菜单与卡片投影、provider 全量日桶 / provider 窗口筛选、窗口历史与 wire 整秒比较、金额 coverage 和 stale 日桶提示 |
| `Tests/LLMMonitorTests/FleetCostTextPropagationTests.swift` | Fleet 金额说明从真实 DSH builder / 合并投影传到最终可见行：部分计价、混币 5h / 周 / 今及闲行文案 |
| `Tests/LLMMonitorTests/FleetHistoryValueTests.swift` | Fleet 历史数值金额优先级、混币折算、旧桶回退与不可用/部分覆盖回归 |
| `Tests/LLMMonitorTests/SettingsDraftIsolationTests.swift` | General/provider 草稿隔离：仅 Sync 或边缘窗位置写入不重载，真实表单外部变化仍触发热重载 |
| `Tests/LLMMonitorTests/DshLocalUsageScannerTests.swift` | DSH 真实日志扫描、预算及样本 cap、缓存命中 / 旧完整性元数据重建、限额变化和遗漏样本老化恢复 |
| `Tests/LLMMonitorTests/UsageProjectionKernelTests.swift` | Harness 帧归属、日聚合与模型计价、DSH 分片及独立样本完整性标记传播 |
| `Tests/LLMMonitorTests/TruncationProjectionChainTests.swift` | 截断状态沿扫描快照 / 帧 / 内核 / provider 投影到消费层的传播回归与已知完整样本夹具 |
| `Tests/LLMMonitorTests/FleetStoreTests.swift` | Fleet SQLite 通道/窗口持久化、坏行清理与 generation、序号及快照缓存 |
| `Tests/LLMMonitorTests/AppStateTests.swift` | AppState 发布行为，包括 Fleet 快照 / scope 专属通知、无效 scope 回退和展示状态更新后再广播 |
| `Tests/LLMMonitorTests/FleetSyncLifecycleTests.swift` | Fleet node 周期推送、非法 URL 修正后 runtime 恢复、hub listener 生命周期、配置热更新、0 周期序列化、禁用清快照、旧 runtime 响应隔离、同 UUID hub 数据库重建回填、设备身份独立于 config、关闭不创建与读失败重试 |
| `Tests/LLMMonitorTests/DeviceIdentityStoreTests.swift` | 独立 `.deviceId` 创建与复用、legacy config UUID 不继承、坏文件 fail-closed、私有权限及写入失败后可重试 |
| `Sources/LLM-monitor/Models/ProviderLocalUsage.swift` | Antigravity / minimax 共享的本地用量数据模型（保留历史类型别名） |
| `Sources/LLM-monitor/Fetchers/QuotaFetcher.swift` | `QuotaFetcher` protocol + 默认实现 |
| `Sources/LLM-monitor/Services/Infra/QuotaError.swift` | 统一错误类型 |
| `Sources/LLM-monitor/Fetchers/MinimaxTokenPlanFetcher.swift` | minimax Token Plan API 抓取 |
| `Sources/LLM-monitor/Fetchers/CodexFetcher.swift` | ChatGPT Plan API 抓取、多 Key Admin API 赠金并发抓取与错误隔离 + 本地 JSONL 解析 |
| `Sources/LLM-monitor/Fetchers/AntigravityFetcher.swift` | Antigravity 额度决策树（2.5.0）：ls 可用 → 本地 RPC 主路径（不读钥匙串）→ keychain 兜底开关 → 远端配额/账号（Keychain 凭据 + Google API，主机回退）→ 过期/401 按 `allowTokenRefresh` 走 agy 代理刷新或统一提示；主额度每拍、tier 按次要信息频率 |
| `Sources/LLM-monitor/Fetchers/AntigravityCredentialPolicy.swift` | Antigravity 凭据策略进程级状态（2.5.0）：启动预检三态（钥匙串授权被拒自动 disable ① / 条目缺失软不可用 / 未找到 agy CLI 自动 disable ②）、内存 token 缓存、agy 退避、`AntigravityAgyCLI`（agy 可执行查找 + `agy models` 运行：30s 超时、AsyncMutex 互斥、输出不落日志、invalid_grant 归类） |
| `Sources/LLM-monitor/Fetchers/AntigravityProcessDiscovery.swift` | Antigravity 进程发现（pgrep 分类排序 + lsof 端口 + CSRF 提取 + `serverStillOwnsEndpoint` TOCTOU 复查），2.5.0 起决策树第 1 步（本地用量 scanner 不消费） |
| `Tests/LLMMonitorTests/AntigravityRefreshCadenceTests.swift` | Antigravity 远端路径编排：主额度与次要账号/套餐（tier）、可选接口失败降级、额度失败传播、主机回退 |
| `Tests/LLMMonitorTests/AntigravityLocalFallbackTests.swift` | Antigravity 本地路径（决策树第 1 步）：ls 可用优先（不读钥匙串）、本地 RPC 失败落到远端兜底、`response` 包装解析归一化、CSRF 两种头、TOCTOU 落后续分支、tier 回退链 |
| `Tests/LLMMonitorTests/AntigravityCredentialPolicyTests.swift` | Antigravity 凭据策略单元契约（2.5.0）：预检三态与恢复、开关生效态、内存缓存命中/过期重读、退避窗口、agy 运行互斥、agy 可执行查找纯函数 |
| `Tests/LLMMonitorTests/AntigravityCredentialDecisionTreeTests.swift` | Antigravity 决策树分支（2.5.0）：兜底开关关、预检自动 disable、fresh token 远端、401 落凭据分支、agy 成功/失败/退避/重试、invalid_grant 提示、内存缓存省钥匙串读取 |

| `Sources/LLM-monitor/Fetchers/AntigravitySchemas.swift` | Antigravity 远端/本地配额响应的解码模型（`RetrieveUserQuotaSummaryResponse` / `RetrieveUserQuotaSummaryEnvelope` / `LoadCodeAssistRemoteResponse` / `UserStatus*` 一族）+ `LocalhostTrustDelegate` |
| `Sources/LLM-monitor/Fetchers/GlmCodingPlanFetcher.swift` | GLM Coding Plan 额度与 reset time 抓取（支持 `GlmAuthMode`：`apiKey` / `credential`；ZCode 套餐三路编排依赖注入 `ZcodePackageProviding`） |
| `Sources/LLM-monitor/Fetchers/DeepseekFetcher.swift` | DeepSeek 账户余额抓取（`/user/balance`）+ 解析 |
| `Sources/LLM-monitor/Models/PeakWindow.swift` | GLM / DeepSeek 共用的高峰时段判定与倍率（`slots` / `weekdaysOnly` / `multiplier`，支持 Provider JSON 覆盖）；北京时间判定，默认按 Rule A 排除周末与法定节假日，GLM 默认 14–18，DeepSeek 默认 9–12 / 14–18，倍率均为 2×；共享设置展示文本与 JSON 校验 |
| `Sources/LLM-monitor/Models/HolidayCalendar.swift` | 法定节假日快照模型（Rule A 的节假日数据源）：`Set<Int>` yyyyMMdd 日期键 + source/fetchedAt 元信息，`isHoliday` / `covers(year:)`；解析链纯函数（`parseSource` 源语义 / `parseSourceDates` 快照+上游 chinese-days 双格式 / `resolve` 缓存→bundle→empty / `isStale` 7 天新鲜度）与可更新的 `shared`（锁保护，`applyResolved` 替换）；bundle 加载 `loadBundled()` 先过 `ResourceBundleProbe`（资源 bundle 整体缺失时降级路径才可达）、缺失 / 损坏退化为空表并记日志；`sharedRevision` 随 `applyResolved` 递增（派生值 memo 的失效键）；上游 chinese-days 格式要求三键齐全（缺 `holidays`/`workdays`/`inLieuDays` 任一即按「格式不支持」拒绝，schema 变化不静默接受） |
| `Sources/LLM-monitor/Services/HolidayCalendarService.swift` | 节假日数据源服务（解析链编排 + best-effort 取数）：config `holidaySource` 的触发判定（启动 / 源变更 / 设置页立即更新）、缓存 `holidays-cache.json` 读写、HTTP 走 `HTTPClient` / 本地路径直读、成功后应用 `shared` + 宿主回调（UI 刷新）；失败不清空既有数据；设置页状态行 / 覆盖提示纯函数；缓存回写经 `FileManagerBox.writePrivate`（0600 / 0700） |
| `Sources/LLM-monitor/Services/AppState.swift` | 全局状态生命周期、刷新调度、配置 reload 接线（`configStore.startWatching()`）与 Provider batch/LocalUsage reconcile；provider 详情路由仅保存在进程内；显式启用 Fleet Sync 后以 config 同目录 `.deviceId` 构造 DeviceIdentityStore |
| `Sources/LLM-monitor/Services/AppState+Metrics.swift` | `AppState` 的系统健康度与状态栏额度来源目录、选项、读数与 tooltip 接线；主套餐复用 Fleet 生效额度，扩展池读取本机快照 |
| `Sources/LLM-monitor/Services/StatusBarQuotaProjection.swift` | 统一状态栏额度池与纯投影：主套餐接力聚合、独立单额度读数、动态窗口标题及单环 / 双弧布局选择 |
| `Sources/LLM-monitor/Services/AppState+LocalUsage.swift` | `AppState` 的本地用量扫描结果分发与回写（`LocalUsageStatusWriting`）extension（Antigravity/Agy/Minimax/ZCode/DSH/OpenCode） |
| `Sources/LLM-monitor/Services/AppState+Rebuild.swift` | `AppState` 的 Provider 状态派生（`deriveState`）与跨重建保留字段（`PreservedStatusFields`）extension |
| `Sources/LLM-monitor/Services/QuotaUpdateNotifier.swift` | 额度通知引擎：`QuotaEventDetector`（四类窗口事件边沿判定）+ `QuotaEventBatch`（按模型×渠道合并）+ 系统通知声音偏好、provider/model 点击路由 + `CompositeQuotaUpdateNotifier` 渠道扇出 |
| `Sources/LLM-monitor/Services/BarkNotifier.swift` | Bark 推送渠道：POST JSON 传输、稳定覆盖 id、锁屏/亮屏跳过判定、有界串行发送队列（冷却 / 重试 / 可取消）；日志 / 错误定位用固定标签 `bark://<host>/<key 前 4 位>…`（不回显完整 device key） |
| `Sources/LLM-monitor/Services/TriggerStateStore.swift` | 通知触发器基线持久化（`notification-state.json`），检测 previous 的跨重启单一来源；写盘经 actor 串行（0600/fsync）、`seq` 丢弃迟到旧快照，fsync 不占主线程 |
| `Sources/LLM-monitor/Services/LastRefreshStore.swift` | `last-refresh.json` 的 actor 化持久化（合并窗口 + encode/fsync 移出 MainActor） |
| `Sources/LLM-monitor/Services/AppLog.swift` | stdout / 文件 (5MB rotate) / os.Logger (`.private`) 三路日志；测试进程改写日志路径到 `NSTemporaryDirectory()`（`LLM_MONITOR_LOG_PATH` 最优先） |
| `Sources/LLM-monitor/Services/ConfigStore.swift` | 配置文件（config.json）读写、文件变更监听与持久化备份事务（数据模型已下沉至 Models/AppConfig.swift；debounce + 原子替换后重开 fd + 退避重试，由 `AppState.start()` 调用） |
| `Sources/LLM-monitor/Services/LoginItemService.swift` | `SMAppService.mainApp` 包装 + 状态显示 |
| `Sources/LLM-monitor/Services/Formatters.swift` | 基础格式化工具：Token 紧凑计数（K/M/G 阶梯）、速度三字符数值与数量级后缀、格式化整数、百分比与额度百分比（去无效 .0）、FormatterCache 缓存 |
| `Sources/LLM-monitor/Services/Formatters+Time.swift` | 时间与倒计时格式化扩展：统一相对倒计时格式化（`formatRelativeCountdown`）、相对时间（`formatRelativeShort`）、英文压缩倒计时（`formatResetSuffix`）、中文紧凑倒计时（`formatPeakDuration`）、数字时钟持续时长（`formatDigitalDuration`）、绝对时钟与日期（`formatClock` / `formatTimeOfDay` / `formatMonthDayMinute` 等）及 Codex 窗口标签与刷新间隔 |
| `Sources/LLM-monitor/Services/Infra/HTTPClient.swift` | 共享 HTTP 客户端（minimax / codex 三个 fetch 路径）；`ResponseByteLimits` 响应体硬上限（标准额度 8 MiB）由 `CappedDownloader.data` 在**响应体返回后**校验——超限抛 `responseTooLarge`，该错误为非瞬时（不重试、不进通知冷却）。async `session.data(for:delegate:)` 不向 per-task delegate 投递 `didReceive response` / `didReceive data` 内容回调（macOS 27 实测：URLProtocol 桩与真实网络均不触发），因此 `CappedDownloadDelegate` 的流式计数在当前调用方式下**不执行**，真正的拦截点是后置字节校验；delegate 保留待将来改用回调系任务。峰值内存仍由 URLSession 缓冲决定——该上限保证超限响应不进入调用方解析链路，不保证单次响应不被完整缓冲 |
| `Sources/LLM-monitor/Services/LocalUsageCoordinator.swift` | scanner 协议 + Combine wire-up 容器；MainActor 同步应用结果，再转发完整结果验证/新鲜度回调 |
| `Sources/LLM-monitor/Services/ProviderRefreshScheduler.swift` | 循环 A（额度循环）：单一 Task 管理所有 Provider 的 quota 定时排期，睡眠至最早截止时间，并发刷新 + 条目级隔离；配置重载走差异化重排 `reconfigure(managed:)`（未变 provider 保留 deadline 与首刷状态，避免每次写配置全员重抓）；loop 带实例 token（`cancelAll` 后旧 loop 收尾不再清新 loop 的 sleepTask、不再进入下一轮迭代） |
| `Sources/LLM-monitor/Services/ManualRefreshGate.swift` | 手动 full refresh 与 in-flight background refresh 的合并协议（pending 登记 / 取消撤销 / 一次性补跑） |
| `Sources/LLM-monitor/Services/LocalUsageOrchestration.swift` | LocalUsage reconcile：按触发原因分层为 `.dirty` / `.full`（cache-assisted） / `.hardFull`（绕过各 provider 自己的 fingerprint / offset / cache），请求按 `dirty < full < hardFull` 优先级折叠成一次；`.hardFull` 只在启动首拍、日历签名失效与 `bypassesProviderCache` 时触发。Provider batch settled 后每拍都投递一次 reconcile（scanner 内部指纹短路决定是否真扫），不持有 Timer |
| `Sources/LLM-monitor/Services/LocalFSEventsWatcher.swift` | 可复用的单 scanner FSEvents 封装；每个 scanner 自己持有 watcher 与源路径，不维护全局路径表；`info` 载荷为 passRetained 的 context box（对 watcher 弱引用，stream↔watcher 不成环；旧的裸 unretained 指针已移除） |
| `Sources/LLM-monitor/Services/LocalVnodeWriteWatcher.swift` | 文件级 write/extend vnode watcher（持续增长的日志文件 dirty 标记；只报 dirty，扫描仍归 provider 循环） |
| `Sources/LLM-monitor/Services/AuthProber.swift` | 异步探测本地服务（antigravity）是否还活着 + 缓存 + 离/在线变化回调 |
| `Sources/LLM-monitor/Fetchers/RefreshResultMergers.swift` | `CodexFillingMissingMerger`（含多 Key 独立匹配、降级 stale 保留与组织名跨模式保留）、`GlmFillingMissingMerger` 与 `AntigravityFillingMissingMerger`：次要信息跨模式保留、主额度与金额采用新值（Minimax 使用默认 `IdentityRefreshResultMerger`） |
| `Sources/LLM-monitor/Services/Infra/DateParser.swift` | ISO8601 / unix timestamp 统一解析 |
| `Sources/LLM-monitor/Services/Infra/StringUtilities.swift` | 字符串小工具（trim / firstTrimmed） |
| `Sources/LLM-monitor/Services/Infra/ProcessRunner.swift` | 同步短命令子进程执行器（pgrep / lsof / pmset / zstd / node；持续排空 pipe + 超时与取消检查）；文件输出可选流式硬限额，超限终止；产出文件以 0600 出生 |
| `Sources/LLM-monitor/Models/SaturatingArithmetic.swift` | 非负计数饱和算术（负值归零、溢出封顶 `Int.max`），聚合入口防损坏输入 |
| `Sources/LLM-monitor/Services/LocalUsageDayKey.swift` | `yyyy-MM-dd` day key（跟 SQLite `strftime` 对齐） |
| `Sources/LLM-monitor/Services/LocalUsageCalendarSignature.swift` | 决定本地日桶的日历输入签名（`LocalUsageCalendarSignature.make(calendar)`），随 provider 缓存落盘；冷启动时源文件没变也不会把按旧时区分组的快照当成当前数据 |
| `Sources/LLM-monitor/Services/TokenMonitorPaths.swift` | 全部本地用量 scanner 的共享落盘位置（`~/Library/Application Support/LLM-monitor/token-monitor/<provider>.json`）+ Antigravity 旧缓存目录 `legacyAntigravityCacheDir` |
| `Sources/LLM-monitor/Services/Infra/SQLiteConnection.swift` | SQLite3 通用连接层（三层读策略：无 -shm 且无 dirty WAL 时 immutable=1 直读；活跃时共享内存只读；异常由 SQLiteTempCopy 走 /tmp 副本 recovery） |
| `Sources/LLM-monitor/Services/Infra/SQLiteTempCopy.swift` | `/tmp` 副本 fallback：回退白名单 CANTOPEN / BUSY / READONLY 家族 / IOERR 家族 / CORRUPT，以及 immutable 直读打开后复检发现 `-shm`/`-wal` 出现的 `lostImmutableRace`（直读前提失效，非扫描失败）。副本读取同样 CORRUPT 时按源指纹（db/-wal/-shm 的 mtime+size，进程内不落盘）记忆为持久损坏，后续轮次跳过全量拷贝快速失败，指纹变化即失效恢复重拷——并发 checkpoint 撕裂页的重拷自愈路径不受影响。拷贝循环逐文件校验源指纹：db 拷完立即复验，失效即放弃本轮 wal/shm 拷贝，最多 3 轮后抛 `sourceChangedDuringSnapshot`；App 自有临时根 `$TMPDIR/llm-monitor-sqlite/`（0700）由启动 sweep 回收：DSH 解压残留（`llm-monitor-dsh-` 前缀）无条件删除、SQLite 副本按 24h 年龄 |
| `Sources/LLM-monitor/Views/Color+Theme.swift` | 品牌色常量 + provider 卡 accent 映射（`AccentColor.cardAccentColor`，卡片与今日占比条共用） |
| `Sources/LLM-monitor/Services/MenuBarRightClickHandler.swift` | 状态栏按钮右键菜单（best-effort） |
| `Sources/LLM-monitor/Services/StatusBarQuotaMetrics.swift` | 状态栏额度指标结构（`QuotaRingMetrics` / `StatusBarQuotaMetrics` / `StatusBarSingleQuota`），由 Icon Duo 仪表盘消费 |
| `Sources/LLM-monitor/Services/IconDuoSVGBuilder.swift` | Icon Duo 状态栏额度仪表盘的参数化 SVG 生成：双窗左右弧 / 有效5h数字 / 底部健康点，或单额度圆环 / 对应额度数字；共用固定字号CoreText字形轮廓并按实际边界居中（100%→00，省略百分号）；休眠灯位于同一圆周的顶部缺口内，每侧与圆弧端帽留0.75灯径净空 |
| `Tests/LLMMonitorTests/StatusBarQuotaSelectionTests.swift` | Provider + 来源选择、动态窗口形态、API / 活动权益隔离、未知与耗尽、有效期与全局聚合回归 |
| `Sources/LLM-monitor/Services/MinimaxDBReader.swift` | 读 minimax v2 `local_runtime_token_usage` 表 |
| `Sources/LLM-monitor/Services/MinimaxLocalUsageScanner.swift` | minimax v2 `runtime-state.sqlite` 单源 scanner（AsyncMutex + lastCommittedGeneration 串行化）|
| `Sources/LLM-monitor/Services/MinimaxLocalUsageAggregation.swift` | minimax reasoning 字符分摊比例回写 sample 与 per-day 聚合纯函数 |
| `Sources/LLM-monitor/Services/MinimaxSessionModelResolver.swift` | MiniMax 会话模型名解析与映射 |
| `Sources/LLM-monitor/Services/AgyLocalUsageAggregation.swift` | agy transcript MODEL 行解析、跨文件去重、reasoning 拆分（f4 原生真值优先 + 字符守恒分摊回退）与日聚合纯函数 |
| `Sources/LLM-monitor/Services/GlmZcodeDBReader.swift` | ZCode `model_usage` 表 SQL 读取 + reasoning 字符分摊（智谱行与分片统一三段式，native 列优先）+ per-day 聚合与 samples + 非智谱 provider 分片聚合（`ZcodeProviderSliceAggregate`） |
| `Sources/LLM-monitor/Services/GlmZcodeOffPeakReader.swift` | `~/.zcode/v2/tasks-index.sqlite` 闲时任务时间窗口读取（额度窗口排除依据） |
| `Sources/LLM-monitor/Services/GlmZcodeCredentialReader.swift` | ZCode 本地凭证与设备标识读取（`~/.zcode/v2/telemetry-state.json` 的 deviceMid + `credentials.json` 的 zcodejwttoken AES-256-GCM 解密） |
| `Sources/LLM-monitor/Services/GlmZcodeAPIClient.swift` | ZCode 直连 API 客户端（Start Plan / 额度重置卡 / 营销活动触达直连解析与请求；同文件定义 `ZcodePackageProviding` 协议与默认实现 `GlmZcodeAPIPackageProvider`） |
| `Sources/LLM-monitor/Services/ZcodeAppVersionResolver.swift` | ZCode app 版本解析（按 bundle id 定位本机 ZCode.app 读 Info.plist 的 `CFBundleShortVersionString`，失败回退 `3.17.1`；进程内缓存 + 显式刷新入口，plist 路径可注入） |
| `Sources/LLM-monitor/Services/GlmZcodeLocalUsageScanner.swift` | GLM ZCode `db.sqlite` 单源 scanner（AsyncMutex + lastCommittedGeneration 串行化） |
| `Sources/LLM-monitor/Services/AntigravityLocalUsageScanner.swift` | Antigravity `.db` 直读 scanner（AsyncMutex + lastCommittedGeneration 串行化；脏 session 经 `AntigravitySessionDBReader` 全量直读，不发网络请求）|
| `Sources/LLM-monitor/Services/AntigravitySessionDBReader.swift` | Antigravity 会话 `.db` 直读模块：`probe` 版本指纹门（`gen_metadata` 首行模型名）+ `readCalls`（`steps.idx == f20.last_step_index + 1` 连接）+ `readUserTurnSteps`（step_type=14）；经 `SQLiteTempCopy`（原路径 READONLY + /tmp 副本兜底） |
| `Sources/LLM-monitor/Services/AntigravityFilesystem.swift` | `AntigravityLocalUsageScanner` 的文件系统侧 extension：conversations roots 枚举（只收 `.db`，`.pb` 忽略）、指纹与 v10 index I/O、`isComplete` 语义（权限 / TCC / 瞬时 I/O 不得据此删缓存） |
| `Sources/LLM-monitor/Services/AntigravityLocalUsageCache.swift` | `AntigravityLocalUsageScanner` 的缓存与 index 类型 extension（与上面的 scanner 同类型，按职责拆文件） |
| `Sources/LLM-monitor/Services/AntigravityLocalUsageAggregation.swift` | Antigravity per-day 聚合与 sample 组装（`accountCalls`：turns = step14 直计、rounds = 连接命中 Call；纯函数，unit-testable） |
| `Sources/LLM-monitor/Services/AntigravityStepTimestampReader.swift` | Antigravity SQLite step 的 protobuf Timestamp 读取 + agy 共用的 gen_metadata 原生 usage 读取（f1.f4：f9 reasoning / f10 normalized，守恒门控供 agy 拆分；f1.f11 曾误作 TTFT 接入，已证伪回退）（antigravity 路径阶段二b改由 `AntigravitySessionDBReader` 直读双时间戳） |
| `Sources/LLM-monitor/Services/OpencodeDBReader.swift` | 读取 OpenCode `message` 表并按 provider / day 聚合 |
| `Sources/LLM-monitor/Services/OpencodeUsageScanner.swift` | OpenCode DB 指纹、缓存、7 天窗口与 provider slice snapshot |
| `Sources/LLM-monitor/Services/Infra/AsyncMutex.swift` | actor-based async-aware mutex（scanner pipeline 互斥；支持 caller cancellation propagation — acquire 前 / 排队中 / acquire 后执行前三阶段均检查取消）|
| `Sources/LLM-monitor/Services/CancellationFilter.swift` | 统一"取消错误"判断（`Task.isCancelled` / `CancellationError` / `URLError.cancelled`），AppState 与 LocalUsageScanRunner 的两个 catch 入口共用 |
| `Sources/LLM-monitor/Services/Infra/FileManagerBox.swift` | `FileManager` 的 `@unchecked Sendable` 包装 + `fileManager` 字段 `private`（同文件 extension 之外不能直接拿到底层 `FileManager`）。`Tests/LLMMonitorTests/ConfigStoreTests.swift` 验证该访问约束；`temporaryURL()` 落 App 自有临时根（供 DSH 解压，崩溃残留可被启动 sweep 回收）。命名约定：本套 spec 说「`index.json`」指**版本化索引文档本身**（schema 名，也是目录形态输入与测试下的文件名）；生产落盘文件是 `token-monitor/<provider>.json`（共 7 个：`antigravity.json` / `minimax.json` / `dsh.json` / `glm-zcode.json` / `opencode.json` / `agy.json` / `codex.json`，见 `config.md` 运行时文件表） |
| `Sources/LLM-monitor/Services/Infra/HTTPTimeouts.swift` | HTTP timeout 集中地（国内 domestic 10s / 海外 overseas 15s / antigravity 本机回环），改一处全局生效 |
| `Sources/LLM-monitor/Services/Infra/ScheduledTask.swift` | 主线程延时调度工具集：`FixedDeadlineTask`（固定截止时间节流防饿死）、`KeyedScheduledTask`（按目标键固定截止调度）、`DebouncedTask`（经典静默防抖）、`LadderScheduledTask`（多阶梯重试调度） |
| `Sources/LLM-monitor/Services/Infra/LRUCache.swift` | 通用 $O(1)$ LRU 缓存容器（双向链表 + 字典；动态容量收缩与白名单键裁剪；Codex 本地扫描器复用） |
| `Sources/LLM-monitor/Services/Infra/DshLogDecoder.swift` | DSH zstd 日志流式解压器（优先调用 zstd CLI，Node 22+ zlib 回退；单文件 1GB 明文上限与堆内存约束） |
| `Sources/LLM-monitor/Services/Infra/LogFileSnapshot.swift` | 通用日志文件快照（`LogFileSnapshot`）、增量失效指纹（`LogFileFingerprint`）与双预算切片选取器（`LogFileSelector.select`，DSH 与 Agy 共用） |
| `Sources/LLM-monitor/Services/LocalUsageScanRunner.swift` | 本地用量 scanner 共享的 lifecycle helper（generation 守门 / cancellation filter / defer generation 守门），消除镜像 boilerplate |
| `Sources/LLM-monitor/Services/SingleDBSnapshotScanner.swift` | 单库全量快照 scanner 基座（db + WAL 双维指纹与缓存 index；GLM / OpenCode scanner 复用） |
| `Sources/LLM-monitor/Services/DailyUsageAggregation.swift` | minimax / antigravity 共享的 per-day 聚合（补零填充 + 跨 source 合并） |
| `Sources/LLM-monitor/Services/ScannerIndexIO.swift` | 7 个 scanner 共用的 versioned 缓存 index 读写（版本迁移 / 不匹配 reset）：`MinimaxLocalUsageScanner` / `AntigravityFilesystem` / `DshLocalUsageScanner` / `AgyLocalUsageScanner` / `CodexLocalUsageScanner` 直接调用，另两个经 `SingleDBSnapshotScanner` 基座（GLM-Zcode / OpenCode）调用 |
| `Sources/LLM-monitor/Services/ScannerFileError.swift` | scanner 共用的「明确不存在」错误判断（权限 / TCC / 瞬时 I/O 不误判为删除，保护 last-good cache） |
| `Sources/LLM-monitor/Services/LocalUsageScannerBase.swift` | 本地用量 scanner 的状态、generation、取消与 in-flight 去重基座 |
| `Sources/LLM-monitor/Services/LocalUsageSourceLifecycle.swift` | 本地用量源的 FSEvents/vnode 生命周期与 dirty 事件桥接 |
| `Sources/LLM-monitor/Services/CodexLocalUsageScanner.swift` | Codex session JSONL 本地用量缓存与窗口汇总 |
| `Tests/LLMMonitorTests/CodexCachePersistenceTests.swift` | Codex session 本地用量索引磁盘持久化、Codable 往返与版本校验 |
| `Sources/LLM-monitor/Models/SleepHealthModels.swift` | 「节能」模块 UI 与服务实现之间的稳定数据契约（断言快照 / 电源参数 / 健康度结果） |
| `Sources/LLM-monitor/Services/SleepHealthService.swift` | 睡眠健康度快照、防休眠断言与周期健康边界刷新 |
| `Sources/LLM-monitor/Services/SleepHealthEvaluator.swift` | 睡眠锁与系统电源参数的健康度评估 |
| `Sources/LLM-monitor/Views/MenuBarLabel.swift` | 菜单栏 label 视图（可见输入签名去重重绘 + 分钟时钟监听，App 图标 / Icon Duo / SF Symbol 多样式）；label 宿主挂接公开 `openWindow` 路由桥 |
| `Sources/LLM-monitor/Views/ProviderDetailWindowView.swift` | 单实例 Provider 详情窗口、菜单栏公开 Window 路由桥、停用/缺失目标的设置回退；复用完整 `ProviderCardView`；窗口最小宽 `minimumWindowWidth` 由 expanded 表格常量与两层 padding 推导，并注入 `quotaTableFillsWidth` 弹性列宽 |
| `Sources/LLM-monitor/Views/MenuContentView.swift` | 主面板（header / content / footer；header 统一页面级刷新：用量读 LocalUsage 时间并重扫，额度读 Provider 成功数据时间并刷新；footer 无重复时间）+ 高度桥 `MenuPanelHeightBridge` + `MenuHairline`；展示时钟经 `\.displayDate` 注入卡片 |
| `Sources/LLM-monitor/Views/FleetScopeSwitcher.swift` | fleet scope 切换控件（菜单面板与 dock 详情浮层共用：≤4 段整行、>4 紧凑下拉）：`FleetScopeSwitcher` 按选项总数分叉（≤4 分段 `Picker`、>4 下拉 `FleetScopeMenu`），`FleetScopeMenu` 是下拉形态——范围文字 + 行内 `ellipsis` 标记，整组上限 120pt，截断走纯函数 `FleetScopeMenu.truncated(_:maxWidth:)`；三个 macOS `Menu` 平台怪癖（行内图 / 字符串层限宽 / 必须 `fixedSize`）写在文件头 |
| `Sources/LLM-monitor/Views/DisplayClock.swift` | 跨宿主共享的展示时钟：`DisplayClock` + `DisplayClockScope` + `\.displayDate` 环境键；菜单内容 / hover 浮层 / dock 浮层 / provider 详情窗口各自持有实例、随宿主显隐 start/stop 并注入环境，`start()` 与 `refreshNow()` 即时同步墙钟 |
| `Sources/LLM-monitor/Views/HarnessUsageMenuView.swift` | 菜单用量与额度紧凑卡片（`HarnessUsageMenuView` / `MenuQuotaOverviewView`）：今日汇总、客户端占比、客户端段为引导线树形（2026-11-07 起；harness 汇总合并到一级行，折叠即一行；`HarnessMetricColumns` 并集定宽簇两级行字段级对齐；原方块卡片、独立摘要行与 Prompt 速度范围线均已移除，速度为 P50 文本）。额度行展示有效额度、重置倒计时、临期/高峰事件、右侧时间与刷新；套餐详情/用量历史独立折叠、独立窗口可达，长摘要与三操作分行；`MenuContentMode` 由宿主持久化。布局回归见 `HarnessUsageMenuViewTests` |
| `Sources/LLM-monitor/Views/MenuTypography.swift` | 菜单面板与悬浮层统一排版常量（语义角色，禁止散落硬编码字号） |
| `Tests/LLMMonitorTests/MenuRefreshPresentationTests.swift` | 页面额度时间来源：启用项、失败保留成功数据、持久成功时间与空态 |
| `Sources/LLM-monitor/Views/MenuWindowAutoCloseBridge.swift` | 失焦立即关 + 30s 无交互关闭（菜单内 mouse/scroll/key 重置计时）；关闭统一出口 `performClose` 并发 `onPanelClose`（菜单展示时钟随之停表）；30s 计时为单个可复用 `DispatchSourceTimer`（reset 只改 deadline，鼠标事件不再重建句柄） |
| `Sources/LLM-monitor/Views/ProviderCardDerived.swift` | 卡片 body 的派生值入口：投影 + 额度窗口快照 + 「今」行 + 「闲」行（GLM 今日闲时，`offPeakUsageRow`）+ 「免 / 速 / 它」今日动态行（`glmCategoryUsageRows`，按 `GlmUsageCategory` 今日切片）打包成一个 memo 值（共享失效条件；键 = 全值 `status` + 墙钟日 + 展示日 + `HolidayCalendar.sharedRevision` + 时区标识），展示时钟每秒 tick 不再重算 O(samples) 定价 |
| `Sources/LLM-monitor/Views/ProviderCardView.swift` | provider 卡片 + `ProviderStateLabel` + `QuotaSummary`；卡片 header 显式刷新按钮（`arrow.clockwise`，加载中显示 `ProgressView`）与时间戳胶囊刷新；支持多 Key ChatGPT API 额度独立行渲染；`ProviderCardPresentation` 分 complete / plan / edgePlan / history，共用账号+套餐模块与七天历史；body 派生值经 `ProviderCardDerivedValues` 值键 memo；多节点 scope 控制用 `FleetScopeSwitcher` |
| `Sources/LLM-monitor/Views/StatusBarQuotaSelector.swift` | Provider 卡片与菜单栏 quota 行共用的状态栏 Provider / 额度来源眼睛菜单；`StatusBarQuotaSourcePinButton` 放在主套餐 / API Key / 活动权益标题后，单击固定具体额度，实心眼睛表示当前来源 |
| `Sources/LLM-monitor/Views/QuotaViews.swift` | 各种 quota 行 + 进度条（`CombinedQuotaWindowRow` / `CombinedQuotaBar` / `SingleQuotaBar` / `ModelQuotaDockBlock` / `CompactResetCreditsRow` / `QuotaBarTooltip`）；重置倒计时与过期判定随宿主展示时钟推进（`\.displayDate`）。`OffPeakUsageFootnote` 已删除，GLM 闲时用量改由「额度窗口」表格「闲」行承担 |
| `Sources/LLM-monitor/Views/QuotaWindowUsageViews.swift` | 「额度窗口用量」区块族：模块标题 / 细分隔线、四桶绝对值与三个比率（`QuotaWindowUsageMetrics`）、双段 capsule 切换（`QuotaWindowUsageSegmentControl` / `QuotaWindowUsageSegment`）、reset credits 明细（`ResetCreditsDetailList`）与合并统一 7 列 Grid 骨架的总段 `QuotaWindowUsageSection`；重置日期格倒计时随宿主展示时钟推进（`\.displayDate`） |
| `Sources/LLM-monitor/Views/HoverPanel.swift` | `HoverInfoRow` / `HoverPanelController` / 浮层管理；浮层显隐驱动共享展示时钟（经 `DisplayClockScope` 注入） |
| `Sources/LLM-monitor/Models/EdgeDockEntry.swift` | `EdgeDockEntry` + `EdgeDockProjection`：已启用 Provider → 按窗口数量选择单环/双环的条目（双环外环=5h 有效额度 min(5h, 周×N)、内环=原始周，各自最低 + 健康档位 + 品牌 kind）；DeepSeek 单独投影账户可用性并展示单状态圈，不生成窗口比例，纯函数 |
| `Sources/LLM-monitor/Models/EdgeDockConfig.swift` | `DockEdge` / `EdgeDockConfig`：贴边方向 + 归一化位置（存比例不存绝对坐标），含手改值归一化 |
| `Sources/LLM-monitor/Services/EdgeDockGeometry.swift` | 边缘窗纯几何：行高/尺寸、贴边 frame、offset 往返换算、有限边线段距离与吸附、行/圆矩形推算（兜底用）、popover 定位、保留抓取比例的沿边拖拽换算、贴屏侧直边的非对称标签形状 |
| `Sources/LLM-monitor/Services/EdgeDockDisplay.swift` | 屏幕稳定身份（`EdgeDockDisplay`，display UUID）：边缘窗跨屏只记 UUID，不记 `NSScreen` 对象 / 数组下标 / 几何位置 |
| `Sources/LLM-monitor/Services/FullscreenProbe.swift` | 当前 Space 全屏判定（`CGWindowList` 只读窗口边框 + 桌面装饰是否存在，fail-open，不需要辅助功能权限） |
| `Sources/LLM-monitor/Services/ScreenChromeProbe.swift` | 屏幕边缘与 Dock 遮挡探测 |
| `Sources/LLM-monitor/Services/EdgeDockController.swift` | 边缘窗控制器本体：状态与配置（`applyRuntimeConfig` 是运行时改配置的唯一入口，`config` 的 setter 保持 private）+ 接线（`attach` / `teardown`） |
| `Sources/LLM-monitor/Services/EdgeDockController+Window.swift` | `NSPanel` 建/拆、按条目数与形态算窗口尺寸、贴到目标屏那一侧、"为什么没出现 / 出现在哪"的日志签名 |
| `Sources/LLM-monitor/Services/EdgeDockController+Mouse.swift` | 鼠标穿透与悬停接管：monitor 装卸、2Hz 轮询节拍、命中后的接管与释放、hover / 展开 / 收起挂起任务，以及松手未拖动（`!pressBecameDrag`）时点击 Provider 圆环触发该 provider 独立立即刷新（`refreshOne`） |
| `Sources/LLM-monitor/Services/EdgeDockController+Popover.swift` | Provider 卡片浮层（与 dock 两个独立窗口）：定位、显隐、鼠标停在浮层上时的接管保持（`ignoresMouseEvents = false` 接收交互并注入 `quotaWindowSegmentEditable = true`），并经 `DisplayClockScope` 注入随显隐 start/stop 的展示时钟 |
| `Sources/LLM-monitor/Services/EdgeDockController+Drag.swift` | 沿贴靠边滑动拖拽：抓取位置保持、跨屏换屏 UUID、落点吸附与位置持久化；鼠标松手由 `+Mouse` 补足最终坐标与阈值判定 |
| `Sources/LLM-monitor/Services/EdgeDockController+Fullscreen.swift` | 全屏门控：判定变化后重排窗口，以及窗口进出场动画期间的阶梯补测 |
| `Sources/LLM-monitor/Services/EdgeDockController+HitTesting.swift` | 边缘窗命中判定纯函数（`circleIndex` 圆命中 + `resolveRowRects` / `resolveCircleRects` 实测优先、几何兜底），`nonisolated static`，不读实例状态 |
| `Tests/LLMMonitorTests/EdgeDockDragTests.swift` | 区外边缘距离、40pt 换边门槛、抓取位置与方向切换、松手末帧持久化回归 |
| `Sources/LLM-monitor/Views/EdgeDockContentView.swift` | 边缘窗视图（双窗口=外环5h有效额度+内环周、单窗口=单环、余额=单状态圈，中心=Provider 品牌图标，刘海式背景） |
| `Sources/LLM-monitor/Views/TokenBucketBar.swift` | 水平三段占比条（input / cacheRead / billableOutput，reasoning 并入 output），输入为 `TokenAccounting` 归一化四桶；桶色与 7 天柱图一致 |
| `Sources/LLM-monitor/Views/AccountHoverViews.swift` | 账号信息值类型 + 行（`QuotaWindowAccountInfo` / `QuotaWindowAccountInfoRow`）：卡片第一段「Account Info」常驻行，取代已删除的折叠区与 `AccountHoverView` 浮层 |
| `Sources/LLM-monitor/Views/GlmPeakIndicatorView.swift` | GLM 高峰期提示行（倒计时 + 三档颜色） |
| `Sources/LLM-monitor/Views/GlmActivityPlanBalancesView.swift` | GLM 活动套餐余额展示行（OpenAI 赠金同款一等配额块：生效中带进度条与失效倒计时 `剩余X小时`、未生效置灰带生效倒计时 `X小时后生效`，两者都空则不渲染） |
| `Sources/LLM-monitor/Views/DeepseekPeakIndicatorView.swift` | DeepSeek 高峰期提示行（北京时间倒计时，内嵌余额行右侧） |
| `Sources/LLM-monitor/Views/DeepseekBalanceRow.swift` | DeepSeek API 余额专用展示行（充值与赠金明细、高峰提示布局与 between 注入） |
| `Sources/LLM-monitor/Views/ChatGPTPlanModelRow.swift` | ChatGPT Plan 专用模型行（双窗口 dock 进度条与本地 token 聚合计算） |
| `Sources/LLM-monitor/Views/ChatGPTApiCreditsRow.swift` | ChatGPT API 赠金用量与周期进度行（多 Key 备注标签 `titleText`、组织信息、通栏额度条+时间标记三角、单行已用/剩余与周期倒计时、per-key 错误提示与 Formatters 倒计时复用） |
| `Sources/LLM-monitor/Views/PeakIndicatorView.swift` | 高峰提示行公共组件（`TimelineView` 外壳 + `formatDuration`，GLM / DeepSeek 共用） |
| `Sources/LLM-monitor/Views/BrandLogoView.swift` | provider 品牌 logo 资源加载 + SF Symbol fallback |
| `Sources/LLM-monitor/Views/LocalUsageHoverViews.swift` | 7 天用量新鲜度状态机与胶囊（`LocalUsageFreshnessState` / `LocalUsageFreshnessBadge`）；数值逐日价格（`LocalUsagePriceByDay`）与 Prompt P50 memo（`LocalUsageSpeedByDay`）、调用级 TTFT P50 memo（`LocalUsageTTFTByDay`） |
| `Sources/LLM-monitor/Models/UsageHistorySeries.swift` | 九维历史指标（含 TTFT）、独立偏好键与数值日序列；固定七日槽、缺失与已知零、混币归一化及部分覆盖 |
| `Sources/LLM-monitor/Views/SevenDayUsageHistoryChart.swift` | 菜单/详情窗口/设置共用七天单指标折线、指标图例、逐日表与来源提示；支持 compact/expanded 布局模式，坐标轴与日期标签提升为 secondary；expanded 表格列宽下限住在 `SevenDayUsageChartMetrics.expanded*`，expanded 下弹性填满可用宽度、compact 保持固定列宽 |
| `Tests/LLMMonitorTests/UsageHistorySeriesTests.swift` | 七日槽、四桶守恒、数值价格/混币、P50、缺失/零与部分样本回归 |
| `Tests/LLMMonitorTests/GlmZcodeCredentialReaderTests.swift` | ZCode 本地凭证读取与 AES-256-GCM JWT 解密/密钥派生/格式容错单元测试 |
| `Tests/LLMMonitorTests/GlmZcodeAPIClientTests.swift` | ZCode 直连 API 响应解析、重置卡前三截断、套餐余额与预告、ProviderConfig/Draft 状态同步、三条 parse 路径 `code != 0` 业务错误单测 |
| `Tests/LLMMonitorTests/GlmZcodePackageOrchestrationTests.swift` | ZCode 套餐三路编排测试（注入 `ZcodePackageProviding` stub）：部分失败降级与 `GlmFillingMissingMerger` 衔接、凭证缺失三路全跳过、marketing/reset 的开关与 background 门控、全失败保留既有数据 |
| `Tests/LLMMonitorTests/ZcodeAppVersionResolverTests.swift` | ZCode app 版本解析（可注入 plist 路径）：正常读取/trim、缺键/空值/坏 plist/未安装回退、缓存与显式刷新 |
| `Tests/LLMMonitorTests/SevenDayUsageLastColumnTests.swift` | `SevenDayUsageHistoryMetricTests`：历史偏好独立于额度 segment、每日 Prompt P50 与 Fleet 无时长回归（替代旧末列耦合测试） |
| `Sources/LLM-monitor/Views/SegmentedQuotaProgressBar.swift` | 5h / 周额度分段条（约 100 槽微栅格体系，固定 2.0pt 点宽与 1:1 呼吸间距，Half-Down 吸附点亮）、窗口颜色与 reset 标记 + `EquivalentQuotaAllocation`（binding constraint 文案与 `bindingWindow` 判定） |
| `Tests/LLMMonitorTests/QuotaAllocationTests.swift` | 额度分段吸附计算、周等价换算与瓶颈窗口判定回归 |
| `Tests/LLMMonitorTests/PeakPricingConfigTests.swift` | Provider 高峰配置默认值、JSON 往返与非法值、1.5× / 3× 计价、自定义时段与午夜结束边界回归 |
| `Tests/LLMMonitorTests/ChatGPTApiCreditsRowTests.swift` | 多 Key 赠金名称展示、首尾空白处理与未命名序号回退 |
| `Tests/LLMMonitorTests/AlertThresholdConfigTests.swift` | 告警阈值配置默认值、取值区间裁切与 critical <= warning 约束单测 |
| `Sources/LLM-monitor/Views/SettingsEnergyPane.swift` | 设置页节能 pane：睡眠健康度、防休眠与电源参数矩阵 |
| `Sources/LLM-monitor/Views/SleepAssertionOffender+RowText.swift` | 「阻止休眠的第三方应用」行文案（`SleepAssertionOffender` 的行格式化 extension）+ 主面板 header 悬浮清单 `SleepOffendersHoverView`，两处共用同一份格式 |
| `Sources/LLM-monitor/Views/SettingsClientsPane.swift` | 设置页「客户端」tab：按 provider 与共享额度池归组的本地用量诊断、共享七天历史；无归因开关 |
| `Sources/LLM-monitor/Views/ClientSegmentedControl.swift` | 设置页「客户端」切换条：原生 `NSSegmentedControl` 包装（段宽按文字测量写死，客户端变多时整体变宽并横向滚动，不压成省略号） |
| `Sources/LLM-monitor/Views/SettingsComponents.swift` | 设置窗口共享组件与统一字体角色（`SettingsTypography` / `SettingsSection` / `SettingsControlRow` / `SettingsPaneHeader`） |
| `Sources/LLM-monitor/Views/SettingsFields.swift` | 设置页通用表单输入组件与数值/路径辅助函数（`intervalSliderField`、`secretField`、`apiKeyField`、`selectAuthFile`、`tildePath`） |
| `Sources/LLM-monitor/Views/SettingsGeneralPane.swift` | 设置页常规 pane：全局刷新、状态栏主题与健康色、边缘状态窗、Provider 顺序、Bark 推送与节假日源 |
| `Sources/LLM-monitor/Views/SettingsProviderPanes.swift` | 设置页各 Provider 设置 pane（MiniMax / ChatGPT 支持多 API Key 卡片列表 `CodexAdminKeyCardView`、添加/删除/编辑 / Antigravity / GLM / DeepSeek）与四类额度通知配置 |
| `Sources/LLM-monitor/Views/SettingsSaveTransaction.swift` | 设置保存事务：login item 更新 + config 保存的失败回滚语义；`SettingsLoginItemDraft` 区分系统实际状态与未保存编辑，保护菜单切换不被旧草稿覆盖 |
| `Tests/LLMMonitorTests/SettingsLoginItemDraftTests.swift` | 菜单/设置开机自启状态同步、重复状态刷新保留本地编辑、未修改草稿服从系统实际值 |
| `Sources/LLM-monitor/Views/SettingsView.swift` | 设置面板主框架：侧边栏、Tab 路由、表单草稿状态与保存事务入口；持有联动草稿 controller，跨 tab 保留未保存状态并在底栏提示 |
| `Sources/LLM-monitor/Views/SettingsFormDraft.swift` | 设置页表单草稿与统一 Equatable 脏检查（含 `CodexAdminKeyConfigDraft` 多 Key 草稿列表及脏检查） |
| `Tests/LLMMonitorTests/SettingsFormDraftTests.swift` | 设置页表单草稿等价性比较、Equatable 脏检查与重置单测 |
| `scripts/build-app.sh` | Release arm64 `.app` bundle build（dSYM 导出 + strip）和 ad-hoc signing |
| `scripts/build-release.sh` | 发行编排入口：依次 build-app.sh → build-dmg.sh 并产出 SHA-256 校验和，签名 / notarization 变量透传 |
| `scripts/test-build-config.sh` | `build-app.sh` 构建期常量的 shell 冒烟测试（BUNDLE_ID 等「格式对但值被改」的回归护栏，自带框架） |
| `scripts/build-dmg.sh` | DMG packaging from the built `.app` |
| `scripts/test.sh` | 运行 `swift test`；仅显式设置 `INCREMENT_BUILD_NUMBER=1` 时递增 build 编号 |
| `scripts/audit.sh` | Shell syntax、Package、Swift 测试、Python 分析/发布脚本回归、Release 和 Swift 6 门禁（Python 优先 .venv，否则 python3；仅标准库） |
| `scripts/archive-source.sh` | 从 Git HEAD 生成源码归档 |
| `scripts/export-antigravity-quota.sh` | 导出 Antigravity 本地 quota 数据 |
| `scripts/generate-icns.sh` | 从源图生成 AppIcon.icns（由 sync-icon-assets.sh 调用，也可独立使用） |
| `scripts/sync-icon-assets.sh` | 图标资产唯一同步入口：IconPreview 副本 + 回退 icns 重生成 + sidecar 新鲜度记录；`--check` 供构建前置校验 |
| `scripts/sync-holiday-data.sh` | 法定节假日快照唯一同步入口：拉取上游 chinese-days JSON，抽取 `holidays` ∪ `inLieuDays`（workdays 有意丢弃，Rule A）生成 ChinaHolidays.json，幂等 + `--check` 只读校验 |
| `Tests/LLMMonitorTests/DataSourceRegressionTests.swift` | OpenCode/MiniMax 分拆守恒、Agy 耗时排除与数据库变更、数值极值、DSH 流式输出上限回归 |
| `Tests/LLMMonitorTests/CrossReviewDataTests.swift` | 计量交叉复核：同窗守恒、原生/配对/残余分配、DB 删除、数值边界及子进程 EOF 超时/取消 |
| `Tests/LLMMonitorTests/CrossReviewRuntimeTests.swift` | 运行时交叉复核：停止/重启、排队配置、取消后成功、扫描代际原子应用与不完整结果发布顺序 |
| `Tests/LLMMonitorTests/CrossReviewUITests.swift` | UI 交叉复核：节假日缓存恢复、设置目标重入、来源等价失效与悬停目标替换 |
| `Tests/LLMMonitorTests/RuntimeLifecycleRegressionTests.swift` | 配置重建、启动收敛、取消恢复、Fleet 首扫保护与 Bark 队列冷却回归 |
| `Tests/LLMMonitorTests/HolidaySourceLifecycleTests.swift` | 节假日草稿/已保存源隔离、旧请求拒收与新请求刷新状态回归 |
| `Tests/LLMMonitorTests/SettingsNavigationTests.swift` | 实际消费设置页发布目标并清理导航请求 |
| `Tests/LLMMonitorTests/EdgeDockSelectionTests.swift` | Dock 稳定 Provider 身份、重排与停用清理回归 |
| `scripts/tests/test_analysis_tools.py` | 合成日志/SQLite 测试分析脚本的累计去重、时间边界、空与零成本；不读取用户数据 |
| `scripts/tests/test_release_script.py` | 临时干净仓库与桩构建器验证发布入口的构建号优先级及不写回约束 |
| `scripts/dsh_token_analysis/summary.py` | DSH 离线 RATE_LIMIT 与窗口汇总；全部 call 区间累计、retryId 去重 |
| `scripts/dsh_token_analysis/analyze.py` | DSH 离线明细分析；触发时刻窗口/日累计按 call 时间统计 |
| `scripts/dsh_token_analysis/cost.py` | DSH 离线窗口成本与分组统计；空组/零成本可输出 |
| `scripts/dsh_token_analysis/minimax_cost.py` | MiniMax 本地 SQLite 离线窗口成本分析；空库/零成本可输出 |

## Test Suite

- 规模：`Tests/LLMMonitorTests/` 按主题一文件组织。Fleet Sync 覆盖协议/合并、存储、报告构建、UI 投影、HTTP 集成、scope 控件、设置页与 LAN 地址解析；用例数随工作区改动变化，不在职责地图中固定记录。
- **串行执行是既定选择**：`swift test --parallel` 实测（2026-10-02，5 连跑 3 败）不可用——`SQLiteTempCopyTests` 的临时副本断言扫描跨进程共享目录，并行 worker 互相误判；且慢测试为睡眠型，并行的 wall 收益仅 ~4s。并行化前提：先给 SQLiteTempCopy 的副本目录引入进程级隔离，再复评。
- 慢用例的等待注入缝已建立：调度器（now/sleep）、Bark 退避（retryDelay）、vnode 合并窗口（coalescingWindow 参数）；新增耗时敏感测试时优先走注入缝，不要写死真实 sleep。

> 核对基线：2026-11-10 · 代码 91f6cd4
