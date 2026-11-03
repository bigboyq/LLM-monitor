# Runtime — 启动、调度与运行时模型

App 的运行期行为：组件接线图、启动流程、刷新调度、provider 状态机、本地认证探测、UI 广播、数据模型、健康度算法、错误兜底与 provider 注册契约。配置字段契约不在本文件，见 `config.md`；token 计量口径见 `accounting.md`。

## Architecture

```mermaid
flowchart TD
  App["LLMMonitorApp\n@main"] --> MenuBar["MenuBarExtra\n.window style"]
  App --> Descriptors["FetcherDescriptor registry"]
  App --> ConfigStore["ConfigStore\nconfig.json"]
  App --> LoginItem["LoginItemService\nSMAppService.mainApp"]
  App --> AppState["AppState\n@MainActor"]

  MenuBar --> MenuContentView["MenuContentView"]
  MenuContentView --> Harness["HarnessUsageMenuView\n(用量: 汇总/可折叠客户端)"]
  MenuContentView --> QuotaOverview["MenuQuotaOverviewView\n(额度: 有效额度/余额/套餐详情)"]
  MenuContentView --> AutoClose["MenuWindowAutoCloseBridge"]

  AppState --> Statuses["[ProviderStatus]"]
  AppState --> LoopA["循环 A: ProviderRefreshScheduler\n(单 Task 额度循环 / 最早截止时间休眠 / 并发隔离)"]
  AppState --> Reconcile["LocalUsage reconcile\n(Provider batch settled 后 / Full 或 dirty scan)"]
  AppState --> Prober["AuthProber\n(async 本地服务探测)"]
  AppState --> Watcher["ConfigStore.startWatching\nDispatchSource on config.json (file, not dir)\nevent-driven"]
  AppState --> Fetchers["QuotaFetcher implementations"]

  LoopA -. 并发抓取额度 .-> Fetchers
  Prober -. 本地认证探测 .-> Fetchers
  Reconcile -. 扫描本地账本 .-> Scanners["Local Scanners\n(Minimax / GLM / OpenCode / DSH / Antigravity / Agy / Codex)"]
  Scanners -. 各自 FSEvents 标记 dirty .-> Reconcile

  Fetchers --> Minimax["MinimaxTokenPlanFetcher"]
  Fetchers --> Codex["CodexFetcher"]
  Fetchers --> Antigravity["AntigravityFetcher"]
  Fetchers --> GLM["GlmCodingPlanFetcher"]
  Fetchers --> Deepseek["DeepseekFetcher"]

  Scanners --> Frames["usageFrameExtractors\n帧抽取 (L1)"]
  Frames --> Kernel["UsageProjectionKernel.project\n(L2 唯一生产调用点)"]
  ConfigBindings["内置 Harness → Provider 自动归因路由"] --> Kernel
  Kernel --> Projection["ProviderStatus.usageProjection"]
  Projection --> ProviderCard["ProviderCardView\n(dock / 菜单兜底行 hover)"]
  Projection --> Harness["HarnessTodaySummary\n(菜单 Harness 视角)"]
  Projection --> ClientsPane["ClientUsageAggregation\n(设置页 客户端)"]

  ConfigStore --> ConfigFile["~/Library/Application Support/\nLLM-monitor/config.json"]
  AppState --> LogFile["~/Library/Application Support/\nLLM-monitor/log.txt"]
```

## Startup Flow

1. `LLMMonitorApp.init()` acquires the per-user `instance.lock`; a second instance exits without touching shared state.
2. `LLMMonitorApp.init()` creates `ConfigStore`.
3. `ConfigStore` creates the app support directory if needed.
4. If `config.json` is missing, `ConfigStore.writeTemplate(to:)` writes the built-in template.
5. `ConfigStore` loads JSON into `AppConfig`; if an existing file cannot be decoded, it is backed up as `config.json.corrupt-*.json` before recovery continues with `.default`.
6. `LLMMonitorApp.makeDescriptors()` registers the built-in providers.
7. `ConfigStore.ensureProvidersPresent(descriptors:)` adds missing provider blocks without overwriting existing blocks.
8. `LoginItemService` snapshots the current launch-at-login status from `SMAppService.mainApp`.
9. `AppState` derives `ProviderStatus` values from descriptors plus config.
10. `AppState.start()` registers each enabled provider with usable auth in `ProviderRefreshScheduler` — a single long-lived Task that wakes on the earliest due date and runs due refreshes concurrently (no per-provider timer).
11. `AppState.start()` calls `ConfigStore.startWatching()`, which opens the **`config.json` file itself** via `open(O_EVTONLY)` and installs a `DispatchSource.makeFileSystemObjectSource` listener (`eventMask` = `.write / .delete / .rename / .revoke`) — config edits trigger a debounced, event-driven reload in milliseconds (no polling). Directory-level watching is deliberately avoided: `log.txt` and `last-refresh.json` sit in the same directory and would fire a reload on every log line and every timestamp write. An editor's atomic replace (delete + rename) reopens the fd on the old inode's death, and a briefly-missing file is retried with backoff.

