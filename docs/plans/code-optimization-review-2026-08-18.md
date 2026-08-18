# 代码优化审查报告（2026-08-18）

审查对象：`main` @ 4edc8f4 · 源码 92 文件 / 23,679 行 · 测试 24 文件 / 12,578 行
关注点：代码规模（减文件、减行数）、效能、代码层级与调用关系。

---

## 〇、实施结果（2026-08-18 当日落地，7 个 commit，375→376→374 测试全绿）

源码 92 → 98 文件 / 23,679 → 22,976 行（**-703 行 / -3.0%**）；测试 +84 行（新增
Minimax 严格计数校验回归测试）。行数降幅低于原估的 -1,900，主要因为：阶段 1 的
watcher 重挂载/退避是新增防御代码（+137）；阶段 2/3 为保住全部既有测试表面保留了
per-scanner 静态函数（原估算假设删掉）；新组件（编排层/基座）按仓库惯例带完整文档
注释。架构目标基本达成，明细见下。

### 各阶段落地明细

**阶段 1（13206a0）**：全部 8 项落地。watcher 改监听 config.json 单文件（原子替换
重挂载 + 2s 退避重试）；Minimax 双重解析删除（严格计数校验并入 Decodable，具体
错误信息透传）；Codex usage/reset-credits `async let` 并行；hover 图定价 `@autoclosure`
惰性化；`ProviderCardView` Equatable + `.equatable()`；MenuBarLabel 改"渲染签名变化
才重合成 NSImage + bump revision"（含外观/刷新态入签名）；index.json 去
`.prettyPrinted`；ProviderConfig 手写 encode 删除、`hasLocalAuth` 协议默认实现；
Minimax per-day/字符聚合 SQL 加 cutoff（对齐 GLM 口径）。

**阶段 2（081e885）**：两层基座替代单基座方案——`LocalUsageScannerBase<Usage>`
（生命周期外壳：@Published 状态 / scan dedup / generation 守门 / runner 接线 /
LocalUsageScanner conformance，5 个扫描器全部迁移）+ `SingleDBSnapshotScanner<Usage>`
（db+WAL 指纹 / 泛型 SnapshotCacheIndex / 命中即 rebase / 变更才写盘；Glm+Opencode
全量迁移，418→229 / 354→153）。on-disk JSON 字段不变，旧缓存零迁移。Codex 扫描器
归位 Services/。SQLiteConnection 收编 nnClamp / SQLITE_TRANSIENT /
bindNullableMsCutoff；Glm/Opencode reader 统一严格版 LocalUsageDayKey.parse。
**偏差**：Minimax/Antigravity 的 performScanPure 静态测试表面保留（原估算的 -750
含删除它们，需重写大量测试，暂缓）。

**阶段 3（59b7b13）**：5 个同构 daily 结构收口为 `LocalDailyTokenUsage` + 5 个
typealias（JSON 键一致 → 缓存零迁移，`+`/withDayStart/hasActivity/adapter 样板
×5 → ×1）；Antigravity/Minimax 容器合并为 `ProviderLocalUsage`；`PeakWindow`
参数化合并（Glm=单槽本地时区，DeepSeek=双槽北京时间，调用点显式传 calendar）；
ModelPricingCatalog 拆独立文件（~270 行）；usageProjection 五分支 switch 改
contribution 工厂注册表（新增 provider = 表里加一行）。**暂缓**：codex
JSONSerialization→AnyJSON（4 处解析路径稳定且有测试，纯风格迁移收益低）；
opencode/dsh 容器归一（byProvider 形态差异大）。

