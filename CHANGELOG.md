# Changelog

本文件记录面向用户的版本变化；审计、重构和测试补强只在影响使用行为时摘要记录。

## [Unreleased]

### Added

- 新增 DeepSeek Harness (dsh) 客户端用量监控：扫描 `~/.dsh/sessions` 中的 JSONL session 日志（zstd / Node 22+ zlib 双解压路径），按 `request/context` 中的 provider 自动合并到 MiniMax / GLM / DeepSeek 三张卡片。
- 新增"设置 > 客户端"tab：按客户端维度（Antigravity / Codex / DSH / MiniMax Code / OpenCode / ZCode）展示本地 token 用量、最近 7 天柱图、缓存命中率与按公开 API 单价估算的价值。
- 新增 `ModelPricingCatalog`：模型价目快照（MiniMax-M3 USD→CNY 换算、DeepSeek 高峰期 2× 倍率、DSH 独立 uncached-input / cache-read bucket 计价）；客户端 tab 标注目录更新日期 `lastUpdated`。
- 客户端 tab 中未定价模型显式列出名称、token 数与调用次数，不再静默归零。

### Changed

- 重构客户端 ↔ quota provider 关系：引入 `ClientDescriptor` / `ClientProviderBinding`，把 provider-level `mergeOpencodeUsage` 字段抽象为 `clientBindings[]`；schema 升级到 v2，旧 v1 配置自动迁移。
- Codex 本地账本从 `turn_context` 解析 model 名称，让 GPT-5.6 Sol / Terra / Luna 在公开价目中可被独立计价；新增 `recentSamples` 字段把逐次调用样本带入客户端 tab 的价值估算。
- minimax v2 SQLite reader 增加 model 回退链：row-level `model` → session-level `record_json.effectiveModel` → ledger 唯一模型；多模型时不再猜测。

### Fixed

- 修复 Codex (ChatGPT) 今日与近几日用量金额显示 `—` 的问题：优化 `summarizeLocalUsage` 样本截断逻辑，在全量读取后按完成时间排序保留最新样本，避免倒序读取时最先解析的最新样本被提前截断丢弃。
- 修复 Codex 与 DSH 的 `promptID` 粒度过细导致今日 `turns` 等于 `rounds` 的问题：规范化 `promptID` 共享同一个 turn 标识（移除单次 token 事件时间戳与 step 编号），并修正 DSH 每日 turn 聚合的跨 session 去重键。
- 修复 MiniMax (DSH) 5h 和周额度浮窗中未缓存输入显示为 `0`（如 `0 (+65M cached)`）的问题：统一将 DSH 样本的 `inputTokens` 规范化为包含缓存的总输入口径（`uncached + cached`），使浮窗中的 `uncachedInputTokens` 计算与 7 日图保持一致。
- 提升本地扫描器容量上限：将 `maxRecentSamples` 从 4,096 扩容至 65,536，`maxSessionFiles` 从 256 扩容至 1,024，`maxEventCacheEntries` 从 64 扩容至 256，避免重度使用及 7 天周期内样本溢出截断。
- 升级 DSH (`v4`)、MiniMax (`v14`) 和 Codex (`v7`) 本地缓存索引指纹版本，自动失效旧快照以全量重建规范化数据。
- 扩充 `ModelPricingCatalog` 对 OpenAI 常见模型（`gpt-4o`, `gpt-4o-mini`, `o1`, `o3-mini` 等）的定价覆盖。
- 客户端 tab 当日聚合落后于样本时（DB 缓存尚未刷新），用最近样本补齐当日 token 数，避免 UI 显示陈旧的"今日 0"。
- 移除客户端 tab 中 OpenCode 诊断页（功能已被 clientsPane 吸收，原始 spec 文档已同步更新）。

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
