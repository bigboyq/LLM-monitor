# Changelog

本文件记录面向用户的版本变化；审计、重构和测试补强只在影响使用行为时摘要记录。

## [Unreleased]

### Added

- 新增 Bark 推送通知：在「设置 > 常规 > Bark 推送」配置服务端地址（默认官方 `api.day.app`，支持自建）、Device Key 与铃声，可发送测试推送；提供「非锁屏时跳过推送」开关。
- 额度通知细分为四类事件（5 小时额度恢复 / 耗尽、周额度恢复 / 耗尽）。有 5 小时 + 周额度窗口的 Provider（ChatGPT、GLM）在各自设置页可独立配置每类事件的通知渠道：不通知、系统通知、Bark + 系统通知；默认恢复 → 系统通知、耗尽 → 不通知，与既有行为一致。其它 Provider 暂不接入 Bark。

## [1.6.0] - 2026-09-09

### Added

- 状态栏图标升级为全参数化动态 SVG 仪表盘（`QuotaLogoSVGBuilder`）：
  - 外圈（周额度）与中圈（5h 额度）采用双环展示，按物理真实剩余百分比动态展开；
  - 顺时针 $\to$ 逆时针重构：自 12 点钟起点逆时针环绕，$0 \to \min$ 实线段稳定承托左半环，$\min \to \text{avg}$ 虚线段沿底部延伸至右下，$\text{avg} \to 100\%$ 留白位于右侧；
  - 虚线步进标定为「2-4-2」刻度模式（`stroke-dasharray="32 64"`）：在 Retina 屏幕上呈现清晰通透的 2 物理像素实线 + 4 物理像素留白，呼吸感大幅提升；
  - 中心水杯水位映射 5h 最低剩余可用量，中心颜色引入严格的三级优先级判定体系（红 > 黄 > 绿），并具备高峰价格时段（GLM / DeepSeek）自动预警感知。

### Changed

- 优化状态栏渲染性能与缓存管道：`MenuBarLabel` 引入 7 维全要素可见输入签名 `RenderSignature`，仅在可见数据实质变更时重绘；接入分钟时钟监听，在高峰时段切换点无缝更新而无额外刷新开销。
- 扩大动态 SVG 画布范围至 `viewBox="160 160 704 704"`，彻底消除右下角与外圈描边裁切风险。

### Removed

- 彻底清理 `Sources/LLM-monitor/Resources/StatusBarIcons/` 目录下的 4 个旧版静态切图 SVG 文件及 `Package.swift` 资源绑定，状态栏 App 图标改为纯内存矢量渲染，零磁盘 I/O 依赖。

## [1.5.0] - 2026-09-08

### Added

- 新增 DeepSeek Harness (dsh) 客户端用量监控：扫描 `~/.dsh/sessions` 中的 JSONL session 日志（zstd / Node 22+ zlib 双解压路径），按 `request/context` 中的 provider 自动合并到 MiniMax / GLM / DeepSeek 三张卡片。
- 新增"设置 > 客户端"tab：按客户端维度（Antigravity / Codex / DSH / MiniMax Code / OpenCode / ZCode）展示本地 token 用量、最近 7 天柱图、缓存命中率与按公开 API 单价估算的价值。
- 新增 `ModelPricingCatalog`：模型价目快照（MiniMax-M3 直接使用公开 CNY 价格、DeepSeek 高峰期 2× 倍率、DSH 独立 uncached-input / cache-read bucket 计价、新增 GLM-5.3-Flash 定价规则）；客户端 tab 标注目录更新日期 `lastUpdated`。
- Antigravity 新增 Gemini 3.8 Flash 定价：官方价与 3.7 Flash 完全相同（Input $0.75 / Cached Input $0.075 / Output $3.75，introductory 价至 2026-12-31）。
- Antigravity 新增 Gemini 3.1 Pro 定价：Input $2 / Cache read $0.2 / Output $12（USD）。按标准档（≤200K 上下文）建模，>200K 的长上下文档不参与计价口径。
- 客户端 tab 中未定价模型显式列出名称、token 数与调用次数，不再静默归零。
- 主菜单 Provider 卡片可自定义顺序：设置 → 通用 → 主菜单 Provider 顺序段提供上下按钮拖拽，按 Provider 显示名称排序。客户端 tab、设置页 Provider tabs 与 Client tab 内的 Provider 行仍按显示名称字母顺序排列；`providerCardOrder` 仅作用于主菜单。

### Changed

