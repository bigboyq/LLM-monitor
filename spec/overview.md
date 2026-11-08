# LLM Monitor — Project Spec

macOS menu bar app for watching remaining LLM service quota. The app is intentionally passive: it lives in the menu bar, reads a local JSON config, refreshes quota in the background, and shows the latest status when the menu is opened.

本文件是 spec 的**入口**：只放范围、目标、分层约束、概念模型与任务路由。字段契约、运行时行为、文件职责表分别见 `config.md` / `runtime.md` / `source-map.md`；按任务查表见下方 §Spec 地图与任务路由。

## Current Scope

| Area | Current behavior |
|---|---|
| Platform | macOS 14+, SwiftUI `MenuBarExtra` |
| Build system | Swift Package Manager executable target (with `LLMMonitorTests` test target) |
| UI model | Menu bar drop-down plus a native Settings window; per-provider interactive refresh in popover card header and edge dock circles; lightweight setup guidance appears when all providers are unconfigured |
| Edge dock | Optional screen-edge panel, one circle per enabled Provider, click-through by default and hidden while the frontmost App is fullscreen (`hideInFullscreen`, default `true`). Shape is a four-way `EdgeDockMode` picker (无 / 状态窗 / 小圆环 / 自动隐藏状态窗) whose default is **auto-hide window** — the feature ships on, occupying only a 7pt ring column until the mouse approaches; clicking an individual provider circle without dragging triggers immediate per-provider refresh (`state.refreshOne(providerID:)`) with loading spinner feedback |
| Hover details | Delayed floating edge panels show shared account / Plan details; quota menu expands Plan details and seven-day history independently, and the independent window combines both |
| Appearance | Settings Interface pane 「外观」 section: 浅色 / 深色 / 自动 (default), drafted with ordinary settings and applied to `NSApp.appearance` on save; `MenuBarExtra` native presentation follows the system |
| Login item | Settings-window launch-at-login toggle backed by `SMAppService.mainApp`; menu footer's 自启 entry is also a toggle button (状态化图标 `power` / `power.dotted`) |
| Fleet Sync (多机联动) | Optional LAN sync between one hub and one or more secondary nodes: node→hub periodic usage reports, hub-merged fleet snapshot, scope switching (全局 / 本机 / 节点) in menu and dock cards, effective-quota fallback for stale local fetches. Wire protocol, storage and coordinator: `sync.md` |
| Config | `~/Library/Application Support/LLM-monitor/config.json`, JSON, permission `0600` |
| Fleet device identity | `~/Library/Application Support/LLM-monitor/.deviceId`; independent of config synchronization; only created when Fleet Sync is enabled |
| Instance | One process per user config directory, enforced by `instance.lock` |
| Runtime log | `~/Library/Application Support/LLM-monitor/log.txt` plus stdout and `os.Logger` (privacy `.private`, Console.app 默认脱敏)；测试进程改写至 `NSTemporaryDirectory()`（`LLM_MONITOR_LOG_PATH` 覆盖最优先） |
| Quota Providers | `minimax_token_plan`, `codex_chatgpt` (supports multi-key API quota tracking with independent allowances, progress bars and reset countdowns), `antigravity`, `glm_coding_plan`, `deepseek` |
| Clients | Codex, Antigravity, Agy, ZCode, OpenCode, DSH, MiniMax Code; clients may contribute to multiple quota providers |
| Refresh | Provider scheduler drives quota refreshes and settled-batch LocalUsage reconcile; manual per-provider refresh supported via card header refresh button and edge dock provider circle click (`refreshOne`); scanners use FSEvents dirty invalidation |
| Config reload | Event-driven via a `DispatchSourceFileSystemObject` on the `config.json` **file** itself, not the directory (the directory also holds `log.txt` / `last-refresh.json`); debounced, with reopen-on-rename/atomic-replace retry and backoff (no polling) |
| Window lifetime | Menu closes on focus loss or after 30s of inactivity; any in-menu interaction resets the timer |