**阶段 4（e692aaf）**：`ProviderRefreshScheduler.runRefresh` 收编 in-flight
mark/release + 成败记录（handler 返回即自动结算，回调环消灭）；`ManualRefreshGate`
拆出 pending/waiter/claim 协议；watcher 归还 ConfigStore（startWatching/
stopWatching）；`LocalUsageOrchestration` 拆出 5 组 coordinator + 启动策略 + GLM
定期任务 + postRefreshTriggers 触发表（刷新成功后的 per-kind if 链删除）；
目录归位 5 个文件（Color+Theme→Views、QuotaError→Services、FetcherDescriptor→
Fetchers、两个 UsageMerger→Services）；sessionFileURLs 移回 Dsh 扫描器；
rebuild 双重派生消除 + shouldAutoRefresh 复用 auth 结论（主线程少构造 fetcher）。
AppState 1365 → 1133。**暂缓**：codex detail task 块（~120 行）再拆一个
coordinator。

**阶段 5（776e894）**：Antigravity/ChatGPT 账户 hover 合并为参数化 AccountHoverView；
两个纯转发 ChatGPT quota 行 wrapper 删除；SettingsView 1206 → 849 +
SettingsClientsPane 284 + SettingsSaveTransaction 83；KVC 私有 API
（NSStatusBar "items"）备用分支删除（上架审核风险消除）。**暂缓（附理由）**：
ProviderFormSpec 通用 pane 引擎（GLM/Deepseek 高峰段异构，DSL 收益 < 改造churn，
19 个 @State 维持现状）；PeakIndicator 合并（已共用 PeakIndicatorView 外壳，
剩余差异是真实文案/样式）；AutoCloseBridge 改 ContinuousClock（现有 scheduler
DI 是刻意可测试设计，122 行测试依赖它）；显示差异收进 FetcherDescriptor
（weeklyEquivalentMultiplier 依赖 model 而非 kind，收口不干净）。

**阶段 6（本轮回归后追加）**：Dsh 增加有界进程内 per-file 解析 LRU；任一 session 变化时
只重新读取/解压该文件，未变化文件复用解析结果，index.json 字段与版本保持不变。
Antigravity dirty session RPC 改为最多 4 路有界并发，并保持聚合顺序；Codex 最新 session
文件选择由逐个插入排序改为一次排序截断。ConfigStore watcher 重试改为指数退避
（1/2/4/8/16/30 秒）并抑制重复 warning。新增 Dsh 单文件增量回归测试，测试数 375→376。

**阶段 7（测试整体重构）**：审查所有测试后保留语义不同的边界场景；将 Dsh 三个仅 provider
别名不同、断言结构相同的 merger 测试合并为一个 table-driven 测试，三组输入仍逐组执行。
同时移除无效的临时 fixture 变量和多余 `try`，让测试编译零 warning。测试总数从 376
降为 374，但保留的断言场景不变。

### 遗留建议（后续可选）
1. 阶段 6 后续：Dsh zstd 解压改流式/分块读取（降低压缩文件峰值内存）、
   GlmZcode readOffPeakWindows 纳入指纹，并以真实设备数据评估 SQLiteTempCopy 的
   渐进 backup 接口。
2. Minimax/Antigravity performScanPure 迁到实例方法并入基座（需重写其静态测试
   表面，预计再 -200 行）。
3. codex detail task 提取为独立 coordinator（AppState 再 -120 行）。
4. codex JSON 解析风格迁移 AnyJSON（纯风格统一）。

---

## 一、问题清单

### A. 架构级问题

**A1. AppState 是 god object（Services/AppState.swift，1365 行）**
- 5 个 `@Published`、约 50 个方法、约 26 个存储属性、直接依赖约 32 个类型，承担 14 类职责：状态派生、刷新编排、手动/后台刷新合并协议（`pendingFullRefreshIDs` 两套计数字典）、配置 watcher（DispatchSource + debounce）、配置代数守门、健康度时钟、通知、5 组 scanner 编排、Codex 明细任务、auth 探测、last-refresh 持久化、NSWorkspace UI 动作等。
- 注释声称 merger policy "不在 AppState 里堆 if 分支"（AppState.swift:675），但 :723-758 仍是 5 分支的 per-kind 副作用链。**每新增一个 provider 至少要改 AppState 3 处**（trigger、apply、rebuild 保留字段），违背 spec 的 "small provider surface" 设计目标。

