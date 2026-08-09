# 性能预算（Performance Policy）

macOS 菜单栏常驻 app（默认 5 分钟一刷，Antigravity 60s）。以下是实现需要持续满足的资源目标。

## 资源目标

| 指标 | 目标 | 验证 |
| --- | --- | --- |
| Idle CPU | < 0.1% | `top -pid $(pgrep LLM-monitor)` |
| RSS | 稳定（不单调增长） | `ps -o rss= -p $(pgrep LLM-monitor)` |
| 日志 | 5 MB × 3 = ~15 MB 上限 | `ls -lh ~/Library/Application\ Support/LLM-monitor/log.txt*` |
| 冷启动 | 避免同步网络与重 I/O | Instruments / Time Profiler |

## 刷新间隔 & 退避

| Provider | 默认间隔 | 失败退避 |
| --- | --- | --- |
| minimax / GLM / Codex | 300s | 2×, 4×, …, 30min + ±10% jitter |
| Antigravity | 60s | 同上 |
| 4 local scanner | 跟随主 quota 刷新后触发 | single attempt，失败不重试 |

[`AppConfig.effectiveRefreshInterval`](../../Sources/LLM-monitor/Services/ConfigStore.swift:23)
clamp 到 10s～30d：下限防止 0/负数导致 `Task.sleep` 立即返回 → 高速循环 / CPU 100%，
上限防止极大手工配置在 `TimeInterval` / `Int` 转换时溢出或让刷新近似永久停摆。
[`ProviderRefreshScheduler.nextDelay`](../../Sources/LLM-monitor/Services/ProviderRefreshScheduler.swift:223)：
成功 → `baseInterval`；失败 → `baseInterval × 2^failures`（封顶 5 次）→ cap 30 min → ±10%
jitter。

## 主线程约束

- 重 I/O 全部 background（SQL 聚合、文件遍历、缓存读写）
- 4 scanner 模板：`@MainActor` 实例只改 `@Published` 状态；`performScanPure` 是
  `nonisolated static`；pipeline 在 `AsyncMutex.pipelineMutex` 内串行
- 主线程不调 `Data.write(to:)` / `FileManager.moveItem` / `Process.run`
- `AppLog` 走专用 `DispatchQueue` 异步写，UI 线程零阻塞；stdout 也异步
- 图表 re-render on data change only（`@Published` 驱动）；7 天窗口用 `pow(value, 0.3)`
  非线性缩放 [TokenChart.swift:35](../../Sources/LLM-monitor/Views/TokenChart.swift:35)