## Design Goals

1. **Low interruption** — the app never takes focus unless the user opens the menu.
2. **Local config with a native editor** — settings can edit supported provider fields, while `config.json` remains directly editable and reloads through filesystem events.
3. **Provider isolation** — each provider fetches independently; one slow or failing provider should not block the others.
4. **Auditable config** — API keys and provider settings live in a readable JSON file that can be diffed or managed by dotfiles.
5. **Graceful failure** — failed fetches show an error and keep the last successful quota in memory.
6. **Small provider surface** — adding a provider should mean implementing one `QuotaFetcher`, adding one `ProviderKind`, and registering one descriptor.

## Architecture Layers

代码按**逻辑分层**组织（单 SwiftPM target，无 module 边界——分层靠类型引用约束，不靠 import）。
目录划分（Models / Services / Views / Fetchers）与逻辑层**不一一对应**：Services 同时容纳 L0 数据源、
编排与基础设施；L1/L2 类型同住 `Models/UsageProjectionKernel.swift`。约束按逻辑层执行：

| 层 | 内容 | 允许依赖 |
|---|---|---|
| **L0 数据源** | `Fetchers/` 全部；`Services/` 下的各 `*Scanner` / `*DBReader` / `*Aggregation`（Antigravity/Agy/Codex/Dsh/GlmZcode/Minimax/Opencode 系，含 Antigravity scanner 按职责拆出的 `AntigravityFilesystem.swift` / `AntigravityLocalUsageCache.swift` 两个同类型 extension 文件） | L0 专属基础设施（`Services/Infra/`：HTTP、SQLite、进程、文件、并发原语、错误类型）；Models 的数据契约类型 |
| **L1 适配** | `HarnessUsageFrame` + 各 harness 的帧适配（`DshHarnessFrames` 等；类型与 L2 内核同住 `Models/UsageProjectionKernel.swift`） | L0 产物类型、L1 自身 |
| **L2 投影内核** | `UsageProjectionKernel.project`（`Models/UsageProjectionKernel.swift`）——全仓**唯一**生产调用点在 `ProviderStatus.usageProjection` | L1、`TokenAccounting`、`ModelPricingCatalog`、绑定矩阵 |
| **L3 消费** | 视图模型（`ClientUsageAggregation.swift` 的 `HarnessTodaySummary`、`ProviderClientModel.swift` 的 `ClientUsageContribution` / `ProviderUsageProjection` / `ClientProviderUsageSummary`）与全部 `Views/` | L2 产出、AppState 状态宿主 |
| **横切** | 身份语汇 `Models/ClientIdentity.swift`（QuotaProviderID / ClientID / ClientDescriptor / ClientProviderBinding + 默认绑定矩阵）、纯数值 `Models/SaturatingArithmetic.swift`、排版常量 `Services/LayoutMetrics.swift` | 各层均可读；它们自身只依赖更底层 |

**方向规则**（2026-10 架构审核后确立）：禁止 Models → Services（业务编排/配置）、禁止 Services → Views（排版常量例外：统一走 `Services/LayoutMetrics.swift`）、禁止任何层 → L3。基础设施（`Services/Infra/`）是所有层的合法下层。审核基线：`Models → Services` / `Models → Views` / `Fetchers → Views` 代码引用均为零（注释与文档提及不计）；`Services → Views` 仅豁免 AppKit 装载 SwiftUI 根视图的 **2 处 NSHostingView 宿主**（`EdgeDockController+Window.swift`、`EdgeDockController+Popover.swift`；原第三处 `MenuBarRightClickHandler` 的 SettingsLink 宿主已随 2.5.2 改为 `OpenSettingsAction` 注入而移除）；`UsageProjectionKernel.project` 生产调用点唯一（`ProviderClientModel.swift:349`，其余全部在 `Tests/`）。

## 概念模型

三个词贯穿全库，先定义再引用。身份语汇的事实源是 `Sources/LLM-monitor/Models/ClientIdentity.swift`。

