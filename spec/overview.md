# LLM Monitor — Project Spec

macOS menu bar app for watching remaining LLM service quota. The app is intentionally passive: it lives in the menu bar, reads a local JSON config, refreshes quota in the background, and shows the latest status when the menu is opened.

本文件是 spec 的**入口**：只放范围、目标、分层约束、概念模型与任务路由。字段契约、运行时行为、文件职责表分别见 `config.md` / `runtime.md` / `source-map.md`；按任务查表见下方 §Spec 地图与任务路由。

## Current Scope

| Area | Current behavior |
|---|---|
| Platform | macOS 14+, SwiftUI `MenuBarExtra` |
| Build system | Swift Package Manager executable target (with `LLMMonitorTests` test target) |
| UI model | Menu bar drop-down plus a native Settings window; lightweight setup guidance appears when all providers are unconfigured |
| Edge dock | Optional screen-edge panel, one circle per enabled Provider, click-through by default and hidden while the frontmost App is fullscreen (`hideInFullscreen`, default `true`). Shape is a four-way `EdgeDockMode` picker (无 / 状态窗 / 小圆环 / 自动隐藏状态窗) whose default is **auto-hide window** — the feature ships on, occupying only a 7pt ring column until the mouse approaches |
| Hover details | Delayed floating hover panels for compact quota details |
| Login item | Settings-window launch-at-login toggle backed by `SMAppService.mainApp`; menu footer is read-only |
| Config | `~/Library/Application Support/LLM-monitor/config.json`, JSON, permission `0600` |
| Instance | One process per user config directory, enforced by `instance.lock` |
| Runtime log | `~/Library/Application Support/LLM-monitor/log.txt` plus stdout and `os.Logger` (privacy `.private`, Console.app 默认脱敏) |
| Quota Providers | `minimax_token_plan`, `codex_chatgpt`, `antigravity`, `glm_coding_plan`, `deepseek` |
| Clients | Codex, Antigravity, Agy, ZCode, OpenCode, DSH, MiniMax Code; clients may contribute to multiple quota providers |
| Refresh | Provider scheduler drives quota refreshes and settled-batch LocalUsage reconcile; scanners use FSEvents dirty invalidation |
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
| **L3 消费** | 视图模型（`ClientUsageAggregation.swift` 的 `HarnessTodaySummary` / `ProviderStatusStrip`、`ProviderClientModel.swift` 的 `ClientUsageContribution` / `ProviderUsageProjection` / `ClientProviderUsageSummary`）与全部 `Views/` | L2 产出、AppState 状态宿主 |
| **横切** | 身份语汇 `Models/ClientIdentity.swift`（QuotaProviderID / ClientID / ClientDescriptor / ClientProviderBinding + 默认绑定矩阵）、纯数值 `Models/SaturatingArithmetic.swift`、排版常量 `Services/LayoutMetrics.swift` | 各层均可读；它们自身只依赖更底层 |

**方向规则**（2026-10 架构审核后确立）：禁止 Models → Services（业务编排/配置）、禁止 Services → Views（排版常量例外：统一走 `Services/LayoutMetrics.swift`）、禁止任何层 → L3。基础设施（`Services/Infra/`）是所有层的合法下层。审核基线：`Models → Services` / `Models → Views` / `Fetchers → Views` 代码引用均为零（注释与文档提及不计）；`Services → Views` 仅豁免 `EdgeDockController+` 族 **2 处 NSHostingView 宿主**（`+Window.swift:52` / `+Popover.swift:57`——AppKit 宿主装载 SwiftUI 根视图，归属待独立裁定）；`UsageProjectionKernel.project` 生产调用点唯一（`ProviderClientModel.swift:326`，其余全部在 `Tests/`）。

## 概念模型

三个词贯穿全库，先定义再引用。身份语汇的事实源是 `Sources/LLM-monitor/Models/ClientIdentity.swift`。

