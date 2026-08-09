# Changelog

本文件记录面向用户的版本变化；审计、重构和测试补强只在影响使用行为时摘要记录。

## [Unreleased]

## [1.4.1] - 2026-08-09

### Fixed

- 修复部分 macOS 版本中菜单栏图标持续重绘，可能导致 CPU 占用和内存增长的问题。

## [1.4.0] - 2026-08-09

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

## [1.3.0]

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