| 概念 | 是什么 | 不是 | 事实源 |
|---|---|---|---|
| **provider** | 5 个 quota provider：`minimax_token_plan` / `codex_chatgpt` / `antigravity` / `glm_coding_plan` / `deepseek`。额度卡与 fetcher 的归属单位（Codex ChatGPT 支持多 API Key 独立配额抓取） | 不是本地应用；共享本地账本的客户端（OpenCode / DSH）不是 provider | `FetcherDescriptor`（`Fetchers/FetcherDescriptor.swift`）、`ProviderKind`（`Models/ProviderStatus.swift`）、`QuotaProviderID` |
| **client** | 7 个本地客户端：Codex、Antigravity、Agy、ZCode、OpenCode、DSH、MiniMax Code。本地 transcript / SQLite / RPC 账本的来源，一个 client 可向多个 provider 贡献用量 | 不是额度卡；client 自己没有 quota | `ClientID` / `ClientDescriptor`（`Models/ClientIdentity.swift`） |
| **harness** | L1 帧适配概念：某个 client 的 `ProviderStatus` 字段被抽成 `HarnessUsageFrame`，经 L2 `UsageProjectionKernel.project` 投影后归属到 provider 卡 | 不是 provider，也不是 client——它是 client → provider 之间的适配层 | 抽取注册表 `usageFrameExtractors`（`Models/UsageFrameExtractors.swift`）、内核 `UsageProjectionKernel`（`Models/UsageProjectionKernel.swift`） |

两者之间的桥只有两条：

- **client → provider 自动归因**：native 帧自带 `quotaProviderID`；共享账本按已登记的 provider 别名匹配，所有已支持来源均参与统计，不提供启停开关。别名事实源是 `ClientProviderBinding.defaultBindings`（10 条共享账本路由），`AppConfig.clientBindings` 仅为只读运行时出口，历史 JSON 配置已移除。未知 provider 保留未归属，不按模型名猜测；详见 `config.md` §Config Schema。
- **帧 → 投影**：L1 抽取注册表把各 client 的原始字段归一成 `HarnessUsageFrame`（`clientID` / `sourceKey` / quota 归属），L2 内核投影出 per-client × per-provider 结果；生产调用点唯一（`ProviderStatus.usageProjection`），详见 `runtime.md` §Architecture。

计数不对称是常态：5 provider、7 client，harness 与实现了帧适配的 client 一一对应（逐个 harness 的 raw 字段口径与守恒拆分规则见 `accounting.md` §Harness 对齐矩阵）。

## Spec 地图与任务路由

### 全文件清单

文档按职责分流：`providers/` 维护远端额度、认证消费、套餐规则与 Provider 展示；
`harnesses/` 维护本地客户端账本、扫描、计量、凭证来源及客户端自身行为。
该目录按客户端组织 L0 数据源与 L1 帧适配规格，不改变前文 harness 的 L1 术语定义。
跨层接线只在主责文档保留完整契约，另一侧通过链接引用；客户端从哪个 Provider 取额度，
不决定它的本地账本应写在哪份文档。Antigravity 的本地用量规格（阶段二b起为会话 `.db` 直读，本地 RPC 已退役）保留在现有文档中。