- 调度架构重构为「双循环」模型：
  - 循环 A（额度循环）：单一 Task 管理全部 Provider 的 Quota 抓取，睡眠至最早截止时间，到期批次通过 `TaskGroup` 并发调度并保持严格的条目级隔离；保留启动首拍 full、每 20 次 background 补 full、指数退避、1s 短重试早醒、mid-cycle reset+15s 补刷新及手动刷新合并等既有语义。
  - 循环 B（用量循环）：单一 Task 按全局刷新间隔迭代全部 6 个客户端（Codex、Antigravity、ZCode/GLM、OpenCode、DSH、MiniMax Code），就绪探测短路并增加状态跃迁去噪日志；Codex usage-details 读取并入本循环。
  - 彻底剥离 Quota 成功对本地用量扫描的触发依赖（删除 `postRefreshTriggers` 表与成功回调），移除 GLM 专属定时任务（由循环 B 全面覆盖）。手动 `refreshAll` 与系统唤醒同时触发双循环立即执行一拍。
  - Codex 本地明细与额度数据解耦：quota 首胜前扫描照常进行（产出 7day/today 与 Last Prompt，窗口用量 `primary`/`secondary` 为 nil，UI 悬浮窗条件渲染）；窗口定义从数据层存量 reset 时间读取，quota 刷新后下一拍自动对齐；`applyCodexUsageDetails` 移除 `fetchedAt` 严格匹配门槛，本地数据写入独立触发 UI 刷新。
  - Codex 扫描性能优化：行过滤下沉到字节层（memmem 预过滤替代逐行 `String.contains`，冷扫描约 12× 提速）、读取分块 64KB→1MB、`refreshAll` 触发去重（不再与被唤醒的循环 B 并发双扫），并引入程序生命周期内的 append-only 增量解析——会话文件增长时只解析新增尾部（每拍从秒级降到毫秒级），截断/替换按文件整体重扫自愈，App 重启即冷全扫；不写入任何磁盘索引。
  - DSH 扫描同步优化：`consumeLine` 增加字节级 marker 预过滤（只有 `request/context` / `assistant/message` 行进入 JSONDecoder，占解压后字节绝大多数的 `assistant/chunk` 等噪声行被跳过）、读取分块 64KB→1MB；Codex 与 DSH 的字节总预算上限从 256MB 统一放宽到 1024MB（增量解析后预算只约束 I/O，重度七天用量不再静默挤出最旧 session）。
- DSH 扫描缓存保留最新会话：按 mtime 保留最新 256 个 session 文件的解析结果（hot set），历史/冷文件不再每轮全量重解压，只有 mtime/size 变化的热文件会重新解析；被挤出选中集或删除的文件自动失效，不产生脏读。
- 重构客户端 ↔ quota provider 关系：引入 `ClientDescriptor` / `ClientProviderBinding`，把 provider-level `mergeOpencodeUsage` 字段抽象为 `clientBindings[]`；schema 升级到 v2，旧 v1 配置自动迁移。
- Codex 本地账本从 `turn_context` 解析 model 名称，让 GPT-5.6 Sol / Terra / Luna 在公开价目中可被独立计价；新增 `recentSamples` 字段把逐次调用样本带入客户端 tab 的价值估算。
- minimax v2 SQLite reader 增加 model 回退链：row-level `model` → session-level `record_json.effectiveModel` → ledger 唯一模型；多模型时不再猜测。
- 客户端 tab tab 标题新增 provider 数量徽标：每个客户端 tab 后显示该客户端已识别的 Provider 数（如"Antigravity 3"），让用户一眼看到哪些 Provider 在产生数据。
- OpenAI 模型定价升级：新增 GPT-6 Astra 价格（Input $10 / Cached Input $1 / Output $50），GPT-5.6 Sol 价格更新为 $4 / $0.4 / $20（原 $5 / $0.5 / $30），模型匹配从 `contains` 宽匹配改为小写后精确相等，避免同系列不同价模型被误吞；价目快照日期更新为 `2026-09-05`。
- 模型价格目录 JSON 化：全部价格数据从 Swift 代码迁移到随 app 打包的 `Sources/LLM-monitor/Resources/ModelPricing.json`，未来调价 / 新增 / 退休模型只改该文件（同步测试与 spec）；`ModelPricingCatalog` 启动时加载 JSON，公开 API（`pricing` / `estimate` / `estimateByDay` / `tokenComponents` / `lastUpdated`）签名与语义不变。
- 打包产物瘦身：`.app` 从 14.3MB 降到 3.5MB（-75%）。构建从 universal 双架构改为 arm64-only；打包前先导出 `build/LLM-monitor.dSYM`（约 13MB，留在 .app 外，保留线上崩溃符号化能力），再 strip .app 内二进制符号表（主二进制 12.2MB → 2.9MB）；应用图标去除 icns 内逐字节重复图层（256px/512px 各存两份）并用 pngquant 压缩图层（2.1MB → 0.6MB），原始源图不做任何修改，仅压缩进入 iconset 的副本。

### Removed

