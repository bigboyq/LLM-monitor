# 持久化布局（Persistence Layout）

运行时数据集中在 `~/Library/{Application Support,Caches,Logs}/LLM-monitor/` + SQLite 临时副本
在 `NSTemporaryDirectory()`。权限策略统一 **0600 文件 / 0700 目录**，写入走
`O_EXCL | O_CLOEXEC` 原子模式。

## 路径

- 用户配置 → `~/Library/Application Support/LLM-monitor/config.json` [ConfigStore.swift:182](../../Sources/LLM-monitor/Services/ConfigStore.swift:182)
- 实例锁 → `…/LLM-monitor/instance.lock` [AppInstanceLock.swift:19](../../Sources/LLM-monitor/Services/AppInstanceLock.swift:19)
- 损坏配置备份 → `config.json.corrupt-<UUID>.json` [ConfigStore.swift:395](../../Sources/LLM-monitor/Services/ConfigStore.swift:395)
- 日志 → `…/LLM-monitor/log.txt`（rotated `.1` / `.2`）[AppLog.swift:33](../../Sources/LLM-monitor/Services/AppLog.swift:33)
- 4× scanner cache: `~/.minimax/.token-monitor/index.json` (v12, [Minimax:63](../../Sources/LLM-monitor/Services/MinimaxLocalUsageScanner.swift:63)) · `~/.gemini/antigravity/.token-monitor/index.json` (v6, [Antigravity:59](../../Sources/LLM-monitor/Services/AntigravityLocalUsageScanner.swift:59)) · `~/.local/share/opencode/.token-monitor/index.json` (v2, [Opencode:30](../../Sources/LLM-monitor/Services/OpencodeUsageScanner.swift:30)) · `~/.zcode/cli/.token-monitor/index.json` (v8, [GlmZcode:39](../../Sources/LLM-monitor/Services/GlmZcodeLocalUsageScanner.swift:39))
- SQLite 临时副本 → `NSTemporaryDirectory()/llm-monitor-<UUID>.sqlite`

> **Override**：`LLM_MONITOR_LOG_PATH` 改日志位置 [AppLog.swift:22](../../Sources/LLM-monitor/Services/AppLog.swift:22)；
> 测试用 `ConfigStore(configURL:)` 注入。

## 权限 & 原子写

[`FileManagerBox.writePrivate`](../../Sources/LLM-monitor/Services/FileManagerBox.swift:98) 是
项目所有敏感文件写入的**唯一**入口：同目录 `.<basename>.<UUID>.tmp` →
`O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC` + `S_IRUSR | S_IWUSR`（0600 from birth）→
完整 `write()` 循环（`EINTR` 重试）→ `fchmod` 0600 → `fsync` → `rename` 原子替换 →
父目录 `fsync`（best effort + warning）。不存在 `Data.write(.atomic) → chmod` 的
"短窗口宽松 umask"问题。

## Crash safety

| 层 | 保护 |
| --- | --- |
| 配置文件 | 原子 rename，rename 成功即视为写入成功 |
| 日志 | append-only + 5MB rotate（`FileManager.moveItem` 原子） |
| Scanner cache | `newDaily` 先构造再覆盖；`lastCommittedGeneration` 守门防旧 worker 回滚 |
| Lock | flock 由内核管理，进程退出自动释放；锁竞争与锁文件 I/O 失败分开报告 |

## Schema versioning

`config.json` 当前 schema 为 v1；历史文件缺少 `schemaVersion` 时按 v0 解码并在内存中
规范化到 v1，后续保存会写出版本字段。未来不支持的版本会拒绝加载，并禁止旧版本
自动写回，避免覆盖新版本配置。`ProviderConfig` 仍对可选字段使用 `decodeIfPresent`，
保留字段级向前兼容。损坏配置兜底（
[ConfigStore.swift:236](../../Sources/LLM-monitor/Services/ConfigStore.swift:236)）：解析失败
→ 备份到 `config.json.corrupt-<UUID>.json`（0600）→ 备份成功用 `.default` 空配置运行
（不覆盖原文件）→ 备份失败 `persistenceAllowed = false` 禁止自动写回。
4× scanner 用 `ScannerIndexIO` 版本不匹配 → 重扫（v12/v6/v2/v8）。
`SQLiteTempCopy.read` 把生产 `.db` 复制到 `NSTemporaryDirectory()` 绕开 IDE/Antigravity WAL
锁（`CANTOPEN`/`BUSY`），per-scan UUID，权限 0600。