| 概念 | 是什么 | 不是 | 事实源 |
|---|---|---|---|
| **provider** | 5 个 quota provider：`minimax_token_plan` / `codex_chatgpt` / `antigravity` / `glm_coding_plan` / `deepseek`。额度卡与 fetcher 的归属单位 | 不是本地应用；共享本地账本的客户端（OpenCode / DSH）不是 provider | `FetcherDescriptor`（`Fetchers/FetcherDescriptor.swift`）、`ProviderKind`（`Models/ProviderStatus.swift`）、`QuotaProviderID` |
| **client** | 7 个本地客户端：Codex、Antigravity、Agy、ZCode、OpenCode、DSH、MiniMax Code。本地 transcript / SQLite / RPC 账本的来源，一个 client 可向多个 provider 贡献用量 | 不是额度卡；client 自己没有 quota | `ClientID` / `ClientDescriptor`（`Models/ClientIdentity.swift`） |
| **harness** | L1 帧适配概念：某个 client 的 `ProviderStatus` 字段被抽成 `HarnessUsageFrame`，经 L2 `UsageProjectionKernel.project` 投影后归属到 provider 卡 | 不是 provider，也不是 client——它是 client → provider 之间的适配层 | 抽取注册表 `usageFrameExtractors`（`Models/UsageFrameExtractors.swift`）、内核 `UsageProjectionKernel`（`Models/UsageProjectionKernel.swift`） |

两者之间的桥只有两条：

- **client → provider 门控**：`config.json` 的 `clientBindings[]`。client 不自带归属时，由 `sourceProviderAliases` 匹配 + `enabled` 门控决定贡献到哪张卡；字面量事实源是 `ClientProviderBinding.defaultBindings`（10 条，6 条默认开启），字段语义见 `config.md` §Config Schema。**例外**：Antigravity / agy 的帧自带 `quotaProviderID`，native 归 Antigravity 卡，不走门控。
- **帧 → 投影**：L1 抽取注册表把各 client 的原始字段归一成 `HarnessUsageFrame`（`clientID` / `sourceKey` / quota 归属），L2 内核投影出 per-client × per-provider 结果；生产调用点唯一（`ProviderStatus.usageProjection`），详见 `runtime.md` §Architecture。

计数不对称是常态：5 provider、7 client，harness 与实现了帧适配的 client 一一对应（逐个 harness 的 raw 字段口径与守恒拆分规则见 `accounting.md` §Harness 对齐矩阵）。

## Spec 地图与任务路由

### 全文件清单

| 文件 | 覆盖范围 |
|---|---|
| `overview.md` | 入口：当前范围、设计目标、分层约束与方向规则、概念模型、本路由表 |
| `source-map.md` | 全量 `path → 职责` 文件表 + 测试套件约定（机械对账用，不作为阅读材料） |
| `config.md` | `config.json` 字段契约、运行时落盘文件、构建与打包脚本 |
| `runtime.md` | 组件接线图、启动流程、刷新调度、provider 状态机、本地认证探测、UI 广播、数据模型、健康度算法、错误兜底、provider 注册契约、产品边界 |
| `accounting.md` | token 计量四桶口径、harness 对齐矩阵、promptID 命名空间、跨 provider 金额汇总 |
| `local-usage-reconcile.md` | reconcile 三层模型与三种扫描模式、provider 策略矩阵、scanner 并发模型 |
| `notifications.md` | 额度事件检测与触发语义、渠道层（系统通知 / Bark）、通知配置与设置 UI |
| `ui-design.md` | UI 主题索引（拆分后的导航入口，内容分流到 `ui/*.md`） |
| `ui/edge-dock.md` | 屏幕边缘状态窗：几何、锚点、命中判定、拖拽、鼠标轮询、全屏门控、dock 形态 |
| `ui/menu-and-cards.md` | 菜单面板结构、header / content / footer、Provider 卡片与状态、hover 浮层、进度与健康色 |
| `ui/settings.md` | 设置窗口：通用 pane 与字体角色、各 provider 设置、客户端 pane、开机自启 |
| `providers/agy.md` | agy CLI：transcript + cli log 扫描、模型名 join、帧投影命名空间 |
| `providers/antigravity.md` | Antigravity：进程发现、本地 RPC 与响应形状、quota 读取、本地用量 scanner、文件格式 |
| `providers/codex.md` | Codex：ChatGPT Plan 抓取、`auth.json`、本地 session 聚合、reset credits 端点 |
| `providers/deepseek.md` | DeepSeek：账户余额语义、高峰窗口（北京时间）、OpenCode / ZCode / DSH 合并、错误映射 |
| `providers/dsh.md` | DSH：`~/.dsh/sessions` 账本扫描、provider 分片与归因别名、rounds / turns |
| `providers/glm.md` | GLM Coding Plan：API 请求与解析、高峰时段、ZCode 本地数据源与分片 |
| `providers/minimax.md` | minimax：Token Plan 抓取与解析、`runtime-state.sqlite` scanner、价格与高峰倍率、错误处理 |
| `providers/opencode.md` | OpenCode：`message` 表读取、provider 绑定与别名、reasoning fallback、7 天窗口 |