- 定价退休：移除 Antigravity 的 Gemini 2.5 系列（Pro / Flash）与 MiniMax M2 系列（M2.7 / M2.5 / M2.1 及 highspeed 档）价格条目，MiniMax 仅保留 M3；被退休模型的历史用量将显示"未定价"（有意行为）。
- 移除 DeepSeek「仅工作日」设置开关及 `deepseekPeakWeekdaysOnly` 配置键：高峰时段固定为北京时间周一至周五 9:00–12:00 与 14:00–18:00（官方口径，高峰永不含周末），周六、周日全天平价（1×），高峰价格为平价的 2 倍；旧配置文件中残留的该键会被静默忽略。

### Fixed

- 修复 Codex (ChatGPT) 今日与近几日用量金额显示 `—` 的问题：优化 `summarizeLocalUsage` 样本截断逻辑，在全量读取后按完成时间排序保留最新样本，避免倒序读取时最先解析的最新样本被提前截断丢弃。
- 修复 Codex 与 DSH 的 `promptID` 粒度过细导致今日 `turns` 等于 `rounds` 的问题：规范化 `promptID` 共享同一个 turn 标识（移除单次 token 事件时间戳与 step 编号），并修正 DSH 每日 turn 聚合的跨 session 去重键。
- 修复 MiniMax (DSH) 5h 和周额度浮窗中未缓存输入显示为 `0`（如 `0 (+65M cached)`）的问题：统一将 DSH 样本的 `inputTokens` 规范化为包含缓存的总输入口径（`uncached + cached`），使浮窗中的 `uncachedInputTokens` 计算与 7 日图保持一致。
- 提升本地扫描器容量上限：将 `maxRecentSamples` 从 4,096 扩容至 65,536，`maxSessionFiles` 从 256 扩容至 1,024，`maxEventCacheEntries` 从 64 扩容至 256，避免重度使用及 7 天周期内样本溢出截断。
- 升级 DSH (`v5`)、MiniMax (`v14`) 和 Codex (`v7`) 本地缓存索引指纹版本，自动失效旧快照以全量重建规范化数据。
- 明确 OpenAI/Codex 价格目录只对当前支持的 GPT-5.5 / GPT-5.6 Sol/Terra/Luna 建立价格；未知或已移除模型不再猜价。
- 客户端 tab 当日聚合落后于样本时（DB 缓存尚未刷新），用最近样本补齐当日 token 数，避免 UI 显示陈旧的"今日 0"。
- 移除客户端 tab 中 OpenCode 诊断页（功能已被 clientsPane 吸收，原始 spec 文档已同步更新）。
- 部分模型没有公开价格时，菜单 footer、7 天表格和设置页统一标注“部分计价”，金额只覆盖已知价格模型。
- Provider 卡片和设置页复用同一次 `usageProjection` 快照，避免一次 SwiftUI 渲染重复聚合相同本地样本。
- DSH 坏文件、文件选择顺序、replay dedup、缓存样本边界和 MiniMax 字符聚合失败路径增加隔离与重试诊断。
- 修复 DSH 路由 MiniMax-M3 模型时 reasoning token 始终显示为 `0` 的问题：DSH session 日志的 MiniMax-M3 路径经常缺少 `reasoningTokens` 字段，scanner 现在读取同一 `assistant/message` 事件下的 `reasoning`、`text`、`tool-call.arguments` 内容块，按字符比例估算 Reason，并保持 `Output + Reason = raw outputTokens`。其他模型、其他 provider 或没有可用内容块时仍按 `Reason = 0` 处理。升级 DSH cache 到 `v5` 触发全量重建。
- 修复常规刷新路径的 mid-cycle 补刷新从未生效的问题：截止时间在处理完成前仍是已过期的旧值，被 60 秒 guard 一律跳过；现在过期登记回退到 `now + 刷新间隔` 推导补刷新时点，手动刷新与未来截止时间的行为不变。
- 修复关闭 ZCode「活动/余额解析」开关后仍残留已展示余额的问题：开关关闭时立即清除缓存余额并落盘（冷启动不复活），日志读取失败仍保留上次好值，不因瞬时失败误清。
- 修复客户端 tab 七天柱图与分组把第 8 天样本计入的问题：分组与组内总量严格限定为展示窗口内的 7 个自然日；同时补齐 ChatGPT (Codex) 卡片在开启 OpenCode 合并后的 token 与金额叠加（此前 hover 明细不含 OpenCode 部分）。

## [1.4.2] - 2026-08-12

### Added

- 新增额度更新通知：同一模型的短周期或周额度较上一次成功请求增加时，通过 macOS 系统通知展示变化前后的百分比。
- 新增 GLM、DeepSeek 与 OpenCode 品牌图标，并统一用于菜单卡片和设置页导航。

### Changed