| 文件 | 覆盖范围 |
|---|---|
| `overview.md` | 入口：当前范围、设计目标、分层约束与方向规则、概念模型、本路由表 |
| `source-map.md` | 全量 `path → 职责` 文件表 + 测试套件约定（机械对账用，不作为阅读材料） |
| `config.md` | `config.json` 字段契约、运行时落盘文件、构建与打包脚本 |
| `runtime.md` | 组件接线图、启动流程、刷新调度、provider 状态机、本地认证探测、UI 广播、数据模型、健康度算法、错误兜底、provider 注册契约、产品边界 |
| `accounting.md` | token 计量四桶口径、harness 对齐矩阵、promptID 命名空间、跨 provider 金额汇总 |
| `local-usage-reconcile.md` | reconcile 三层模型与三种扫描模式、provider 策略矩阵、scanner 并发模型 |
| `sync.md` | 多机联动（Fleet Sync）核心链路：角色派生与拓扑不变量、wire 协议、报告/快照形状、合并与选举、独立 `.deviceId` 身份文件与 seq、fleet.sqlite 单表存储、报告构建、协调器编排与 AppState 接线 |
| `notifications.md` | 额度事件检测与触发语义、渠道层（系统通知 / Bark）、通知配置与设置 UI |
| `ui-design.md` | UI 主题索引（拆分后的导航入口，内容分流到 `ui/*.md`） |
| `ui/edge-dock.md` | 屏幕边缘状态窗：几何、锚点、命中判定、拖拽、鼠标轮询、全屏门控、dock 形态 |
| `ui/menu-and-cards.md` | 菜单面板结构、header / content / footer、Provider 卡片与状态、hover 浮层、进度与健康色 |
| `ui/settings.md` | 设置窗口：通用 pane 与字体角色、各 provider 设置、客户端 pane、开机自启 |
| `providers/antigravity.md` | Antigravity：额度凭据策略（2.5.0 ls 优先本地 RPC + keychain 兜底开关 + agy 代理刷新 + 预检/退避；远端配额路径 Keychain 凭据 + Google API）+ 本地用量 `.db` 直读 scanner（阶段二b；`.pb` 退役）与响应形状、文件格式 |
| `providers/chatgpt.md` | ChatGPT Plan：远端额度、认证消费、reset credits、多 Key API 额度与独立用量进度、窗口估值与 Provider 展示 |
| `providers/deepseek.md` | DeepSeek：账户余额语义、高峰窗口（北京时间）、OpenCode / ZCode / DSH 合并、错误映射 |
| `providers/glm.md` | GLM Coding Plan：远端额度、API Key 与 JWT 扩展查询、价格、高峰时段与 Provider 展示 |
| `providers/minimax.md` | MiniMax Token Plan：远端额度、响应解析、价格与高峰倍率、服务端限额、Provider 展示与错误处理 |
| `harnesses/agy.md` | Agy CLI：transcript + cli log 扫描、模型名 join、帧投影命名空间 |
| `harnesses/codex.md` | Codex：`auth.json` 凭证来源、本地 session 聚合、扫描缓存、计量与上下文压缩 |
| `harnesses/dsh.md` | DSH：`~/.dsh/sessions` 账本扫描、provider 分片与归因别名、rounds / turns |
| `harnesses/minimaxcode.md` | MiniMax Code：`runtime-state.sqlite`、本地 scanner / reader、reasoning 分摊与缓存口径 |
| `harnesses/opencode.md` | OpenCode：`message` 表读取、provider 绑定与别名、reasoning fallback、7 天窗口 |
| `harnesses/zcode.md` | ZCode：本地凭证来源、SQLite 账本与分片、扫描计量、上下文压缩及客户端自身轮询调研 |

### client → provider spec

| Client | 本地账本 / 通道 | 归属 provider | 读哪份 spec |
|---|---|---|---|
| Codex | 本地 session JSONL + ChatGPT Plan 远程（支持多 API Key 独立配额跟踪） | `codex_chatgpt`（openai）、经 OpenCode 路径并入其他 | 本地与凭证来源：`harnesses/codex.md`；远端额度：`providers/chatgpt.md` |
| Antigravity | 会话 `.db` 直读（本地用量，阶段二b）；额度走 2.5.0 凭据策略：本地 language_server RPC 优先、keychain 兜底、agy 代理刷新（`providers/antigravity.md` § Remote Quota Path） | `antigravity` | `providers/antigravity.md` |
| Agy | `~/.gemini/antigravity-cli/brain/` transcript + cli log | `antigravity`（native，帧自带归属） | `harnesses/agy.md` |
| ZCode | `~/.zcode` SQLite `model_usage` | 智谱行进 GLM 卡；minimax / deepseek 分片并入对应卡 | 本地与客户端策略：`harnesses/zcode.md`；远端额度：`providers/glm.md` |
| OpenCode | OpenCode SQLite `message` 表（多 provider 账本） | 按内置 provider 路由自动归因 | `harnesses/opencode.md` |
| DSH | `~/.dsh/sessions` JSONL/zstd（多 provider 账本） | 按内置 provider 别名自动归因 | `harnesses/dsh.md` |
| MiniMax Code | `runtime-state.sqlite` | `minimax_token_plan`（minimax） | 本地账本：`harnesses/minimaxcode.md`；远端额度：`providers/minimax.md` |
| DeepSeek | 无本地账本，纯余额 fetcher | `deepseek` | `providers/deepseek.md` |