The lifecycle delegate calls `AppState.stop()` during normal application termination
and triggers `AppState.handleSystemWake()` after `NSWorkspace.didWakeNotification` —
a merged protocol: the wake refresh joins the global refresh transaction (an external job
already in flight absorbs it as `pendingWakeup` instead of a second transaction) and does
**not** re-anchor per-provider schedules,
so sleep/wake does not leave quota cards stale until the next configured timer tick.
Sleep health is refreshed at startup and wake, and the same deadline driver also schedules
a five-minute health boundary, so newly acquired sleep assertions or AC power changes
are reflected without opening Settings or restarting the app.

## Provider State Machine

```swift
enum State {
    case notConfigured(reason: String)
    case ready
    case loading(lastSuccess: QuotaInfo?)        // 抓取中,lastSuccess 兜底
    case ok(QuotaInfo)                          // 抓取成功
    case failed(message: String, lastSuccess: QuotaInfo?)
}
```

`State` 自身持有"上次成功数据" —— `.loading(lastSuccess:)` / `.failed(_, lastSuccess:)`
/ `.ok(info)` 三种 case 都能从 `state.lastSuccess` 拿到 QuotaInfo?。**没有**单独的
`_lastSuccess` 字段（之前有过，跟 `.failed.lastSuccess` 重复存，迁 `.ok → .loading →
.ok/.failed` 任意一处忘记更新就会让 UI 跟 `healthLevel` 不一致，已删）。

State derivation is descriptor-driven:

| Situation | State |
|---|---|
| Provider block missing from config | `.notConfigured("未在 config.json 中配置")` |
| `enabled == false` | `.notConfigured("已在 config.json 中禁用")` |
| API-key provider has empty/template key | `.notConfigured("API Key 未填写")` |
| External-auth provider has no local auth file | `.notConfigured("外部 auth 缺失：...")` |
| Antigravity local session missing | `.notConfigured("请先启动 Antigravity 并完成登录")` |
| Config and auth are present | `.ready` |
| Fetch in progress | `.loading(lastSuccess: prev)` |
| Fetch succeeds | `.ok(info)` |
| Fetch fails | `.failed(message, lastSuccess: prev)` |

`rebuildStatuses` 在 config 变更时被调用。如果 deriveState 返回 `.ready`（auth 还 ok），
旧 status 的 `.ok/.loading/.failed` 状态会**整体复用**（auth 没变就不擦数据）；
deriveState 返回 `.notConfigured` 时整个 state 重置，lastSuccess 跟着清。

`rebuildStatuses()` preserves the entire `State` (`.ok/.loading/.failed`) by provider id when auth is still valid (derived is `.ready`), so config reloads do not erase the last successful snapshot. When auth becomes invalid (derived is `.notConfigured`), state resets to `.notConfigured` and the QuotaInfo data is dropped.

## Refresh Behavior

所有 enabled provider 由单一 `ProviderRefreshScheduler` Task 统一调度（无 per-provider timer）：

1. 注册时立即调用 `refreshHandler(providerID, .full)` → AppState 的 `refreshProviderDirectly`
2. 每次唤醒取"最早到期时刻"，到期的 provider 用 TaskGroup 并发刷新（首轮 `.full`，后续轮询用 `.background` mode）
3. 成功后按 `providers.<id>.refreshIntervalSeconds ?? refreshIntervalSeconds` 计算下次到期
4. 失败按同一个 baseInterval 固定间隔随下一定时周期重试（不做指数退避：后台固定间隔刷新下，拉长重试间隔只会推迟恢复）
5. 任务被 cancel → 退出循环

**配置重载 ≠ 冷启动**：配置写盘（设置页保存、dock 拖拽落点 App 自写 config、auth 探测翻转）触发的重排走 `ProviderRefreshScheduler.reconfigure(managed:)` 差异化路径——仍启用且 interval 未变的 provider 原样保留既有 deadline 与首刷标记（下一拍继续 `.background`），只有新增 / 重新启用 / interval 变化的 provider 才按初始排期立即纳入；冷启动语义只属于 `AppState.start()`。

**次要信息频率（周期 full）**：`periodicFullEveryN`（默认 20，用户范围 1...30，动态热重载）表示次要信息周期相对 Provider 有效刷新间隔的真实倍率。`ProviderRefreshScheduler` 首拍 `.full`，随后 N-1 次 `.background` 后下一拍 `.full`，N=1 时每拍 `.full`；实际预计周期为 `N × Provider 间隔`，默认 300s × 20 ≈ 100min，仍走常规 deadline。内部直接注入 0 保留“只靠启动/手动 full”的兼容语义。