- 状态栏保留用户选择的主图标及系统前景色，改用可选的右下角健康圆点表示状态：绿色健康、橙色预警、红色异常。
- 重新整理设置窗口的字体层级、分区说明和设置项布局；布尔选项统一使用小尺寸 switch，标签与控件左右对齐。
- 菜单栏图标画布调整为 22pt，主图形为 20pt，健康圆点为 6pt。
- 菜单窗口按内容决定高度（卡片少→窗口矮、全部显示；卡片多到超过当前屏幕可见高度 70% 时由 `NSWindow.contentMaxSize` 封顶，内部 ScrollView 滚动）。原先用 SwiftUI frame 拼凑高度预算会在多屏 / Dock 变化时拿到错误值，本版改用 AppKit 桥接在窗口层设上限。
- Codex reset credits 改为周期自动刷新：scheduler 每 20 次 background 抓取后补 1 次 full 抓取，让重置卡这类只在 full 抓取里返回的字段在常驻不主动刷新时也能保持新鲜。默认刷新间隔 300s 下，每约 100 分钟自动重抓；"可能过期"判定同步改为按 `3 × (N × 刷新间隔) ≈ 5 小时` 计算，移除原先 15 分钟随机误报。

### Fixed

- 延迟初始化系统通知中心，避免应用启动早期访问 `UNUserNotificationCenter` 导致崩溃。
- 裸 SwiftPM 可执行文件缺少 Bundle Identifier 时安全禁用通知，避免调试启动异常。

## [1.4.1] - 2026-08-09

### Fixed

- 修复部分 macOS 版本中菜单栏图标持续重绘，可能导致 CPU 占用和内存增长的问题。

## [1.4.0] - 2026-08-09

> 1.4.0 是一次“整合重新发布”：它把 1.3.0 之后积累的代码状态作为 universal macOS
> 菜单栏应用整体发布（对应 git tag 为单个 `publish clean 1.4.0 snapshot` 提交）。
> 下列 Added/Changed/Fixed 描述的是相对 1.3.0 的**累计**变化，其中部分能力在 1.3.0
> 已存在（例如 GLM ZCode、Minimax v2、OpenCode 合并的初版），并非 1.4.0 无条件新增；
> 1.4.0 的实际增量主要是 universal 打包、Antigravity 纯 RPC 化与 DeepSeek 监控的整合。
> 发布日期 2026-08-09 为真实 tag 日期（1.3.0 为 2026-07-15）。

### Added

- 新增 GLM Coding Plan 与 DeepSeek 监控，包括额度/余额、高峰时段提示和本地用量展示。
- 新增 OpenCode provider 分片及可选合并，支持 Minimax、ChatGPT、Antigravity、GLM 与 DeepSeek。
- 新增 GLM ZCode、Minimax v2 和 Antigravity RPC 本地 token 用量扫描。
- 新增多款状态栏图标，以及彩色健康度和 macOS 单色模板两种指示模式。
- DeepSeek 高峰期增加「仅工作日（周一至周五）」开关，周末按平价显示。

### Changed

- Antigravity 本地用量改为纯 RPC 架构，并改进多工作区、模型分组和 Turns/Rounds 统计。
- 额度窗口采用 binding constraint 展示逻辑，并补充 reset 倒计时与窗口详情。
- 本地 scanner 统一增加增量缓存、取消安全、generation 守门和 SQLite 临时副本回退。
- 配置、日志、刷新调度和首次启动流程进一步收紧，并支持损坏配置自动备份恢复。

### Fixed

- 修复 GLM 闲时任务在额度窗口和本地日用量中的归属问题。
- 修复多个 provider 合并时的 prompt 去重、窗口边界与 token 分类问题。
- 修复状态栏、悬浮面板、菜单自动关闭和应用单实例相关的边界行为。
- 修复并发刷新、配置监听、冷启动缓存恢复和本地数据库读取的稳定性问题。

## [1.3.0] - 2026-07-15

### Added

- 增加 GLM Coding Plan 的 ZCode 本地 token 用量扫描，并支持 OpenCode 用量合并。
- 增加 Minimax v2 `runtime-state.sqlite` 本地用量扫描。
- 增加 OpenCode 多 provider 分片、alias 去重和本地窗口用量展示。
- 首次启动时提供配置引导，设置页支持 provider 配置和本地登录项管理。

### Changed

- Minimax 本地数据源统一使用 v2 runtime 数据库。
- 本地 scanner 增加缓存恢复、取消安全和 generation 守门，避免旧扫描结果覆盖新状态。
- 刷新调度、错误提示和配置文件恢复流程更加明确，并通过 Swift 6 严格并发编译检查。

### Fixed

- 修复 GLM 5h 窗口缺少 reset 时间时，本地 token 用量可能扩大到整个缓存窗口的问题。
- 修复 alias 合并造成的重复 prompt 统计和多个 provider 之间的用量串扰。
- 修复配置 watcher 重启、full refresh 等待取消和首次启动占位凭据误启用问题。