**A2. 目录分层漂移（Fetchers/Services/Models 职责混乱）**
- `Fetchers/CodexLocalUsageScanner.swift`（958 行）是本地扫描器，其余 5 个扫描器全在 `Services/`；且它游离在 `LocalUsageScanner` 协议之外（无 scan/cancel 生命周期、无 coordinator、缓存是 `static let shared` 单例 actor）。
- `Services/Color+Theme.swift` import SwiftUI，纯 UI 代码放在 Services。
- `Fetchers/QuotaError.swift` 被 `Services/HTTPClient.swift` 反向依赖（跨层类型放错边）。
- `Models/` 正在吸收逻辑文件：`DshUsageMerger`、`OpencodeUsageMerger`（聚合逻辑）、`ModelPricingCatalog`（ProviderClientModel.swift:339-611，~270 行定价子系统）、`usageProjection` 145 行五分支 switch（:816-960）。
- `FileManagerBox.sessionFileURLs`（:57-68）是 dsh 领域专用逻辑，塞在通用文件工具里。

**A3. "每个 provider 复制一套"是系统性模式（最大体量问题）**
- 5 个 `@MainActor` 扫描器（Dsh/Antigravity/Minimax/GlmZcode/Opencode）是同一模板手工复制 5 遍：生命周期外壳（scan/cancelInFlight/runScan + generation 守门，约 330 行）、`lastCommittedGeneration` + DEBUG hook（约 120 行 ×2）、DB+WAL 指纹 stat（约 140 行、5 种互不兼容的指纹结构）、CacheIndex/load/save/loadCachedResult（约 250 行）、7 天窗口 rebase + `-8*24*60*60` 魔数 ×10 处（约 150 行）。合计 **约 1,020 行高度重复**，占扫描器主体 23%。
- 6 种同构 daily 模型（Antigravity/Minimax/Glm/Opencode/Dsh/Codex 的 DailyTokenUsage）字段完全同构，共约 500 行、其中 ~380 行逐字样板；5 份逐字相同的自定义 `==`（排除 scannedAt）；统一模型 `UnifiedDailyTokenUsage` 其实已存在且 UI 边界已全部转换，归一化只差最后一公里。
- `GlmPeakWindow` 与 `DeepseekPeakWindow` 是同一逻辑的平行实现（~80% 相同）。
- provider 元信息三处冗余注册（fetcher 属性、FetcherDescriptor、ProviderStatus）。
- 5 个 Fetcher 中 "API-key GET" 骨架（guard key → URLRequest → Authorization → send → parse）重复 3 份（Minimax/Glm/Deepseek，~70 行逐字重复）；`hasLocalAuth()` 恒 true + 相同注释复制 3 份，本应是协议默认实现。

**A4. 三套 JSON 解析风格并存**
- 纯 JSONDecoder（Glm/Deepseek/Antigravity）、纯 JSONSerialization + Any 强转（Codex ×4 处）、两者叠加（Minimax：同一份 response 先 JSONSerialization 校验再 JSONDecoder 完整重解码一遍）。
- "NSNumber 非负整数校验" 有 3 套实现（MinimaxTokenPlanFetcher.swift:263-278、CodexFetcher.swift:479-485、CodexLocalUsageScanner.swift:932）。AnyJSON 本身质量好，但生产代码只有 Antigravity 一个消费者——双轨未收敛。