### client → provider spec

| Client | 本地账本 / 通道 | 归属 provider | 读哪份 spec |
|---|---|---|---|
| Codex | 本地 session JSONL + ChatGPT Plan 远程 | `codex_chatgpt`（openai）、经 OpenCode 路径并入其他 | `providers/codex.md` |
| Antigravity | IDE `language_server` 本地 RPC | `antigravity` | `providers/antigravity.md` |
| Agy | `~/.gemini/antigravity-cli/brain/` transcript + cli log | `antigravity`（native，帧自带归属） | `providers/agy.md` |
| ZCode | `~/.zcode` SQLite `model_usage` | 智谱行进 GLM 卡；minimax / deepseek 分片并入对应卡 | `providers/glm.md` |
| OpenCode | OpenCode SQLite `message` 表（多 provider 账本） | 由 `clientBindings` 决定 | `providers/opencode.md` |
| DSH | `~/.dsh/sessions` JSONL/zstd（多 provider 账本） | 由 `clientBindings` 别名解析 | `providers/dsh.md` |
| MiniMax Code | `runtime-state.sqlite` | `minimax_token_plan`（minimax） | `providers/minimax.md` |
| DeepSeek | 无本地账本，纯余额 fetcher | `deepseek` | `providers/deepseek.md` |

### 任务配方

| 任务 | 起点 |
|---|---|
| 新增 quota provider | `runtime.md` §Provider Registration Contract |
| 改某 provider 的抓取 / 解析 / 缓存 / 帧适配 | `providers/<名>.md`（agy / antigravity / codex / deepseek / dsh / glm / minimax / opencode） |
| 改配额卡、菜单结构、hover 浮层、进度与健康色 | `ui/menu-and-cards.md` §Provider Card |
| 改屏幕边缘状态窗（几何 / 拖拽 / 全屏 / dock 形态） | `ui/edge-dock.md` §Edge Status Dock (Screen Edge Panel) |
| 改设置窗口与客户端 pane | `ui/settings.md` §Settings Window 及其下 §客户端 (Clients) pane |
| 改开机自启入口 | `ui/settings.md` §Launch At Login (Settings Window) |
| 改 token 计量、思考分摊、价格与金额汇总 | `accounting.md` §Harness 对齐矩阵 |
| 改扫描调度、缓存指纹、reconcile 分层 | `local-usage-reconcile.md` §Scanner Concurrency (本地用量 scanner 的并发模型) |
| 改 `config.json` 字段、运行时文件、构建打包 | `config.md` §Config Schema |
| 改通知触发语义、渠道与去抖 | `notifications.md` §3. 事件模型与触发语义 |
| 改额度健康度分档与状态胶囊配色 | `runtime.md` §Health Algorithm |
| 查某个源文件/脚本/测试文件负责什么 | `source-map.md` §Source Map |
| 改分层依赖（新增 import 方向） | 本文件 §Architecture Layers |

### 横切问题路由

- 计量 / 价格 / 思考分摊 → `accounting.md`
- 扫描调度 / 缓存 / reconcile → `local-usage-reconcile.md`
- 通知触发与渠道 → `notifications.md`
- 配置字段与默认值 → `config.md`
- 身份语汇（client / provider / 绑定矩阵） → `Models/ClientIdentity.swift` + `runtime.md` §Provider Registration Contract

## Out Of Scope

- Automatic generation of arbitrary provider-specific settings forms.
- Provider deletion from UI.
- Push notifications beyond the Bark channel (no APNs integration, no third-party push
  services). See `spec/notifications.md`.
- Usage history or cost analytics.
- Automatic provider discovery from remote sources.

> 核对基线：2026-10-04 · 代码 d6396fd