次要信息包含 Codex reset credits、GLM ZCode 重置卡与营销活动（需通知开启）、Antigravity 独立账号/套餐 RPC，以及 costs 缺少组织名时 Codex `/v1/me` 查询。`.background` 同样获取主额度/余额、启用后的 Codex Admin API 赠金与 GLM 活动套餐余额；同一主响应附带元数据及 Codex 本地鉴权文件内的邮箱/套餐随主流程更新，不额外请求。Antigravity 跳过的账号与套餐、Codex 后台缺少的组织名由对应 merger 保留，额度金额与其新鲜度仍用本次结果。本地用量在批次结算后独立 reconcile，高峰提示和倒计时走本地时钟。完整范围见 `config.md` §次要信息频率。

scheduler 集中持有排期与 in-flight 状态：`nextRefreshDates` / `resetCandidates` +
`lastIntervalFinishedDates`（mid-cycle reset 点）/ `inFlightModes` / `inFlightWaiters` 等。
in-flight dedup：`markInFlight(providerID)` 返回 false 时直接 `.deferred`（已被 timer /
manual / menu-open 任一路径占住）。手动 full refresh 若遇到 background 请求，会通过
`waitUntilNotInFlight` 等待；该等待支持 cancellation，取消时会移除带 UUID 的 waiter，
不会留下悬挂 continuation。多个 full refresh waiter 由 `ManualRefreshGate` 的
`pendingFullRefreshIDs`（`Services/ManualRefreshGate.swift`，AppState 侧而非 scheduler 侧）
做一次性 claim，当前 background 请求完成后最多补跑一次 full refresh。
成功与失败都直接按 baseInterval 写入 `nextRefreshDates`。
UI 通过 `earliestNextRefresh` 拿到所有 provider 中最早的下次触发时间，pub 到 `nextRefreshAt`。

`AppState.refreshProviderDirectly` 是 scheduler 的 refreshHandler 闭包：
1. 入口 `markInFlight` dedup，失败 `.deferred` 退出
2. fetch + 应用到 `statuses[idx]` + 通知 `statusDidChange` 广播
3. `defer { markNotInFlight }` 在 `await` 路径任何退出都执行
4. 失败时只记录 `.failed` 状态 + antigravity 走 `AuthProber.scheduleProbe` 重新探测（排期仍按 baseInterval）
5. config 变更时 generation mismatch 直接丢弃旧结果

The `effectiveRefreshInterval(for:)` helper clamps the interval to `10s...30d` to prevent
busy loops from typos (`0` or negative) and integer-conversion overflow from extreme values
in `config.json`.

Manual refresh paths:

| UI action | Method |
|---|---|
| Header refresh button | `AppState.refreshAll()` |
| Provider card quota timestamp（标题行胶囊，menu hover / dock popover） | `AppState.refreshOne(providerID:)` — 只刷该 provider 的额度 |
| Provider card usage timestamp（段3 标题行） | `AppState.triggerLocalUsageRescan()` — 只重扫本地用量，不发额度请求 |
| Provider strip left click | `AppState.refreshOne(providerID:)` |
| Section header right-click 「刷新 <客户端名>」 | sequential `AppState.refreshOne` over the section's contributed providers (`HarnessSection.refreshProviderStatusIDs`) |
| Menu open with any `.ready` provider | `MenuContentView.onAppear` triggers `refreshAll()` |
| Right-click menu bar icon 刷新 | `MenuBarRightClickHandler.refreshClicked`；同一菜单的「配置」项（`configClicked`）经 `AppState.openConfigFile()` 用默认编辑器打开 `config.json` |

`refreshAll()` starts one child task per refreshable provider. `ProviderRefreshScheduler.markInFlight`
deduplicates so timer + manual + menu-open fire on the same provider collapse to a
single in-flight request. Status mutations remain on the main actor; network waits are
asynchronous.

Config reload path:

1. `ConfigStore.startWatching()` opens the `config.json` **file** and installs a
   `DispatchSource.makeFileSystemObjectSource` listener; the only callers are
   `AppState.start()`（启动）与 `AppState.rescheduleAll()`（配置重载路径上的幂等重申——
   watcher 本来就在跑，不构成第二个装载点）。
2. Each event first schedules a 250 ms debounce, then reads the file on a detached
   utility task and calls `configStore.hasChangedSinceLastRead(using:)`; an
   unchanged fingerprint short-circuits without parsing.
3. If parsing succeeds, `ConfigStore` publishes the new config, AppState
   increments `configurationGeneration`, statuses rebuild, and all provider timers
   reschedule.
4. In-flight fetches captured the *previous* `configurationGeneration`; when they
   complete, the captured value is compared and stale results are dropped.
5. If parsing fails during reload, `ConfigStore` keeps the previous config.

## Per-Provider Result Merge

每个 fetcher 自带 `resultMerger: RefreshResultMerger` —— policy 跟 fetcher domain knowledge
放一起，AppState 不再写 `if kind == .minimaxTokenPlan { ... }` 之类的分支：