**A5. Scheduler 与 AppState 的回调环**
- `refreshProviderDirectly` 被 scheduler 调用，内部反过来调 scheduler 的 `markInFlight/markNotInFlight/recordSuccess/recordFailure`（AppState.swift:611-785）。in-flight dedup 状态在 scheduler，acquire/release 却由 AppState 驱动；`waitUntilNotInFlight + pendingFullRefresh` 协议（3 dict + 2 方法）横跨两类。ProviderRefreshScheduler 的 continuation 队列与 AsyncMutex 是两套手写的同语义实现。
- ConfigStore 文档自称负责"文件变化监听"，实际 DispatchSource watcher 在 AppState（:437-464），watcher 归属错位。

**A6. Views 层无 ViewModel 拆分，观察粒度过粗**
- `MenuContentView`、`SettingsView` 均 `@ObservedObject` 整个 AppState：任一 provider 的任一状态变化（含每次扫描的 scanning 开关）触发整个菜单面板/设置页 body 重算。`mutateStatus` 双通道广播（数组赋值 + `statusDidChange.send()`）放大频率。
- `MenuBarLabel` 每次通知无条件 `statusRevision &+= 1` 改 `.id()` 整体重建 label + 重新合成 NSImage（MenuBarLabel.swift:19-24, 48-74）。
- `SettingsView` 实际只用 `state.statuses` 一个字段；`ProviderCardView` 拿的是值类型 `ProviderStatus`（Equatable），却没加 `.equatable()`，未变化的卡片照样重算。

### B. 性能问题（按影响排序）

**P1.【最严重】日志写入自触发配置 watcher**：watcher 监听配置目录 `.write` 事件（AppState.swift:440-450），但 `log.txt`（AppLog）与 `last-refresh.json` 同目录。每条日志 append、每次 last-refresh 落盘都会触发一轮 debounce → detached 读整个 config.json → Data 指纹比对。一次刷新周期产生 5-10 行日志 = 自造 5-10 轮 watcher 抖动。
**P2. Dsh 无增量缓存**：整目录指纹全有/全无（DshLocalUsageScanner.swift:212-231），任一 session 文件追加一行 → 重新读取+解压+解析全部选中文件（上限 1024 个/256MB）。Codex 已有 per-file 缓存方案可移植。附带：zstd 走外部进程 + 临时文件（:959-1034，内存峰值 3×）、整文件 `Data(contentsOf:)` 载入（无分块）。
**P3. Minimax 双重 JSON 解析**：`parse` 先 JSONSerialization 全量解析（:229）再 JSONDecoder 全量重解码（:91）。
**P4. Minimax dirty 时全历史聚合**：`perDaySQL` 无时间下界（MinimaxDBReader.swift:158-172），每次 dirty 全表 GROUP BY + 约 8 条全表查询；GlmZcode 同类查询反而传了 cutoff，口径不一致。
**P5. Codex 两个独立 GET 串行 await**（usage → reset-credits，CodexFetcher.swift:103-126），可用 `async let` 并行，每次 full 刷新省一个 RTT（AntigravityFetcher.swift:58-79 已示范正确做法）。
**P6. 卡片 body 内每次白算价格**：`priceByDay`/`todayCostText`（LocalUsageHoverViews.swift:378-405）在 footer 每次 body 求值时对全部 recentSamples 跑定价估算——即使 hover 图从未打开。
**P7. 每张卡 O(模型数 × 样本数 × 4) 线性扫描**：QuotaViews.swift 的 `primaryUsage/secondaryUsage/lastPrompt/todayOffPeakUsage/weeklyUsage` 全是 computed property 连缓存都没有（:77-101, 373-407），每次经过含字符串 contains 的 `matchingSamples` 过滤。
**P8. 主线程三重冗余**：一次 config 变更 → rebuild 流程中同一 provider 在 MainActor 上构造 3 次 fetcher + 3 次 auth 文件 stat（deriveProviderState :1312-1317、shouldAutoRefresh :824-832、AuthProber 接线 :222-228）；`deriveProviderState` 非 ready 路径每 provider 派生 2 遍（:514 vs :537→deriveState→:1274）。
**P9. index.json `.prettyPrinted`**（ScannerIndexIO.swift:53）：含数万条 recentSamples 的缓存每轮多写数 MB 磁盘 + 编码 CPU。
**P10. 菜单打开时 5 个 1 秒 TimelineView tick**（ProviderCardView.swift:363，实际阈值 3 秒）；Antigravity dirty session 串行 RPC（AntigravityLocalUsageScanner.swift:542-557）可改有界并发；Codex 最新文件选择 O(n²) 插入排序（CodexLocalUsageScanner.swift:786-817）；SQLiteTempCopy 对大 WAL 整份拷贝可评估 `sqlite3_backup` 渐进接口。
正面确认：5 个类扫描器各自独立 mutex，跨扫描器本就并行；`refreshAll` 用 TaskGroup 按 provider 并行；响应有 8/64 MiB 上限；LastRefreshStore 已把 fsync 移出 MainActor；AppLog 复用 FileHandle。