### 任务配方

| 任务 | 起点 |
|---|---|
| 新增 quota provider | `runtime.md` §Provider Registration Contract |
| 改 Provider 的远端抓取 / 响应解析 / 套餐规则 | `providers/<名>.md`（antigravity / chatgpt / deepseek / glm / minimax） |
| 改本地客户端账本 / scanner / reader / 帧适配 / 客户端行为 | `harnesses/<名>.md`（agy / codex / dsh / minimaxcode / opencode / zcode）；Antigravity 本地用量（`.db` 直读）仍见 `providers/antigravity.md` |
| 改配额卡、菜单结构、hover 浮层、进度与健康色 | `ui/menu-and-cards.md` §Provider Card |
| 改屏幕边缘状态窗（几何 / 拖拽 / 全屏 / dock 形态） | `ui/edge-dock.md` §Edge Status Dock (Screen Edge Panel) |
| 改设置窗口与客户端 pane | `ui/settings.md` §Settings Window 及其下 §客户端 (Clients) pane |
| 改开机自启入口 | `ui/settings.md` §Launch At Login (Settings Window) |
| 改 token 计量、思考分摊、价格与金额汇总 | `accounting.md` §Harness 对齐矩阵 |
| 改扫描调度、缓存指纹、reconcile 分层 | `local-usage-reconcile.md` §Scanner Concurrency (本地用量 scanner 的并发模型) |
| 改多机联动（协议 / 存储 / 合并选举 / 上报构建 / 协调器） | `sync.md`（设计裁定与未实现项见 `docs/reviews/fleet-sync-design.md`） |
| 改 `config.json` 字段、运行时文件、构建打包 | `config.md` §Config Schema |
| 改通知触发语义、渠道与去抖 | `notifications.md` §3. 事件模型与触发语义 |
| 改额度健康度分档与状态胶囊配色 | `runtime.md` §Health Algorithm |
| 查某个源文件/脚本/测试文件负责什么 | `source-map.md` §Source Map |
| 改分层依赖（新增 import 方向） | 本文件 §Architecture Layers |

### 横切问题路由

- 计量 / 价格 / 思考分摊 → `accounting.md`
- 扫描调度 / 缓存 / reconcile → `local-usage-reconcile.md`
- 多机联动 / fleet 协议与存储 → `sync.md`
- 通知触发与渠道 → `notifications.md`
- 配置字段与默认值 → `config.md`
- 身份语汇（client / provider / 绑定矩阵） → `Models/ClientIdentity.swift` + `runtime.md` §Provider Registration Contract

## Out Of Scope

- Automatic generation of arbitrary provider-specific settings forms.
- Provider deletion from UI.
- Push notifications beyond the Bark channel (no APNs integration, no third-party push
  services). See `spec/notifications.md`.
- Long-term usage history and advanced cost analytics beyond the rolling seven-day usage trends.
- Automatic provider discovery from remote sources.
- Automatic updates and in-app version checks — upgrading means downloading a new build from
  GitHub Releases manually (release gating and the pre-release checklist: `spec/config.md`).

> 核对基线：2026-11-08 · 代码 4941430