| Fetcher | Merger | Behavior |
|---|---|---|
| `MinimaxTokenPlanFetcher` | `IdentityRefreshResultMerger`（默认） | 直接用新值。历史上的 `MinimaxVideoPreservingMerger`（`.background` 模式沿用上次 video 条目）已删除 |
| `CodexFetcher` | `CodexFillingMissingMerger` | `resetCredits` / `codexUsageDetails` 缺失时回退到上次；reset credits 在 `.background` 跳过时保留原值与时间，`.full` 失败时标记「可能过期」，恢复成功清除。API 赠金独立记录新鲜度，失败保留旧值并标记「更新失败」。Admin-only 或主 quota 失败结果携带主额度错误，merger 保留 Plan 数据与时间；AppState 进入 `.failed(lastSuccess:)`，不推进成功时间或额度通知基线 |
| `GlmCodingPlanFetcher` | `GlmFillingMissingMerger` | `glmZcodePackage` 在凭证模式下跨模式合并：活动套餐余额与预告在接口缺失时回退保留上次成功数据；重置卡与运营活动在 `.background` 跳过时从上次快照继承，保证卡片展示与营销通知稳定 |
| `AntigravityFetcher` | `AntigravityFillingMissingMerger` | `.background` 保留 previous 的账号/套餐信息，主额度、抓取时间及其余字段用 new；`.full` 直接采用新结果（包括 nil），避免旧账号/套餐在新查询后残留。首次无 previous 直接采用 new |
| `DeepseekFetcher` | `IdentityRefreshResultMerger`（默认） | 直接用新值 |

`CodexFetcher`、`GlmCodingPlanFetcher` 与 `AntigravityFetcher` 自带专用 merger；其余走 `QuotaFetcher` 的默认实现。

AppState.fetch 成功后调 `fetcher.resultMerger.merge(new:previous:mode:)` 合成最终值。

## Auth Probing

Antigravity 是用本地 Antigravity / agy CLI 的 `language_server`，进程可能中途崩。
`AuthProber` 异步探测 `fetcher.checkLocalAuth()` 并缓存结果：

- `scheduleProbe(for: providerID)`：启动探测（fetcher.hasLocalAuth() false 时不发）
- `markAvailable(providerID)`：refresh 成功路径直接标记可用
- `isUnavailable(providerID)`：用于 `rebuildStatuses` 派生 `.notConfigured("请先启动 Antigravity...")`
- `reset()`：config 变更时清空 cache + 取消所有 in-flight
- `cancelAll()` / `cancel(providerID:)`：stop / schedule 同 provider 前的清理

`onChange` 回调在 cache 值变化时触发，AppState 收到 `false` 立刻 `rebuildStatuses + rescheduleAll`
让 UI 立即显示离线提示；`true` 不在 callback 里 rebuild（依赖下次 refresh 成功后的 markAvailable）。
函数名 `rescheduleAll` 是历史遗留（`AppState.swift` 顶部注释亦然），**语义已是「Refresh Behavior」
小节那条差异化重排**：auth 探测翻转与配置写盘同属一条路径，只重排新增 / 重新启用 /
interval 变化的 provider，未变者保留既有 deadline 与首刷标记，不做全员重抓。

## UI Event Broadcasting

`AppState.statusDidChange: PassthroughSubject<Void, Never>` 是统一的广播通道。
所有"改 statuses 数组"或"改 status[idx] 局部字段"的入口（`mutateStatus` / `rebuildStatuses` /
`setScanningState` / `apply*LocalUsage`）都 fire 一次，MenuBarExtra 上挂一个
`.onReceive(state.statusDidChange) { _ in }` 即可绕开 MenuBarExtra 的 view 缓存。

`mutateStatus(at:_:)` 用 "copy array → modify → assign once" 模式：
赋值触发 `@Published` willSet 自动 send `objectWillChange`，加上手动 `statusDidChange.send()`
走显式 publisher 通道，两路保险。之前是 `objectWillChange.send() + in-place mutation` +
3 个独立 PassthroughSubject（`antigravityUsageDidChange` / `minimaxUsageDidChange`），已合并。

多机联动（Fleet Sync）状态不走这条通道：`AppState.fleetDidChange` 是独立的
`PassthroughSubject<Void, Never>`，在 fleet 快照接受 / scope 变化时 fire，订阅方是
MenuContentView、MenuBarLabel、EdgeDockContentView 与 EdgeDockController（详见 `sync.md` §10）。
`statusDidChange` 仍是 quota / 本地用量状态唯一的广播通道，两套互不替代。

## Launch At Login

The Settings panel includes a launch-at-login toggle backed by `SMAppService.mainApp`. The menu footer's 自启 entry is **also a toggle button**（`FooterActionButton`，2026-10-24 起）：单击调 `LoginItemService.setEnabled`，状态由图标表达——已启用 `power`（实心电源）、未启用 `power.dotted`（虚线电源），标题只写「自启」二字、无 ✓/✗ 文字。UI 结构细节见 `ui/menu-and-cards.md` §Footer。

Behavior:

| Situation | UI text |
|---|---|
| Registered | `已开启开机自启动` |
| Not registered, app in `/Applications` | `可开启开机自启动` |
| Not registered, app outside `/Applications` | `建议放到 Applications 后再开启` |
| Registered but blocked by system approval | `需要在系统设置中批准登录项` |
| Service not found / unsupported runtime | `当前环境暂不支持开机自启动` |

Implementation notes:

- This works best from a packaged `.app`, especially when the bundle lives in `/Applications`.
- The toggle does not write to `config.json`; it talks directly to the system login-item service.
- Registration failures are shown in the Settings panel and written to `log.txt`.
- Settings refreshes the login-item service before initializing its draft, then subscribes
  to the published state. Actual state changes synchronize the draft; repeated unchanged
  state refreshes preserve local edits. An untouched draft uses the current service value
  at save time, so saving another field cannot undo a menu toggle. Save success or failure
  (including rollback) rebases the draft to the final actual state.

## Data Model

`QuotaInfo` is provider-neutral:

| Field | Meaning |
|---|---|
| `models` | One or more `ModelQuota` rows shown in the card |
| `resetCredits` | Optional ChatGPT/Codex reset-credit details |
| `planLabel` | Optional plan label, currently parsed from Codex `id_token` |
| `accountEmail` | Optional logged-in account. Only Antigravity provides it; other providers leave it nil (the card's Account Info row visibility is decided solely by `QuotaWindowAccountInfo.make`) |
| `codexUsageDetails` | Optional local 5h / weekly token summary for Codex |
| `balanceDetail` | Optional structured DeepSeek balance breakdown (`DeepseekBalanceDetail`); replaced the preformatted string that used to be stuffed into `accountEmail`. Always nil for other providers |
| `glmZcodePackage` | Optional GLM ZCode 活动套餐余额、预告、额度重置卡与营销活动快照（`GlmZcodePackageSnapshot`） |
| `openAIApiCredits` | Optional OpenAI API 赠金明细，包含独立成功时间与最近失败标记 |
| `mainQuotaError` / `openAIApiCreditsError` | Optional Codex 部分抓取错误；主额度失败由 AppState 写入 `.failed`，赠金失败由赠金行单独呈现 |
| `fetchedAt` | Successful fetch timestamp |

`ModelQuota` carries two quota windows:

| Window | Fields |
|---|---|
| 5-hour / interval | `intervalTotalCount`, `intervalUsageCount`, `intervalRemainingPercent`, `intervalStatus`, `intervalResetsAt`, `intervalWindowSeconds` (optional; ChatGPT/Codex 等动态窗口；minimax 5h 由 fetcher 按 `end_time` 反推段长：end 落 0 点 → 4h、其余边界 → 5h，video 恒 nil) |
| Weekly | `weeklyTotalCount`, `weeklyUsageCount`, `weeklyRemainingPercent`, `weeklyStatus`, `weeklyResetsAt`, `weeklyWindowSeconds` |

`intervalStatus` and `weeklyStatus` use the shared `QuotaWindowStatus` type:
`.present` means that the provider exposed the window, including an exhausted `0%` window;
`.absent` means that the window is missing or unavailable. Provider-specific raw status codes
are normalized at each fetcher boundary and must not leak into shared UI or health logic.

The current UI emphasizes reset time and remaining percent. Token totals are preserved in the model but are often `0` for percent-only APIs. Codex additionally computes local token usage summaries from `~/.codex/sessions` and `~/.codex/archived_sessions`.

### OpenCode merge data

`OpencodeLocalUsage` stores one `OpencodeProviderUsage` per OpenCode `providerID`.
Each slice contains today's `OpencodeDailyUsage`, seven local calendar days, a
tokenized assistant-message `roundCount`, and recent samples. The four card switches
are applied at the view-state boundary:

- off: keep the native/local card source unchanged;
- on: add the matching OpenCode slice field by field;
- samples: prefix OpenCode prompt IDs before concatenation so native and OpenCode
  turns cannot collide;
- ChatGPT: convert OpenCode uncached input plus cache read into Codex's complete
  `inputTokens` / `cachedInputTokens` representation before addition.

OpenCode rounds count tokenized assistant messages. Turns count distinct
`COALESCE(parentID, message.id)` values per day. The scanner pads the seven-day window
and rebases it after midnight even when the database fingerprint has not changed.

## Health Algorithm

Health is computed from remaining percent and remaining time fraction:

```swift
if percent <= 0 { return .critical }

guard let timeFraction else {
    if percent < criticalPercent { return .critical }
    if percent < warningPercent { return .warning }
    return .healthy
}

let t = min(max(timeFraction, 0.0), 1.0)
if t <= 0 { return .healthy } // 周期已耗尽或刚到点，只要有剩余额度即算健康（成功撑过周期）

// 分母 = 100% * 剩余时间百分比 (t)
if percent < criticalPercent * t { return .critical }
if percent < warningPercent * t { return .warning }
return .healthy
```

`ModelQuota.colorLevel` is the single source of truth for both health and progress-bar
colors. 统一周额度与 5h 短窗口/滚动窗口节奏标色算法：
分母 = `100% * 剩余时间百分比 (t)`，默认阈值 `warningPercent = 60.0`（60%）、`criticalPercent = 30.0`（30%），支持通过 `config.effectiveAlertThresholds`（`AlertThresholdConfig`）集中动态配置：
- Pacing ratio `< 30%`（即 `percent < criticalPercent * t`）：红色 `.critical`
- Pacing ratio `< 60%`（即 `percent < warningPercent * t`）：黄色 `.warning`
- Pacing ratio `≥ 60%`：绿色 `.healthy`
- 当 `t <= 0`（周期已耗尽或刚到重置时刻）：余量只要大于 0 即代表平稳撑过当前窗口，判为 `.healthy`。
- 当 `timeFraction == nil`（无窗口定义或重置时间缺失）：分母回退为基准 100%（`< 30%` 红色，`< 60%` 黄色，`>= 60%` 绿色）。
此规则彻底解决了“距离重置仅剩几分钟、剩余 15% 明明充裕却因绝对值低而误报红色”的假警报问题。三个 `healthLevel` 派生属性
（`ModelQuota.healthLevel` / `QuotaInfo.healthLevel` / `ProviderStatus.healthLevel`）
已于 2026-10-09 随死代码清理删除：生产消费面为零，跨 model 读数统一走
`aggregateHealthLevel`；`colorLevel` 与 `stateHasSuccessData` 不受影响。`stateHasSuccessData` helper 用来判断一个 state
是否带"上次成功数据"（`.ok/.loading/.failed` 都返回 true）。

| State | Health source |
|---|---|
| `.ok(info)` | `aggregateHealthLevel(at:)`——取聚合 model 集合（`QuotaInfo.aggregateQuotaModels(providerKind:)`）各 model 最差档，全空保守 `.critical` |
| `.loading(lastSuccess: prev)` | `aggregateHealthLevel(at:)`（同上；`prev` 为 nil 则 nil） |
| `.failed(_, let last)` | `aggregateHealthLevel(at:)`（同上；`last` 为 nil 则 nil） |
| `.ready` / `.notConfigured` | `nil`（UI 显示灰点，不归类为"健康"） |

`ProviderStatus.aggregateHealthLevel(at:)` 在 `glmPeakWindow` 命中 GLM 高峰时段时保底
`.warning`（红色优先于普通档位结论）；`QuotaInfo.aggregateHealthLevel(providerKind:isPeakPrice:)`
同步接收高峰倍率入参。阈值细节见 `providers/glm.md`。

`nil` 让 UI 端的状态胶囊用 secondary 灰色渲染，明确区分"没数据"和"有数据但健康"。菜单栏的 `iconDuo` 仪表盘会随额度指标与节能/睡眠健康度变化；`quotaLogo`（App 图标）是固定设计稿、不随健康度变化；标准 SF Symbol 样式则保留右下角状态点与刷新中的图标替换。卡片状态点和进度颜色同样反映健康度。

跨 model 的聚合读数不遍历全部 `activeModels`：`ProviderStatus.aggregateHealthLevel`、
`AppState.statusBarQuotaMetrics`（iconDuo 左右弧 / 中心扇形 / 底部三点）与
`EdgeDockProjection`（边缘窗圆环）统一读 `QuotaInfo.aggregateQuotaModels(providerKind:)`
—— `activeModels` 再排除 `ModelQuota.isExcludedFromQuotaAggregation(providerKind:)`
命中的 minimax `video`（视频生成）与 antigravity `claude_and_gpt_models`（Claude and
GPT models）/ `gemini_argon`（Gemini 4 Argon）。这些都是独立配额池，余量与主力模型水位无关，
2026-10 用户裁定不计入聚合；滤后为空回退 `activeModels`（排除只允许「少算」）。卡片逐 model
展示与通知管线（`QuotaEventDetector` 逐 model 窗口事件）不受影响。

状态栏双环（Icon Duo）与健康度圆点支持服务商小眼睛锚定（`statusBarPinnedProvider`）：
- 缺省或为 nil 时，`AppState.statusBarQuotaMetrics` 与 `systemHealthLevel(at:)` 综合所有已启用 Provider 计算全局非零最小值与健康度；
- 当 `statusBarPinnedProvider` 指定了有效的窗口服务商 ID，且该服务商在可见列表中已启用并持有有效额度数据时，状态栏双环指标与健康度圆点仅计算该服务商的数据；
- 若锚定的服务商被禁用、未配置凭据或尚无有效配额读数，系统自动回退到全 Provider 聚合，避免状态栏出现空白。

## Error And Fallback

On successful fetch:

- state becomes `.ok(info)` (info 自带 QuotaInfo = 之前的 _lastSuccess 角色)
- `lastRefreshedAt` becomes `info.fetchedAt`
- `lastRefreshAt` is set to `Date()`

On failed fetch:

- state becomes `.failed(message, lastSuccess: prev)` (prev 来自上一个 .ok 状态)
- the card shows the error in red
- if `lastSuccess` exists, the old quota is still displayed with reduced opacity

之前用单独的 `_lastSuccess` 字段跟 `.failed.lastSuccess` 重复存 —— 现在
`State` 自身持有 QuotaInfo，迁 `.ok → .loading → .ok/.failed` 不再需要双写。
- `lastRefreshAt` is still updated

Fetcher errors use `QuotaError`:

| Case | User-facing description |
|---|---|
| `missingAPIKey` | `未配置 API Key` |
| `invalidResponse` | `响应格式无效` |
| `httpError(status, body)` | `HTTP <status>: <first 200 chars>`（body 预览已自带 `HTTP <status>` 前缀时不重复拼接） |
| `responseTooLarge(limit, actual, redactedPath)` | `响应过大（上限 N bytes）：<redactedPath>` |
| `decodingError(message)` | `解析失败：<message>` |
| `networkError(message)` | `网络错误：<message>` |

`HTTPRequestLogSanitizer.networkErrorDescription` 对 ATS 拒绝映射为
`系统安全策略阻止了此 HTTP 连接`，对 `URLError.dataNotAllowed` 映射为
`网络访问被系统限制，请检查网络权限`；后者不能直接断言是本地网络授权拒绝。
文案不回显底层错误的 URL、userinfo、query 或 fragment；其他既有超时 / DNS /
连接错误分类保持不变。2026-10-25 工作区定向验证：`HTTPErrorSanitizerTests` 6 例通过；
打包脚本 `bash -n` 及临时 plist 的用途说明 / ATS 嵌套布尔校验通过，未在另一台机器验收。

Antigravity-specific note:

- The fetcher does not trust stale OAuth tokens in `state.vscdb`.
- It reuses the local authenticated Antigravity `language_server`, discovers its HTTPS port and CSRF token, and reads quota through local RPC endpoints.

## Provider Registration Contract

Adding a provider currently requires:

1. Add a `ProviderKind` case in `Models/ProviderStatus.swift`.
2. Add an `AccentColor` case (if it has a brand color) in the same file.
3. Decide whether `kind.usesExternalAuth` is `true` or `false`.
4. Implement `QuotaFetcher` in `Sources/LLM-monitor/Fetchers/`.
5. Return provider-neutral `QuotaInfo` from `fetch()`.
6. Register a `FetcherDescriptor` (id / displayName / kind / icon / accentColor /
   makeFetcher / settingsTabTitle / settingsTabSubtitle) in
   `LLMMonitorApp.makeDescriptors()`.
7. 在 `SettingsView.providerPane(for:)` 派发里加一个 `case`，写该 provider 的
   设置 UI（默认走"enabled toggle + 独立刷新间隔"通用模板，特殊字段
   如 API Key / authPath 在这里加）。
8. Add or update provider spec under `spec/providers/`.

`ConfigStore.ensureProvidersPresent()` will add a placeholder config block for the new descriptor at the next app start.

**如果新 provider 有本地用量 scanner**（参考 `MinimaxLocalUsageScanner` /
`AntigravityLocalUsageScanner`），额外步骤：

9. 写一个 `XxxLocalUsage: Equatable, Codable, Sendable` 聚合 model（参考
   `MinimaxLocalUsage`），**自定义 `==` 排除 `scannedAt`**（每次扫描都是新 `Date`，
   默认 Equatable 让 no-op 检查形同虚设，触发无意义 UI reload + log spam）。
10. 写一个 `XxxLocalUsageScanner: ObservableObject, LocalUsageScanner<XxxLocalUsage>`
    实现（参考 `MinimaxLocalUsageScanner`），用 `AsyncMutex` + `lastCommittedGeneration`
    串行化 cache 写（防 cache revert）。`LocalUsageScanRunner.run` 抽走了
    lifecycle boilerplate，scanner 只实现 work + defer 块。
11. 在 `Services/LocalUsageOrchestration.swift` 加一个 `lazy var xxxCoordinator = LocalUsageCoordinator<XxxLocalUsage>(...)`
    （参考 `antigravityCoordinator`），`AppState.localUsage` 会随该结构自动携带。apply 闭包走
    `applyLocalUsage<T: Equatable>(kind:field:...)` 通用函数；具名薄 wrapper（一行委托通用
    函数，见 `Services/AppState+LocalUsage.swift` 的 `applyAntigravityLocalUsage` :7 /
    `applyMinimaxLocalUsage` :33 / `applyGlmLocalUsage` :52 / 通用 `applyLocalUsage` :140）
    是允许的现状形态——不要再写第二套完整镜像实现。（`AppState.swift` 已拆出
    `+LocalUsage` / `+Metrics` / `+Rebuild` 三个同类型 extension，本地用量入口全部在
    `+LocalUsage`。）
12. 本地用量扫描由 `ProviderRefreshScheduler` 的 `onBatchSettled` 驱动：每批 Provider
    请求全部返回后（不论成功/失败）投递一次 `LocalUsageOrchestration` reconcile。
    **reconcile 每拍都跑**，不是只在 FSEvents 报 dirty 时才跑：常规档是 `.full`
    （cache-assisted），由各 scanner 自己的 fingerprint 决定复用缓存还是真扫；
    `.hardFull`（绕过 fingerprint / offset / cache）只在启动首拍、日历签名失效
    （`LocalUsageCalendarSignature`）和 `bypassesProviderCache` 时触发。请求按
    `dirty < full < hardFull` 折叠，FSEvents / vnode dirty 只是把该拍标成 `.dirty`
    的一个来源。即使 Provider 全部禁用，调度器也会完成一次空 pass，保证首次扫描
    仍能拿到 Provider 流程产出的窗口输入。新客户端需要在自己的 scanner 内注册
    watcher，并在 `LocalUsageOrchestration.checkClientReadiness` 登记数据源就绪判断。

**已落地案例**：`DeepSeek` 完整走上述 1–8 步（无本地用量 scanner，跳过 9–12），
且是唯一一个 **post-fetch 无副作用** 的 provider（`refreshProviderDirectly` 的
kind 派发链里没有 `.deepseek` 分支）。它的高峰窗口为北京时间周一至周五 9–12 / 14–18
（`DeepseekPeakWindow.defaultWindow`），时段固定不可调；高峰永不含周末，周六、周日
全天平价。详见 [`spec/providers/deepseek.md`](providers/deepseek.md)。

Lookup pattern in the rest of the code:

```swift
descriptors.first(where: { $0.kind == .newProvider })?.id
```

**Runtime single source of truth.** AppState and SettingsView both look up the id
through this path. Two known edges (intentional, not bugs):

1. `ConfigStore.writeTemplate` is a `static` function called before `descriptors`
   is available, so the bootstrap `config.json` template has hardcoded
   `providers.<id>` segments. The runtime `ensureProvidersPresent(descriptors:)`
   follows the descriptor path correctly.
2. `QuotaFetcher.providerID` is a stored property on the fetcher itself, used for
   log tags and self-identification. It is the same string as the descriptor id,
   but stored locally because the fetcher is a `Sendable` value that may be used
   independently of the registry.

**SettingsView 派生 tab**（不是硬编码）：`SettingsTab` 是 `.general` / `.interface` / `.notifications` / `.energy` / `.sync` /
`.provider(FetcherDescriptor)` / `.client(ClientDescriptor)` / `.clients` 的 enum。
`SettingsView` 将侧栏划分为三个原生 Section：
- 通用 (`generalTabs`: `[.general, .interface, .notifications, .energy, .sync]`)
- 额度 (`providerTabs`: `sortedProviderDescriptors.map { .provider($0) }`)
- 用量 (`clientTabs`: `sortedClientDescriptors.map { .client($0) }`)
`allTabs` 为三者拼接。侧栏 icon / 标题 / 副标题从 descriptor 拿，**新增 provider 或 client
不用改 `SettingsTab` 枚举本身**。同名条目（如 Antigravity 额度 vs 用量）通过前缀 `client.<id>`
彻底隔离 ID。`providerPane(for: ProviderKind)` 与 `clientPane(for: ClientDescriptor)` 分别派发到对应详情。
`SettingsPaneHeader` 也走同一个 `SettingsTab`，不再 hardcoded icon / title。

## Current Design Boundaries

These are documented product boundaries:

- Local usage scanners restore their last-good `index.json` snapshot on cold start; the
  remote quota refresh timestamp is persisted separately in `last-refresh.json`.

菜单栏图标样式（`chart.bar.fill` / `quotaLogo` / `iconDuo`）与菜单 70% 高度上限的产品边界已并入 `ui/menu-and-cards.md`（§Menu Bar Item / §Window Structure）。

- The local-usage day bucket is now **two structs, not N**: `LocalDailyTokenUsage`
  (`Models/LocalDailyTokenUsage.swift`) is the single shared implementation, and
  `AntigravityDailyUsage` / `MinimaxDailyUsage` / `GlmDailyUsage` /
  `OpencodeDailyUsage` / `DshDailyUsage` / `AgyDailyUsage` are `typealias`es of it;
  `DailyTokenUsage` (`Models/QuotaInfo.swift`) is the only other struct, kept for
  Codex's on-disk JSON key compatibility. Both conform to `LocalUsageDaily`, so view
  code is generic over the protocol while the per-source fields stay where they are.
  This counts **2 chart data types**, not 2 scanners: OpenCode / DSH / GLM-ZCode
  have their own SQLite readers, Antigravity is pure RPC, and Codex parses JSONL on
  demand for the 7-day chart.

> 核对基线：2026-11-03 · 代码 4c646e9
> 2026-10-25 自启草稿与菜单实际状态同步已随 6f11831 入库：定向 27 例、完整 1422 例均通过；完整验证记录见 `spec/sync.md`。