### C. 模块级小问题（择要）

- ConfigStore.swift:315-342 手写 `ProviderConfig` Codable 与编译器合成行为逐字段等价，纯冗余 28 行；模板供给双轨（templateProviders vs ensureProvidersPresent）靠 CI 测试锁一致；watcher API 双份（reload/hasChanged 两套签名）。
- Codex 持有两个 HTTPClient 实例仅 logTag 不同；Antigravity 绕开 HTTPClient 重造 ~70 行网络管线（capped download/错误映射/2xx 检查，AntigravityFetcher.swift:443-518 vs HTTPClient.swift:229-265），其中只有 trust delegate + CSRF 是真差异。
- GlmZcode `readOffPeakWindows` 直接用 `FileManager.default` 绕开注入的 FileManagerBox（GlmZcodeLocalUsageScanner.swift:224），破坏可测试性一致性。
- `MenuBarRightClickHandler.swift:71` 用私有 KVC `NSStatusBar.system.value(forKey: "items")`（上架审核风险）；:63 类名字符串嗅探 StatusBarWindow 易碎。
- FileManagerBox 注释里的"调用方白名单"（:24-30）已失实（实际 8 个文件在用）；包装本身半过度抽象（FileManager.default 本就线程安全），真正有价值的只有 `writePrivate`。
- 3 个 DB reader 各有一份逐字相同的 `parseDayKey`/`nnClamp`/`sqliteTransientDestructor`（~120 行可下沉到 SQLiteConnection；且 GlmZcode/Opencode 用宽松 parseDayKey、Minimax 用严格版，已是隐性口径不一致）。
- QuotaInfo.swift 混入 Codex 专属 ~200 行 + DeepSeek 专属 ~20 行，"每加 provider 往通用结构塞一个 optional" 的模式已成型（resetCredits/codexUsageDetails/balanceDetail）。

---

## 二、改进计划

原则：每阶段独立可交付、`swift test` 全绿后合并；改动 on-disk 缓存格式（index.json）时必须递增版本号；小步提交，每步可回滚。

### 阶段 1：低风险速赢（性能修复 + 纯删除，~1-2 天）
| # | 动作 | 类型 | 预期 |
|---|---|---|---|
| 1.1 | 修 watcher 自触发：改监听 config.json 单文件（或把 log/last-refresh 移出监听路径） | 性能 P1 | 消除每轮刷新 5-10 次 watcher 抖动 |
| 1.2 | Minimax 删除 JSONSerialization 预校验路径，校验并入 Decodable | 性能 P3 | 每次刷新少一遍全量解析 |
| 1.3 | Codex fetch 内 usage/reset-credits 改 `async let` | 性能 P5 | 每次 full 刷新省 1 RTT |
| 1.4 | LocalUsageHoverViews 价格计算惰性化（onHover/缓存） | 性能 P6 | 卡片 body 不再白算价格 |
| 1.5 | ProviderCardView 套 `.equatable()`；MenuBarLabel 仅 health 变化才 bump revision + NSImage 结果缓存 | 性能 | 砍掉最大重算面 |
| 1.6 | ScannerIndexIO 去掉 `.prettyPrinted` | 性能 P9 | 磁盘/CPU 双降 |
| 1.7 | 删 ProviderConfig 手写 Codable（28 行）；`hasLocalAuth` 恒 true 收为协议默认实现（3 处） | 规模 | -40 行 |
| 1.8 | Minimax perDaySQL 加 cutoff 对齐 GlmZcode | 性能 P4 | 消除全表聚合 |

### 阶段 2：扫描器基座（最大单笔规模收益，~3-5 天）
- 新建 `SQLiteSnapshotScanner<Usage>` 泛型基座（~250-300 行），收入：生命周期外壳（scan/cancel/runScan/generation）、统一 `DBFileFingerprint`、泛型 `SnapshotCacheIndex<Usage>`、7 天窗口 rebase、aggregateFromDB 快路径模板、可选 lastCommittedGeneration + test hook。
- 子类只声明 logTag、路径、`aggregate()`、`rebase()`。GlmZcode（418 行）与 Opencode（354 行）结构相似度 ~90%，套基座后合并为一个文件。
- `CodexLocalUsageScanner.swift` 移入 `Services/`，`enumerateUTF8Lines` 泛化为共享 JSONL 读取器供 Dsh 复用（Dsh 顺带获得尾部窗口优化）。
- 三个 DB reader 的 5 个小工具（parseDayKey/nnClamp/destructor/cutoff 绑定/sample 构造）下沉 SQLiteConnection，统一到严格版 parseDayKey。
- **预期：约 -750 行，文件 -2；为阶段 4 的 Dsh per-file 增量缓存铺路。**

### 阶段 3：模型归一（~3-4 天）
- 扫描器直接产出 `UnifiedDailyTokenUsage`（或泛型 `LocalUsageSnapshot<Daily>`），删除 5 个 per-provider daily 结构 + 5 份相同 `==` + withDayStart 拷贝；单源容器（Antigravity/Minimax/Glm）合并为一个 `ProviderLocalUsage`（Glm 的 offPeakWindows 作 optional 附加），byProvider 容器（Opencode/Dsh）合并为一个 `MultiProviderLocalUsage`。
- `GlmPeakWindow`/`DeepseekPeakWindow` 合并为参数化 `PeakWindow`（slots + calendar）。
- NSNumber 校验收敛为 AnyJSON 单一实现；Codex 4 处 JSONSerialization 路径评估迁移 AnyJSON。
- `ModelPricingCatalog` 拆出独立 Pricing 文件；`usageProjection` 145 行 switch 改配置表驱动。
- 风险点：on-disk index.json 的 Codable 兼容 → 全部递增版本号，冷启动重建即可（已有该机制）。
- **预期：约 -450 行，文件 -4~6。**

### 阶段 4：AppState 瘦身 + 分层归位（~4-5 天）
- 从 AppState 拆出：① `ConfigWatcher`（DispatchSource + debounce + 代数，watcher 归还给 ConfigStore 一侧）；② `ManualRefreshGate`（pendingFullRefresh/waiter 协议）；③ `LocalUsageOrchestration`（5 组 coordinator trigger/apply + kind 分支，配置表驱动消灭 per-kind if 链）。目标 AppState 1365 → <600 行，职责只剩"状态容器 + 刷新入口 + 派生"。
- in-flight mark/record 从 AppState handler 内部移进 ProviderRefreshScheduler 自身（handler 返回即自动结算），消灭回调环；其 continuation 队列评估复用 AsyncMutex。
- 目录归位：CodexLocalUsageScanner → Services（阶段 2 已做）、Color+Theme → Views、QuotaError → Services（或新建 Core/）、FetcherDescriptor → Fetchers、UsageMerger ×2 → Services；FileManagerBox 的 dsh 专用 `sessionFileURLs` 移回 Dsh 扫描器。
- 顺带：makeFetcher/auth stat 三重调用收敛为一次构造传入；rebuild 双重派生消除。
- **预期：AppState -700 行，调用关系单向化，"新增 provider 只改 descriptor + fetcher + scanner spec" 达成 spec 目标。**

### 阶段 5：Views 配置驱动（~2-3 天）
- `ProviderFormSpec` + 通用 `ProviderSettingsPane` 替代 5 份手写 pane + 19 个 @State + load/save 五读五写（-110~150 行）；`SettingsSaveTransaction` 与 clientsPane 拆出独立文件（SettingsView 1206 → ~850）。
- 账户 hover 三胞胎合并（Antigravity/ChatGPT/Deepseek → 参数化单 view，-78 行）；Glm/Deepseek PeakIndicator 合并（-35 行）；QuotaViews 内 ChatGPTPlanModelRow 与 CombinedQuotaWindowRow 平行实现合并（-55 行）；两个纯转发 wrapper 删除（-40 行）。
- provider 显示差异（weeklyEquivalentMultiplier/emptyUsageHint/accentColor/header hover 类型）收进 FetcherDescriptor。
- MenuWindowAutoCloseBridge 的三层 DI 协议简化为 ContinuousClock 注入（257 → ~150 行）；MenuBarRightClickHandler 砍掉 KVC 备用分支。
- **预期：约 -360 行，文件 -3；provider UI 差异单点收口。**

### 阶段 6（可选，性能二期）
- Dsh per-file 增量缓存（移植 Codex 双层 LRU 方案）——P2 的根治。
- Antigravity dirty session 有界并发 RPC；Codex 最新文件选择 O(n²) → 一次 sort。
- GlmZcode readOffPeakWindows 纳入指纹缓存。

### 总账
| 阶段 | 行数变化 | 文件变化 |
|---|---|---|
| 1 速赢 | -50 | 0 |
| 2 扫描器基座 | -750 | -2 |
| 3 模型归一 | -450 | -5 |
| 4 AppState/分层 | -300（AppState 内 -700，新增拆分件 +400） | -1~+2 |
| 5 Views | -360 | -3 |
| **合计** | **约 -1,900（-8%）** | **92 → ~80** |

---

## 三、整体评价

**结论：这是一个工程质量在业余/个人项目里属于上游水平、但正站在"第二遍复制"拐点上的代码库。**

亮点（应保持）：
1. **测试文化扎实**：12,578 行测试，performScanPure 纯函数化 + 时间/文件系统全注入，重构安全网在全个人项目里罕见地好。
2. **底层抽象正确**：SQLiteConnection / SQLiteTempCopy / ScannerIndexIO / AsyncMutex / LocalUsageScanRunner / HTTPClient(CappedDownloader) 都是恰当的共享层，没有过度设计。
3. **规格文档与代码同步**：spec/ + docs/policy/ 的存在让每个 workaround 有据可查。
4. **安全卫生好**：0600/0700 权限、响应上限、脱敏日志、损坏配置备份、instance lock。

核心问题只有一个模式的三种表现：**"新增 provider = 复制一遍"的扩展方式**（扫描器 ×5、daily 模型 ×6、设置 pane ×5、AppState 分支 ×5）。它在 5 个 provider 时成本约 2,000+ 行重复，在第 6 个 provider 时会变成 2,500 行——而统一路径（UnifiedDailyTokenUsage、LocalUsageScanner 协议、FetcherDescriptor）其实都已建好 90%，只差最后一公里收口。

建议节奏：先做阶段 1 的速赢建立信心（ watcher 修复用户可感知），随后按 2→3→4→5 顺序推进；阶段 2+3 完成后再评估是否接受新 provider 需求——届时新增一个 provider 的成本应从"改 8 个文件 + 复制 300 行"降到"1 个 fetcher + 1 个 scanner spec + 1 行注册"。
