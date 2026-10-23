# 多机联动设计（Fleet Sync）— 2.0 大版本

> 状态：设计稿（未实现）。实现完成后应毕业为 `spec/sync.md`，并在 `spec/overview.md` §Spec 地图与任务路由 登记入口。
> 基线代码：`main` @ `bd26c3a` / 分支 `2.0.0`。
> 本次修订：2026-10-24，落实 UUID、独立同步表及副节点自报窗口范围的决定；同日裁定 §13.2-M（额度候选按 `fetchedAt`）并确认 §13.2-W（窗口范围技术默认），§13.2 已无待确认项。
> 口径：**多副一主**，不级联。每个实例对自己本机数据永远有权威解释权。

---

## 1. 需求原文拆解

> 每个实例在本机上跑都是将自己作为主节点。如果配置了上级主节点的话，会将自己当天的完整数据定期发给主节点，并且获取主节点合并后的全局数据。不考虑级联多级主节点的形式，但需要考虑多副一主的形式。

拆成五条可实现的规则：

| # | 原文 | 实现规则 |
|---|---|---|
| R1 | 每个实例将自己作为主节点 | 角色由 `sync.hubURL` 派生：无 upstream 的 hub 接收并合并副节点报告；有 upstream 的 node 只向该 hub 上报并消费回传快照，不转发报告、不监听端口。 |
| R2 | 定期发送当天完整数据 | 报告携带今天及前六天日桶；用量来源有效且七个 authoritative totals 均 complete 才整体替换日桶。模型明细完整度独立，可不完整并明确标记。窗口摘要按范围独立 upsert，缺失范围不会删除保留期内的既有范围。额度与心跳通道可独立更新。 |
| R3 | 获取主节点合并后的全局数据 | 同一次往返返回经 `hubUUID + generation` 标记的全局快照；副节点仅接受已验证 hub 且 generation 更新的快照。 |
| R4 | 不级联、多副一主 | node 不转发任何上游/其他节点数据；拓扑严格两层。 |
| **R5** | **用户裁定额度上报与优先级** | hub 本机有效额度优先，否则从副节点有效额度选一份；各 node 本机有效 `lastSuccess` 优先，否则采用 elected。候选排序按 `fetchedAt`（2026-10-24 已裁定）。 |

---

## 2. 四个必须先定的设计裁决

### 2.1 额度：选主，不合并

**用户裁定（2026-10-23）：副节点上报额度；主节点自己有有效额度就以自己为准，没有则用副节点上报中的有效额度。** 额度不相加，只选择一个来源。

- 有效快照：`QuotaInfo` 存在且至少一个 model 的 `hasActiveQuotaWindow` 为 true。该判定包含 0% 已耗尽窗口；DeepSeek 的余额模型以 present interval 表示余额快照，所以余额为 0 也有效。它仍不因此获得窗口通知语义：通知由 `ProviderKind.windowedKinds` 单独门控。
- 旧数据仍有效：本机存在有效 `lastSuccess` 时继续优先，即使本机最近一次抓取失败或数据已旧；副节点额度的年龄用于 UI 标 stale，不直接淘汰候选。
- 节点自身的生效额度：`localEffectiveQuota ?? fleetElectedQuota`。本机 disabled / 未配置而没有 `lastSuccess` 时可回退到 elected；本机 failed 但仍有有效 `lastSuccess` 时仍用本机，并同时显示本机需重试。
- fleet 选举：hub 有有效本机额度就选 hub；否则从副节点有效快照中选一个来源。用户尚未裁定候选排序依据。

选举结果必须带 `sourceNodeID` / `sourceNodeName`，UI 依据当前节点 ID 判断是否为本机来源。协议不传含义含混的 `isLocal` / `sourceIsLocal` 字段（§5.5 / §10.3）。

**候选排序（2026-10-24 已裁定按 `fetchedAt`）：** 按 hub 收到报告的 `receivedAt` 排序的问题是周期重报可能让一台额度陈旧但「刚上报」的机器胜出；`fetchedAt` 始终偏向额度更新鲜的来源。

额度来自某一节点的账号，不代表 fleet 所有账号的余额。v1 多账号语义推迟；来源标签与 stale 标记仍必须显示，避免读者把单账号余量误当作所有机器的合计。

### 2.2 计价在哪一侧发生

**各节点算自己的金额，hub 只做币种内的加法。**

理由是本仓库的一条硬纪律：token 数与金额必须落在**同一批样本**上（`LocalUsageSummaryBuilder.windowSamples` 就是为此而存在）。DeepSeek 高峰 ×2 是**逐样本按时刻**判的，hub 拿到日聚合后再计价就会引入第二套计价路径，两边的「这批 token 值多少钱」会悄悄对不上。

所以：

- 副节点用**自己本地的** `ModelPricing.json` + 自己的节假日表算出每行的原币金额，随报告一起发。
- hub 按**币种**分别求和（`MixedCurrencyEstimate` 已有 USD→CNY ×7 折算），产出全局金额。
- hub 把**自己的**金额也加进去，于是**所有节点看到的全局数字是同一份**（hub 是唯一裁决点）。
- 代价：某台副节点的价目表版本偏旧，它那份贡献金额会略偏——所以 UI 必须能**逐节点展开**看到每台机自己的金额，问题立刻可见，而不是被全局总数掩盖。

> 反过来做（hub 用自己的价目表重算全 fleet）会引入第二套计价路径，且需要按样本时刻判峰——hub 手里只有日聚合，做不到。

### 2.3 时区：单时区前提

**用户裁定（2026-10-23）：不需要支持跨时区节点。**

于是设计简化为一条**硬前提**：

> **所有节点假定在同一时区。** `dayKey`（`yyyy-MM-dd`）在全体节点间语义一致，hub 不做任何日界换算。

实现上：

- wire 里**保留** `timezoneID` 字段，但只作**诊断元数据**——某台机器时区配错了，设置页能看出来。不据此产生任何告警或换算分支（没有跨时区代码路径，也就没有跨时区 bug）。
- `dayStartUTC` / `utcOffsetSeconds` 一并去掉：`dayKey` 在单时区前提下已经唯一确定「今天」，再带 UTC 锚点是冗余。
- **协议契约里写死**：副节点与主节点时区不一致时，属于**配置错误**，主节点在设置页标红提示，但不尝试修正数据。

> 如果将来真要支持跨时区，协议里预留的扩展路径是：entries 升级成小时桶（24 份/天，带 UTC 小时起点），主节点按自己的日界重切。`dayKey` 与小时桶的对应关系在 §5.1 的 schema 里已经能看出来。真到那一步再改协议 v2，不影响 v1 的部署。

### 2.4 用量归属：各节点各自裁决，hub 只做加法

**这一节要定的不是「谁来裁决归属」——而是「各机归因设置不一致时，全局数字怎么解释」。**

#### 归属是怎么来的（三段代码，不用回忆实现细节）

「某段用量算在哪个 provider 名下」由**设置里的「客户端 × Provider 归因」开关**（`clientBindings`）决定，事实源是 `Models/ClientIdentity.swift:63-135` 的 `ClientProviderBinding.defaultBindings`。

但**大多数数据源不受这个开关影响**——它们自己在数据里就声明了归属：

| 来源 | 帧里声明的归属 | 代码位置 |
|---|---|---|
| Codex | openAI | `Models/UsageFrameExtractors.swift:47-52` |
| Antigravity / agy | antigravity | `Models/UsageFrameExtractors.swift:62-67` / `:78-83` |
| MiniMax Code | minimax | `Models/UsageFrameExtractors.swift:93-98` |
| ZCode 原生 GLM | zhipu | `Models/UsageFrameExtractors.swift:108-113` |
| OpenCode / ZCode 切片 | 该切片所属 provider | `Models/UsageFrameExtractors.swift:140-146` / `:165-171` |

**只有 DSH 例外。** DSH 是一份「一个账本里路由到多个 provider」的 session 账本，它的帧**故意留空归属**（`Models/UsageProjectionKernel.swift:360-369`，第 363 行写死 `quotaProviderID: ""`），归属由内核拿**本机**的 `clientBindings` 去匹配（`Models/UsageProjectionKernel.swift:272-287`）。

匹配不上 → 落成空串组 → 被 `ProviderStatus.usageProjection` 的 `ownQuotaProjections` 过滤掉（`Models/ProviderClientModel.swift:336-338`）→ **这段用量在任何卡片、任何菜单里都看不见**。

（OpenCode / ZCode 切片更直接：抽取器自己就用 `isClientBindingEnabled` 门控，绑定关掉 → 帧根本不产生，`Models/UsageFrameExtractors.swift:135-138` / `:160-163`。）

#### 所以只有两种情形

| 情形 | 结果 |
|---|---|
| 各机设置一致（**默认情况**） | 绑定表是随 App 分发的同一份，归属天然一致 → **没有任何问题**，全局数字精确 |
| 某台机器被手动改过 | 那台机器的 DSH 用量要么进了另一个 provider 桶，要么（绑定关掉）整段不存在 |

> **「手动改过」在 v1 几乎不可能发生——设置页根本没有归因开关。**
> `Views/SettingsView.swift:283-286` 明写「OpenCode merge 状态不再进入设置表单：设置页没有独立 Toggle，`clientBindings[]` 是唯一事实源」；`AppConfig.setClientBindingEnabled`（`Models/AppConfig.swift:424`）**只有测试在调用，Views 里零调用**。
> 所以分歧的唯一来源是**手工编辑 `config.json`**（或 schema v1 以下的 legacy 迁移）。
> 而 `config.json` 通常会跟着 dotfile 同步到多台机器——§6.2 之所以把 `nodeID` 排除在 `config.json` 之外，正是因为「它是机器身份，不是用户设置，不该跟着 dotfile 同步」。**归因设置反而是会跟着同步的那一类**，于是各机天然一致。
>
> 结论：**这不是一个需要在协议里解决的问题**，它只是一个几乎不会触发的边角。§7.8 的指纹是它的保险，不是它的解药。

#### 裁定（2026-10-23）：各节点各自裁决，hub 不重裁

> **全局日用量 = hub 已接收的各节点同日权威合计之和；离线或缺报状态必须同时展示。**
> wire 里的 `quotaProviderID` 就是**节点自己解析好的归属**，hub 原样收下、只做加法。

理由：

1. **不引入第二套归属口径。** 仓库的硬纪律是「一个数值只允许一处算」。归属已经由 `UsageProjectionKernel` 在节点侧算完；hub 再按自己的 bindings 重裁一遍就是第二套口径，将来必然漂移。
   → **和额度不一样**：额度是**选一个来源**，必须有人选，所以额度归 hub 裁决（§2.1）；用量是**求和**，每份贡献各自成立，不需要人选。
2. **不新增归属裁决。** 不需要「未门控投影口径」、wire 不新增归属字段（只多一个用于检测的指纹，§5.5）。
3. **可核对。** 「全局 = 各机本地之和」这个语义，用户拿每台机器的菜单数字就能对账。
4. **不一致时提示，不阻断。** 副节点上报时带上本机归因设置指纹 `attributionFingerprint`；hub 发现 fleet 内指纹不一致就在设置页提示「归因设置不一致，全局数字为各机口径之和」（§7.8）。**这不是错误**，是用户的本地配置选择。

**代价（明说）：** 同一类用量可能被拆到两个 provider 桶——机器 A 把 OpenCode 归到 GLM、机器 B 归到 MiniMax，全局里就是两行。这是**正确**的：每台机器的归因对它自己的数据都对，且 UI 能逐节点展开看到（§10.1）。

#### 重复计数边界

用量来源来自本机账本、文件和本机 RPC；hub 不会按账号额度重算。但同一物理数据若被复制到不同节点，或用户强制换 UUID 后旧 nodeID 与新 nodeID 同时保留，hub 会把它们视为不同节点并相加。因此不能承诺跨机永不重复；节点清理与同目录同步造成的重复属于可见运维风险，协议不做内容级去重。

---

## 3. 拓扑与角色

```
                    ┌─────────────────────────────┐
                    │  主节点 hub（无 upstream）     │
                    │  ├── 本机用量（权威）           │
                    │  ├── HubServer :8787          │
                    │  └── FleetSnapshot（含自己）    │
                    └───────────┬──────────────────┘
                                │  POST /v1/usage/day  （单向，副 → 主）
              ┌─────────────────┼─────────────────┐
              ▼                 ▼                 ▼
        ┌──────────┐      ┌──────────┐      ┌──────────┐
        │ 副 node A │      │ 副 node B │      │ 副 node C │
        │ 本机用量   │      │ 本机用量   │      │ 本机用量   │
        │ 不监听端口 │      │ 不监听端口 │      │ 不监听端口 │
        └──────────┘      └──────────┘      └──────────┘
```

**不变量（写进代码断言）：**

1. 副节点**不创建** `NWListener`。角色判定与 server 启动在同一个 switch 分支里，不存在「既监听又上报」的可能。
2. hub **从不主动连副节点**。拓扑单向，hub 的攻击面只有「监听一个端口」。
3. 任一节点的本地显示**永不依赖网络**。hub 挂了、副节点全挂了，本地用量照常显示。

**角色派生的单一来源**（`SyncRole`）：

```swift
enum SyncRole: Equatable {
    /// 无 upstream → 主节点
    case hub
    /// 有 upstream → 副节点
    case node
    /// sync 未启用 → 不参与
    case off

    static func derive(config: AppConfig) -> SyncRole {
        guard config.sync?.enabled == true else { return .off }
        let upstream = config.sync?.hubURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (upstream?.isEmpty == false) ? .node : .hub
    }
}
```

---

## 4. 传输协议

### 4.1 选型

| 项 | 选择 | 理由 |
|---|---|---|
| 协议 | HTTP/1.1 子集 | 可用 `curl` 直接调试；副节点侧复用仓库已有的 `HTTPClient`（超时、状态码、脱敏日志、响应体硬上限全都现成） |
| 服务端实现 | `Network.framework` 的 `NWListener` | **不引入任何外部依赖**——`Package.swift` 目前是零依赖，Network.framework 是系统框架 |
| 端口 | 默认 `8787` | 可配置 |
| 绑定 | 默认 `0.0.0.0`（局域网） | 副节点要能跨机访问；主节点设置页可改 `127.0.0.1` 限定本机 |
| 传输加密 | 无。v1 就是明文 HTTP | 用户已裁定：先不处理，需要时再加（§9） |
| 认证 | **无** | 同上。预留了三个缝，将来加认证改动极小（§9.2） |

### 4.2 端点

| 方法 | 路径 | 请求 | 响应 |
|---|---|---|---|
| `POST` | `/v1/usage/day` | `NodeUsageReport`（JSON） | `FleetSnapshot`（JSON）——**推 + 取一次往返** |
| `GET` | `/v1/usage/day` | 无 | `FleetSnapshot`——push 失败时的兜底拉取 |
| `GET` | `/v1/health` | 无 | `{"ok":true,"nodeID":"...","protocolVersion":1}`——探活 |
| — | 其它 | — | `404` |

副节点侧只需填 `http://<主节点IP>:8787`，路径是固定常量。

服务端只支持 HTTP/1.1 的最小子集：`Content-Length` 必填（不支持 chunked）、`Connection: close`（每请求一条连接，不做 keep-alive）、请求体上限 **4 MiB**、响应体上限 **2 MiB**（超出即 `413` / 截断报错）。

### 4.3 服务端实现要点（`HubServer.swift`）

`NWListener` 收到连接后自行解析 HTTP：`请求行 → 头 → Content-Length 定长 body`。要点：

- **先读头后读 body**，body 长度用 `Content-Length`，超过 4 MiB 立即 `413` 并断开（不等 body 读完）。
- **路径白名单**：不在 `/v1/usage/day` / `/v1/health` 里 → `404`。
- `Content-Type` 必须是 `application/json`，否则 `415`。
- **请求入口留一个认证缝**（§9.2）：解析完请求行与头、进业务逻辑之前的那一行，将来加校验就插在那里。
- **每节点限流**：同一 `nodeID` 的两次请求间隔 < 1s 直接 `429`。防止一个坏客户端打爆 hub。
- 所有请求在**独立 Task** 里处理，`NWListener` 的 accept 循环不阻塞。
- 请求日志只记 `method path nodeID status bytes`，**不记 body、不记 header**。

---

## 5. Wire 格式

### 5.1 副 → 主：`NodeUsageReport`

报告外壳以稳定 `nodeID` 和持久单调 `seq` 标识。`dailyBuckets` 是可选日用量通道：省略或 `null` 表示本次不更新；存在时必须包含今天及前六天，且七个 bucket 的 authoritative totals 均 complete 才替换。`modelDetailsComplete=false` 可接受并保留明细缺口标记。`windowUsage` 是可选窗口增量：省略或 `null` 表示无窗口更新，数组中每行按完整边界 upsert，空数组不删除保留期内的旧范围。`quotas` 同样可选；`null` 表示不更新额度，数组（可空）表示替换该节点额度集合。来源校验失败时不更新用量通道；daily totals 不完整时保留旧七日日桶。明细不完整不阻止 totals 更新。此处来源/完整性校验指同步 builder 的采集来源与覆盖证据，不是认证；v1 按用户裁定不提供身份认证。额度通道独立校验，可按验证结果更新额度、lastSeen 和 seq。

```jsonc
{
  "protocolVersion": 1,
  "node": {"nodeID":"3F2A9C14-...","nodeName":"MacBook-Pro","timezoneID":"Asia/Shanghai","platform":"macOS"},
  "seq": 42,
  "generatedAt": "2026-10-23T06:32:00Z",
  "attributionFingerprint": "9f2c41ab",
  "dailyBuckets": [
    {"dayKey":"2026-10-23","totals":{"input":1,"cacheRead":2,"output":3,"reasoning":4,"turns":5,"rounds":6},
     "clientProviders":[/* client × provider totals */],
     "entries":[/* FleetUsageEntry model detail */],
     "totalsComplete":true,"modelDetailsComplete":true,"sourceTruncated":false}
    /* 固定七个日桶：today + previous six */
  ],
  "windowUsage": [
    {"quotaProviderID":"openai","modelID":"chatgpt_plan","windowKind":"interval",
     "startAt":"2026-10-23T01:32:00Z","endAt":"2026-10-23T06:32:00Z","observedAt":"2026-10-23T06:32:00Z",
     "input":10,"cacheRead":20,"output":30,"reasoning":0,
     "value":0.12,"currency":"USD","coverage":"full","complete":true,"sourceTruncated":false}
  ],
  "quotas": [
    {"quotaProviderID":"openai","fetchedAt":"2026-10-23T06:32:00Z","models":[/* ModelQuota */],
     "resetCredits":null,"planLabel":"Plus","accountEmail":"user@example.com","balanceDetail":null}
  ]
}
```

日桶 totals 由同桶 clientProviders 的规范化计数汇总；接收时核对两者一致，不一致则跳过该日用量通道并提示报告错误。日合计是权威总量，不能从可能截断的 entries 反推；entries 完整度独立。金额必须与对应 token 来自同一样本集合。窗口键为 `quotaProviderID + modelID + windowKind + startAt + endAt`，时刻精确比较不舍入；hub 为每条独立摘要记录可信的最后观察时刻；GLM 闲时行使用 `windowKind = glmOffPeak`，仍须携带真实边界与同样本成本。

额度仅包含本节点具有有效 `lastSuccess` 的 provider；未配置或 disabled provider 不报本机额度。DTO 带 `balanceDetail`，裁掉与用量重复的 `codexUsageDetails`。

### 5.2 主 → 副：`FleetSnapshot`

```jsonc
{
  "protocolVersion":1,"hub":{"nodeID":"...","nodeName":"iMac","timezoneID":"Asia/Shanghai","platform":"macOS"},
  "hubUUID":"...","generation":104,"generatedAt":"2026-10-23T06:32:00Z",
  "nodes":[{"nodeID":"...","nodeName":"MacBook-Pro","lastSeenAt":"2026-10-23T06:32:00Z","seq":42,"stale":false,
             "dailyBuckets":[/* FleetDailyBucket[] */],"windowUsage":[/* 范围独立保存 */],"quotas":[/* FleetQuotaReport[] */]}],
  "fleet":{"dailyBuckets":[/* 合并的 FleetDailyBucket[] */],"windowUsage":[/* FleetWindowAggregate：同范围合并并列贡献节点 */]},
  "electedQuotas":[{"quotaProviderID":"openai","sourceNodeID":"...","sourceNodeName":"iMac",
                     "fetchedAt":"2026-10-23T06:32:00Z","models":[/* ModelQuota */],
                     "resetCredits":null,"planLabel":"Plus","accountEmail":"user@example.com","balanceDetail":null,"isStale":false}]
}
```

`generation` 在 hub 上任何可见状态变更时递增，包括接受额度/心跳更新、本机数据变化和 stale 状态变化；它须持久跨重启比较。node 仅缓存同一 `upstreamKey + hubUUID` 下更新的 generation。`fleet` 是 `FleetAggregate`，包含 dailyBuckets 与 windowUsage；节点来源由 nodeID 推导，不带 `isLocal`。

### 5.3 编码约定

| 约定 | 理由 |
|---|---|
| **时刻一律 ISO8601 字符串**（`"2026-10-23T06:32:00Z"`） | **与仓库既有落盘约定一致**：`ScannerIndexIO` / `LastRefreshStore` / `TriggerStateStore` 全部用 `encoder.dateEncodingStrategy = .iso8601`。且 `ModelQuota` 的 `intervalResetsAt` / `weeklyResetsAt` 是 `Date` 字段，整个 payload 只能有一套 date 策略——选 iso8601 就自动正确往返 |
| **日历日键用 `dayKey`（`yyyy-MM-dd` 字符串）** | 日键是**日历日**概念，不是时刻。全体节点同时区（§2.3），字符串形式可直接读、可直接当字典键、便于人肉核对账期 |
| 金额用 `Double` + 显式 `currency` 标记 | 与 `ModelCostEstimate.value`（Double）同型，转换零损耗；求和时走 `MixedCurrencyEstimate` 的 `Decimal` 路径 |
| `entries` 保留模型明细与计价字段；权威 totals / clientProviders 是独立汇总 | 报告 builder 需保持同样本口径；UI 不从模型明细反推权威合计，也不承诺与 `HarnessModelRow` 完全同构 |
| `quotas[].models` 直接用 `ModelQuota` 的 Codable 形状 | `ModelQuota` 已经是 `Codable`，复用即零漂移——UI 读的字段与 wire 传的字段是同一批 |
| `protocolVersion` 显式携带 | 主副版本不一致时 hub 返回明确错误而不是静默错解 |
| 未知字段忽略；已知字段类型不符 → 整包 400 | 宁可拒绝也不猜 |

> **实现约束（写代码时别漏）：** encoder / decoder 必须显式设 `dateEncodingStrategy = .iso8601` / `dateDecodingStrategy = .iso8601`。用默认策略的话 `Date` 会被编成 `timeIntervalSinceReferenceDate`（**2001 基准**的 Double），副节点与主节点若有一侧漏设就会解析出 1970 或 2001 附近的错误时刻——而这种错误**不报错**，只会让额度重置倒计时变成一个诡异的负数。
>
> 建议在 `SyncModels.swift` 里放一个**唯一**的编解码入口（`FleetCodec.encode/decode`），所有出网/入网的 JSON 都走它，策略只写一次。

### 5.4 体积（实测）

**在本机真实运行数据上量过**（`~/Library/Application Support/LLM-monitor/token-monitor/` 的 minimax + zcode 两家，2026-10-23）：

| 项 | 实测值 |
|---|---|
| 8 天窗口内原始样本 | 521 条 |
| 今日原始样本 | 487 条 |
| 今日模型级行（entries） | **2 行**（minimax/MiniMax-M3.1-Flash、zcode/GLM-5.3-Flash） |
| 今日 client×provider 行 | 2 行 |
| **聚合 wire payload（今日）** | **1,184 B** |
| 单个 entry 平均字节 | 197 B |
| 4 MiB body 上限能装下的 entry 数 | **23,301** |

**参考结论：当前单日日数据量很小；七日日桶与窗口摘要的总量仍需实现后实测。**

两个关键性质：

1. **体积取决于「模型多样性」，不取决于「活动量」。** 487 次调用压缩成 2 行——同一模型的所有调用塌成一行。行数上限是 `(client × provider × model)` 组合数，参照打包价目表也只有 23 个模型条目（`Resources/ModelPricing.json`），重度用户撑死几十到一百行 → **十几 KB**。
2. **额度部分可忽略**：每个 provider 一个 `QuotaInfo`（`models` 一般 1–5 个 `ModelQuota`）→ 1–5 KB。

**为什么必须是聚合，不能传原始样本**（这是硬约束，不是优化）：

| 传什么 | 本机今日实测 | 极端情况 |
|---|---|---|
| 聚合（entries） | **1.2 KB** | 几十行 → 十几 KB |
| 原始样本 | **131 KB**（聚合的 113 倍） | DSH 的 `recentSamples` 上限 **65,536 条**（`DshLocalUsageScanner.swift:18`）→ 单家就 **~10 MB** |

按历史上限估算，原始样本可超过请求上限，因此协议不上传它们。节点须在本地汇总时保留计数与金额的样本一致性；scanner 截尾带来的覆盖限制按 §6.3 标出。

快照响应：N 节点 × entries + N 个 electedQuotas。3 节点约 50 KB 量级，远低于 2 MiB 响应上限。推周期 60s → 流量可忽略。

---

### 5.5 精确 Schema（设计 DTO，尚未实现）

以下是协议草案的语义形状；实现时以 DTO 为准。用量、额度和同步来源分开表达，既有账本与本机缓存模型不增加 local/remote 字段。

```swift
struct FleetNodeIdentity: Codable, Sendable {
    let nodeID: UUID
    let nodeName: String
    let timezoneID: String
    let platform: String
}

enum FleetCostCoverage: String, Codable, Sendable { case none, partial, full }
struct FleetUsageEntry: Codable, Sendable {
    let clientID: String
    let quotaProviderID: String
    let modelName: String?
    let input, cacheRead, output, reasoning: Int
    let value: Double?
    let currency: ModelPriceCurrency?
    let coverage: FleetCostCoverage
    let truncated: Bool
}
struct FleetClientProviderUsage: Codable, Sendable {
    let clientID, quotaProviderID: String
    let input, cacheRead, output, reasoning, turns, rounds: Int
}
struct FleetTotals: Codable, Sendable {
    let input, cacheRead, output, reasoning, turns, rounds: Int
}
struct FleetDailyBucket: Codable, Sendable {
    let dayKey: String                 // today + previous six days
    let totals: FleetTotals                 // authoritative daily totals
    let clientProviders: [FleetClientProviderUsage]
    let entries: [FleetUsageEntry]     // model detail; completeness is separate
    let totalsComplete: Bool
    let modelDetailsComplete: Bool
    let sourceTruncated: Bool
}
struct FleetWindowUsage: Codable, Sendable {
    let quotaProviderID, modelID: String
    let windowKind: String             // interval, weekly, or provider-defined kind
    let startAt, endAt: Date           // observed actual boundaries; startAt < endAt
    let observedAt: Date               // hub receive time in snapshot; hub overwrites untrusted report value
    let input, cacheRead, output, reasoning: Int
    let value: Double?
    let currency: ModelPriceCurrency?
    let coverage: FleetCostCoverage
    let complete: Bool
    let sourceTruncated: Bool
}
struct FleetQuotaReport: Codable, Sendable {
    let quotaProviderID: String
    let fetchedAt: Date
    let models: [ModelQuota]
    let resetCredits: ResetCreditsInfo?
    let planLabel, accountEmail: String?
    let balanceDetail: DeepseekBalanceDetail?
}
struct NodeUsageReport: Codable, Sendable {
    let protocolVersion: Int
    let node: FleetNodeIdentity
    let seq: Int                      // monotonic per stable nodeID
    let generatedAt: Date
    let attributionFingerprint: String
    let dailyBuckets: [FleetDailyBucket]? // nil: no update; if present exactly seven
    let windowUsage: [FleetWindowUsage]?  // nil: no update; rows independently upsert
    let quotas: [FleetQuotaReport]?       // nil: no update; [] clears quota set
}
struct FleetNodeSnapshot: Codable, Sendable {
    let nodeID: UUID
    let nodeName: String
    let lastSeenAt: Date
    let seq: Int
    let stale: Bool
    let dailyBuckets: [FleetDailyBucket]
    let windowUsage: [FleetWindowUsage]
    let quotas: [FleetQuotaReport]
}
struct FleetElectedQuota: Codable, Sendable {
    let quotaProviderID: String
    let sourceNodeID: UUID
    let sourceNodeName: String
    let fetchedAt: Date
    let models: [ModelQuota]
    let resetCredits: ResetCreditsInfo?
    let planLabel, accountEmail: String?
    let balanceDetail: DeepseekBalanceDetail?
    let isStale: Bool
}
struct FleetWindowAggregate: Codable, Sendable {
    let quotaProviderID, modelID, windowKind: String
    let startAt, endAt: Date
    let input, cacheRead, output, reasoning: Int
    let valueByCurrency: [String: Double] // amounts remain separate by currency
    let coverage: FleetCostCoverage
    let complete: Bool
    let contributingNodeIDs, staleNodeIDs: [UUID]
    let missingNodeIDs: [UUID]          // known relevant nodes without this range
}
struct FleetAggregate: Codable, Sendable {
    let dailyBuckets: [FleetDailyBucket]
    let windowUsage: [FleetWindowAggregate]
}
struct FleetSnapshot: Codable, Sendable {
    let protocolVersion: Int
    let hubUUID: UUID
    let generation: Int64
    let hub: FleetNodeIdentity
    let generatedAt: Date
    let nodes: [FleetNodeSnapshot]
    let fleet: FleetAggregate
    let electedQuotas: [FleetElectedQuota]
}
```

DTO 的 `FleetQuotaReport`、`FleetElectedQuota` 与 `FleetWindowUsage` 均使用 `quotaProviderID`，与示例保持一致；快照 `fleet` 对应 `FleetAggregate`。报告通道 nil/empty 语义见 §5.1。`FleetClientProviderUsage` 的总量行不能由可能截断的模型明细反推。每日权威 totals 与 model detail 完整度分别携带；金额与 token 必须来自同一批样本。wire 使用 `FleetCostCoverage: String, Codable` 映射，避免要求既有 `CostCoverage` 增加 Codable。当前设计尚未实现这些 DTO。

### 5.6 字段校验规则（hub 收到报告时）

校验 UUID、已注册 provider/client ID、非负计数、有限金额、`startAt < endAt`、有效 dayKey、dailyBuckets 通道存在时必须恰有七个唯一日桶、序号为非负整数及请求体大小。配对金额/币种不一致时将该金额视为缺失；未知枚举或无效边界拒绝该行并标记完整度不足。额度至少有一个 `ModelQuota.hasActiveQuotaWindow` 才参加选举；DeepSeek 余额为零仍是有效额度。窗口通知范围仍由 provider 类型单独门控。`seq <= node_meta.lastAcceptedSeq` 时不应用任何通道。日用量只有在来源和通道验证成功且七桶有效时更新；额度可独立通过校验并更新，窗口项通过校验后逐行 upsert。

### 5.7 存储

所有同步状态保存在应用自有 `fleet.sqlite` 的单表 `sync_records`。主键包含 `kind, scope, node_id, record_key`；hub 的 latest report、node_meta high-water seq、每个窗口范围的最近摘要、hub_meta generation 与副节点 snapshot 都在此表中。`scope` 对 hub 数据为 hubUUID；snapshot 为 upstreamKey + hubUUID。

```sql
CREATE TABLE sync_records (
  kind TEXT NOT NULL, scope TEXT NOT NULL, node_id TEXT NOT NULL, record_key TEXT NOT NULL,
  seq INTEGER, generation INTEGER, updated_at REAL NOT NULL, payload_json BLOB NOT NULL,
  PRIMARY KEY (kind, scope, node_id, record_key)
);
```

`kind=report, record_key=current` 保存日桶与额度快照；`kind=node_meta, record_key=high-water` 保存 seq；`kind=window` 每个时间范围一行；`kind=hub_meta` 与 `kind=snapshot` 各自使用固定 record_key。报告及 node_meta 在事务中更新，hub 重启后 high-water seq 不因日桶清理而丢失。窗口摘要用 `kind=window`、`record_key=quotaProviderID|modelID|windowKind|startAt|endAt` 独立 upsert；`updated_at` 是可信的最后观察时刻，snapshot 的 `observedAt` 使用该值。新报告没有某个范围时不删除旧范围，按 `retainDays` 清理过期窗口。快照、hub_meta 和 node_meta 亦为不同 kind，同表事务提交。hub 本机数据变化也持久递增 generation。来源未验证或 authoritative daily totals 不完整时不替换旧日桶；model detail 不完整可单独标记。独立通过验证的额度、lastSeen、seq 可更新。不得修改任何客户端账本或原本机缓存，不再使用 `fleet-state.json` / `fleet-snapshot.json`。

## 6. 运行时接线

### 6.1 新增文件（按仓库现有分层）

```text
Models/SyncModels.swift             设计 DTO、校验与纯合并/选举函数
Models/FleetUsageModels.swift       L3 视图投影
Services/Sync/NodeIdentity.swift    Keychain UUID + lastIssuedSeq
Services/Sync/UsageReportBuilder.swift 日桶、窗口、额度 DTO 构建
Services/Sync/FleetStore.swift      fleet.sqlite 唯一表及事务
Services/Sync/HubServer.swift       hub HTTP 服务
Services/Sync/SyncClient.swift      node HTTP 客户端
Services/Sync/SyncCoordinator.swift 串行调度、generation 与状态广播
```

Models 不依赖 Services；Services 不依赖 Views。窗口聚合的可复用内核放在 Models/L2；若现有 scanner 无法在截尾前生成所需摘要，可扩展 scanner 或其上游 builder，但不能从 Views 的 `ProviderCardDerived` 反向依赖，也不能新增第二套计价口径。

### 6.2 节点身份

`nodeID` 与 `lastIssuedSeq` 放在同一个 Keychain 条目中（明确设置 `kSecAttrSynchronizable = false`）。首次启动生成 UUID 并一次性保存；之后读取失败或写入失败时停止同步，不得静默换 UUID。`SyncCoordinator` 串行分配序号，先持久化递增后的 `lastIssuedSeq`，成功后才发送该序号的报告；Keychain 读写失败则不发送。这样迟到报告可由 hub 的最大已接受 seq 拒绝，不需要 epoch、node-id/node-state 文件或身份恢复握手。

用户明确执行“强制换 UUID”时生成新身份并视为新节点；hub 保留旧 nodeID 记录，用户可手动移除。`nodeName` 默认 hostname，可在同步设置中编辑并保存在普通配置中。

### 6.3 推送内容的构建路径

额度 DTO 读取 provider 最近一次成功数据；每日 token totals / model 明细沿用现有投影和归因结果；窗口摘要从真实样本按 provider、model、windowKind、startAt、endAt 计算。hub 不下发窗口计划。当前 Codex `recentSamples` 有预算上限，日桶或窗口金额若由截尾样本构造，必须标记 incomplete；不能把完整 token 总量与截尾样本的金额配成 full。优先复用现有 `LocalUsageSummaryBuilder.windowBounds/windowSamples` 与同样本成本逻辑；必要时在截尾前为共享内核增加日×模型及窗口金额汇总。此处允许 scanner 变更，不允许 Services 依赖 Views，也不新增计价路径。

副节点报告最近七个日桶（今天及之前六天），并分别发送窗口摘要。额度、窗口和每日用量是独立信息：缺少窗口边界的节点不猜边界，也不以日合计填充窗口。

### 6.4 配置 schema 扩展

```jsonc
"sync": {
  "enabled": true,
  "hubURL": "http://192.168.1.20:8787",   // 副节点：主节点地址；留空 = 本机是主节点
  "pushIntervalSeconds": 60,              // 上报周期，默认 60
  "hubBindHost": "0.0.0.0",               // 主节点监听地址
  "hubPort": 8787,
  "nodeName": "",                         // 空 = 用 hostname
  "staleAfterSeconds": 900,               // 超过此时长未上报 → 标 stale（默认 15 分钟）
  "quotaMaxAgeSeconds": 1800,             // 副节点来源的额度超过此时长 → 标「额度已过期」（默认 30 分钟）
  "retainDays": 7                         // hub 保留多少天的历史日桶
}
```

**语义细节：**

- `sync.enabled` 缺省 = `false`（不参与联动）→ **现有用户零影响**。
- `hubURL` 为空 / 缺省 → 角色为 hub（主节点）。
- `hubURL` 非空 → 角色为 node（副节点），**且不监听端口**。
- `hubURL` 只需填 `http://<主节点IP>:8787`。端点路径是固定常量，副节点原样拼接。
- `hubURL` 非空但角色被强制为 hub：不可能——角色完全由 `hubURL` 派生，没有第二条路径。

`AppConfig` 的改动遵循现有模式：可选字段 + `effective*` 访问器 + 逐字段容错（手改坏值只回退该字段）。`schemaVersion` 从 2 升到 3。

### 6.5 调度

Node 周期或数据变更时串行分配 seq、生成报告并 POST；hub 在事务中校验 seq，分别验证 daily、window、quota 通道；有效日桶替换 report 当前七日数据，窗口行独立 upsert，额度通道独立替换。已验证 envelope 可更新 lastSeen/seq；hub 本机数据、额度或 stale 状态变化也递增并持久 generation。node 仅当响应对应当前 upstreamKey、已通过 health 握手确认的 hubUUID，且 generation 不旧于已缓存值时，才提交快照；每次启停、角色或 upstream 配置改变均递增本地配置版本并取消旧请求；响应写入前必须仍匹配发起时的配置版本，配置切换造成的迟到响应丢弃。hubUUID 未验证或 generation 较旧时不得覆盖快照；仅用量通道来源/完整度未通过时跳过日桶/窗口写入，仍可独立应用通过验证的额度与 lastSeen/seq，避免心跳与额度通道被卡住。缓存与 hub 状态都写 `fleet.sqlite`。网络失败保留最后有效快照并标离线，重试退避。

## 7. 合并语义

### 7.1 幂等与合并

hub 将每节点有效日用量作为当前报告中的七日日桶整体替换，按 dayKey 合并。权威 totals 独立求和，client/provider totals 用于 UI 分组；模型明细按键合并并单独传播完整度。若有定价贡献也有无定价贡献，coverage 为 partial；只有全贡献有价且完整才是 full；全无价才是 none。金额仅同币种相加。报告的 usage 来源无效或七个 authoritative totals 不完整时保持已有日用量，不让空/不完整 totals 覆盖它；totals 完整但 modelDetails 不完整时可更新 totals，并将明细缺口显式标记。

`windowUsage` 不随每节点当前报告替换。每个摘要按 `(quotaProviderID, modelID, windowKind, startAt, endAt)` 在 `kind=window` 中独立 upsert；新报告没带某范围不删除旧范围，按 retainDays 过期，并以各窗口的 last-observed time 显示数据新鲜度。严格比较起止时刻，不舍入。聚合只合并完全相同范围。stale 节点的同范围摘要仍贡献并显示离线/最后上报时间及 incomplete；范围不同的摘要不混加。缺边界节点不猜测，也不以日桶补窗口。金额与 token 来自同样本集合；部分扫描不得标 full。

### 7.2 hub 的本地条目

hub 自己作为一个节点参加合并；来源是否本机只通过 `nodeID == hub.nodeID` 判断，wire 不带 `isLocal`。本机报告由同一 builder 生成，不经 HTTP。

### 7.3 稳定身份与 seq

每个稳定 nodeID 的 Keychain 条目同时持有 `lastIssuedSeq`。发送前持久化递增 seq；hub 仅接受 `seq > node_meta.lastAcceptedSeq`，事务中更新 node_meta 与成功通过验证的通道。重复/乱序报告不重放旧数据。日桶清理与报告替换不清除 node_meta high-water。Keychain 失败则不发、不换 UUID；强制重置产生新 nodeID，旧节点保留至手动删除。

### 7.4 stale 标记

按 lastSeenAt 计算 stale，只影响状态展示和完整度，不抹去该节点同一当前范围的贡献。UI 标示离线及最后上报时间。窗口范围不匹配才从所选窗口汇总排除，并标记所选总量覆盖不完整。

### 7.5 日切换

有效 dailyBuckets 通道含 today + previous six 的完整七桶。该通道省略或验证失败时旧日桶保留；通过验证时替换七桶并按 dayKey 合并。日桶使用已裁定的同一时区语义，不做跨时区换算。不同日期不会混加。hub 生成快照时只选择今天及前六天；离线节点没有今天的桶应标未收到，不得把昨天的数当成今天。日切、窗口到期、stale 阈值到达均触发本地快照重算和界面广播，不必等待新报告。

### 7.6 节点清理

强制更换 UUID 后旧节点仍保留，直到用户手动移除；stale 节点在保留期内继续计入其匹配日桶及窗口。`retainDays` 清理过期日桶/窗口，但不得清理 node_meta 高水位或把旧 UUID 自动映射到新身份。

### 7.7 额度选举

有效额度要求至少一个 `ModelQuota.hasActiveQuotaWindow`；DeepSeek present balance（包括零余额）符合有效性，但通知仍按 `ProviderKind.windowedKinds` 门控。hub 有自己的有效 `lastSuccess` 就优先，即使当前 fetch 失败或状态显示需重试；只有本机无有效额度才从副节点候选选举。副节点候选按额度 `fetchedAt` 排序（2026-10-24 已裁定）；过期只标 stale，不自动淘汰。

视图生效额度为 `本机有效 lastSuccess ?? electedQuota`。本机状态（disabled、failed、loading）独立于入列门控：provider 入列集合为「本机已启用的 provider」与「存在 elected quota 的 provider」并集；仅远端额度也足以入列。若本机 disabled，卡片可显示远端有效额度，同时本机状态仍显示 disabled，不伪造 enabled/fetch 状态，也不因此发本机额度通知。额度来源通过 sourceNodeID 与当前 nodeID 比较，不使用 wire `isLocal`/`sourceIsLocal`。

### 7.8 归因指纹：检测不一致，但不阻断

按 §2.4 的裁定，**归属由各节点自己裁决，hub 不重裁**。hub 只做一件事：**检测各机的归因设置是否一致**，不一致时告诉用户。

**指纹的算法（写死，跨机可比较）：**

```
attributionFingerprint = hex(SHA256(规范化绑定表))[0..8]
```

规范化：把 `clientBindings` 按 `(clientID, quotaProviderID)` 排序，每条取 `clientID + "|" + quotaProviderID + "|" + (enabled ? "1" : "0") + "|" + sourceProviderAliases.joined(separator: ",")`，用 `\n` 连接。

**别名表进不进指纹？** 进。别名变了 → 归属可能变 → 必须算作「不一致」。`enabled` 也进——绑定关掉会直接让帧不生成（`Models/UsageFrameExtractors.swift:135-138`）。

> 用 SHA256 而不是 Swift 的 `Hasher`：后者的种子每个进程不同，跨进程/跨机器不可比。这是**跨进程**的指纹，不能用 `hashValue`。

**hub 的行为：**

| 情况 | hub 行为 | 用户可见 |
|---|---|---|
| 全体节点指纹相同（含空指纹＝都没上报） | 无 | 无 |
| 出现 ≥ 2 种不同指纹 | **接受全部数据，照常合并** | 设置页标黄提示「fleet 内归因设置不一致，全局数字为各机口径之和」 |
| 某节点指纹为空（格式非法 / 旧版本） | 视为「未知」，不参与比较 | 不提示（避免旧版本节点误报） |

**明确不做的事：**

- 不因为不一致而拒绝数据（那会让一台机器的用量凭空消失）。
- 不让 hub 按自己的 bindings 重裁（会引入第二套口径，见 §2.4 理由 1）。
- 不阻断、不弹窗——归因是用户的本地配置选择，不是错误。

**为什么值得加这个字段（而不是「让大家保持一致」的口头约定）：** 归因设置不一致的**唯一可见后果**就是全局数字与用户预期有偏差，而这个偏差**无法从数字本身看出来**。一个 8 字节的指纹 + 设置页一行提示，是把「说不清的偏差」变成「看得见的说明」的最便宜做法。

---

## 8. 失败与降级

网络失败保留 `fleet.sqlite` 中最后一次经验证且 generation 新的快照，展示离线状态；source/hubUUID 未验证时不得写空快照。hub 重启从 SQLite 事务数据恢复。seq 的 Keychain 读写失败时本轮不发送并报告同步错误，不更换身份。hub 本机抓取失败但有有效 `lastSuccess` 时额度仍本机优先，同时保留需重试状态；本机没有有效额度才回退 elected。stale 节点数据继续计入同一当前范围并注明离线/截止时间；不匹配窗口边界的节点不混加，汇总展示 incomplete。额度通知继续仅由本机 provider 状态和既有通知门控决定，远端 elected 不触发本机抓取通知。

## 9. 安全

### 9.1 v1 不做认证

**用户裁定（2026-10-23）：先不用考虑这个问题，直接用最简单的方式；需要时再加。**

v1 的 hub 只做最基本的输入校验：

| 检查 | 行为 |
|---|---|
| 路径不在白名单 | `404` |
| `Content-Type` 不是 `application/json` | `415` |
| 已知字段类型不符 / `protocolVersion` 不匹配 | 整包 `400` |
| 请求体 > 4 MiB | `413`，不等 body 读完 |
| 同一 `nodeID` 两次请求间隔 < 1s | `429` |

**没有密钥、没有令牌、没有路径前缀、没有 TLS。** 副节点侧只需填 `http://<主节点IP>:8787`。

这是**刻意的推迟**，不是疏忽：安全需求由实际部署形态决定，而这个特性的部署形态还没定（纯局域网？组网？公网？）。现在先加一套认证，等形态变了还得推翻一遍。

### 9.2 将来加认证时，改动落在哪

预留三个缝，实现时**不要把缝堵死**：

| 缝 | 位置 | 将来加认证时怎么用 |
|---|---|---|
| **请求头** | `SyncClient` 构造 `URLRequest` 的那几行 | 加一个 `Authorization` header |
| **请求入口** | `HubServer` 解析完请求行与头、进业务逻辑之前 | 在那里插一次校验；不通过直接 `401`，业务代码零改动 |
| **协议版本** | wire 的 `protocolVersion` | 加认证是**破坏性变更** → 提到 2；主副版本不一致时 hub 明确报错，而不是静默错解 |

配置上，`sync.token` 将来作为一个**可选**字段加进 `AppConfig`（`schemaVersion` 2 → 3 → 4），缺省空 = 不校验。

> **真要跨公网时**，顺序是：先上传输层加密（TLS 反代，或 Tailscale 之类的组网），再谈应用层令牌。**只有令牌没有 TLS 等于把令牌明文发出去。**

### 9.3 日志纪律

沿用现有 `AppLog` 三路策略。同步相关日志**不记**：
- 请求 body（含机器名、模型名、用量）
- 完整 URL 的 query / userinfo（`HTTPRequestLogSanitizer` 已丢弃）

只记：`[fleet-node] POST /v1/usage/day node=MacBook-Pro status=200 bytes=18422`。

---

## 10. UI 落点

> **状态：2026-10-23 用户提出方案**——「dock 详情用一个分段控制切『全局 / 本机』，全局展示逻辑与本机完全一致；菜单再加一层节点分组（`codex{节点1-{模型}, 节点2-{模型}}`），顶部给『今日全部合计』与『今日本机合计』两个数」。
> 本节据此定稿实现落点。**「本看板 vs 全看板」的切分已经由 §10.0 的「两条轴」回答**，三个 UI 细则也已定（§10.6）。

### 10.0 两条独立的轴（整个 UI 设计的骨架）

UI 上有**两件互不相干**的事，必须拆开：

| 轴 | 取值 | 数据源 | 谁控制 |
|---|---|---|---|
| **用量 scope** | 本机 / 全局 | 本机 = `HarnessTodaySummary`；全局 = `FleetSnapshot.fleet` | **用户切**（分段控制） |
| **额度来源** | 本机 / elected | `effectiveQuota(for:)`（§7.7） | **不由用户切**，按规则自动 |

**为什么必须拆成两条轴：** 额度是**账号级**共享池（§2.1），「全局额度」这个概念不存在——fleet 选出来的额度是**某一个账号**的余量，不是所有账号的余量。所以 scope 切到「全局」时，**额度胶囊显示的东西和「本机」模式下完全一样**（都是 `effectiveQuota`），变的只有**用量区块**。

**如果把 scope 也套到额度上会怎样：** 用户切到「全局」，看到 ChatGPT 的环从 80% 变成 43%，以为「我今天用掉了一大截」——实际那 43% 是**同事机器上另一个账号**的余量。这正是 §10.3 要防的误判，而**边缘窗圆环没有文字位置标注来源**（§10.5 已因同样理由决定 iconDuo 不标注）。所以**额度不跟 scope 走**。

### 10.1 Dock 详情（= ProviderCardView）：用量 scope 分段控制

**架构前提（好消息）：** dock 浮层**直接复用菜单那张卡**——`Services/EdgeDockController+Popover.swift:74` 是 `ProviderCardView(status:)`，注释写明「与主菜单那一屏**逐字同源**，不另写一套轻量版」。

→ 所以「全局的展示逻辑可以完全一致」在架构上**天然成立**：不写第二套卡片，只给同一张卡喂两套数据。

**卡片在两个 scope 下逐块对照：**

| 卡片区块 | 本机 scope | 全局 scope | 数据来源 |
|---|---|---|---|
| 标题行（品牌 + 刷新时间） | 同 | 同 | 本机 |
| Account Info（账号邮箱 + 套餐） | 同 | **同** | `effectiveQuota(for:)` |
| 额度胶囊（还剩多少） | 同 | **同** | `effectiveQuota(for:)` |
| 额度窗口用量（每 model 的 5h / 周） | 本机样本 | **fleet 窗口用量**（范围独立保存） | `FleetSnapshot.fleet.windowUsage` |
| 最近 7 天 token 用量 | 本机 | **fleet** | `FleetSnapshot.fleet.dailyBuckets` |
| client 贡献 | 本机 | **fleet** | 今日 bucket 的权威 `clientProviders` totals |

**分段控制放在哪：** 卡片标题行右侧（现在那里是刷新时间 / 状态），`Picker(.segmented)`，`本机 / 全局` 两段。

**scope 状态存哪：** `AppState.fleetScope`（`@Published`），**dock 浮层与菜单 hover 卡共用同一个**——两处口径一致，用户切一次就记住。

**dock 圆环本身不跟 scope 走。** 圆环画的是**额度**（`EdgeDockEntry.intervalFraction` / `weeklyFraction`，读 `status.lastSuccess`），不是用量。理由见 §10.0。圆环继续读 `effectiveQuota(for:)`（§11.1 的改造），**不随 scope 变化**。

#### 窗口边界来自各节点实际观察

窗口用量需要样本时间，因此由节点按其本地有效额度边界及样本计算，并报告 provider/model/windowKind/startAt/endAt 和同样本金额。hub 不下发窗口计划，不把不同时间范围混加。每台机器额度边界可能不同；全局窗口只包含与当前显示范围完全一致的摘要，stale 节点只要范围相同仍计入，并标离线/最后上报时间。节点无边界时不猜测、不用日合计补值。

UI 范围选择默认：若存在与 hub 当前生效额度边界匹配的已上报窗口，优先采用该边界；否则选已报告窗口中 `endAt` 最新者（2026-10-24 用户已确认该默认）。显示明确的范围和覆盖状态；本机额度边界与选中 fleet 用量范围不同时并列呈现，不暗示二者同源。

### 10.2 菜单：两个合计 + client → node → model 三层

**目标结构：**

```
┌──────────────────────────────────────────────┐
│ 今日全部  2.4M   60%  ¥36.80（含$7.5）  14:32 │  ← fleet 合计
│ 今日本机  1.2M   62%  ¥18.40            14:32 │  ← local 合计
│ ████████████████  input / cache / output      │
├──────────────────────────────────────────────┤
│ Codex                       1.2M       $11.30 │  ← client 段头 = fleet 合计
│   ── MacBook-Pro（本机）    820K       $11.30 │  ← 节点行（新增层）
│      gpt-5.1-codex           820K       $11.30 │  ← 模型行（现有）
│   ── iMac                     400K        $5.40 │
│      gpt-5.1-codex           400K        $5.40 │
│ OpenCode                     200K        ¥3.10 │
│   ── iMac                     200K        ¥3.10 │
│      glm-4.6                 200K        ¥3.10 │
└──────────────────────────────────────────────┘
```

**口径：**

| 位置 | 显示 | 来源 |
|---|---|---|
| 第 1 行 | 今日**全部**合计（fleet） | `FleetSnapshot.fleet.dailyBuckets[today].totals` |
| 第 2 行 | 今日**本机**合计 | `HarnessTodaySummary`（今天已有的，不动） |
| client 段头 | 该 client 的权威日合计 | `fleet.dailyBuckets[today].clientProviders` 按 client 汇总 |
| 节点行 | 该节点的权威日合计 | `nodes[].dailyBuckets[today].clientProviders` |
| 模型行 | 该节点该模型明细 | `nodes[].dailyBuckets[today].entries`；只展示明细覆盖，不反推段头 totals |

**顶部两个合计是并排两行**（已定），不用分段控制二选一。理由：分段控制会让下面的段落在切到「本机」时**丢掉节点层**（只剩一个节点），用户想看「全局里本机占多少」就没法看了——而这正是多机联动最常见的一个问题。两行同时给出，节点层保持完整。

**可核对性：** client 段头使用独立权威日 totals；模型明细可能不完整，不能要求模型行相加等于节点/client 总量。UI 分开展示 totals 与 modelDetails 的完整度。

**单节点时只显示一行、且不显示节点层。** fleet 只有 1 台机器（本机）时：
- 「今日全部」==「今日本机」，两行重复 → 顶部只显示「今日合计」一行（保持今天的样子，不让老用户看到多余的一行）。
- 节点层只剩一个节点 → **不显示**。段内直接是模型行，与今天完全一致（纯噪音，且节点名没有信息量）。

> 这两条是同一条规则的两面：**fleet 退化到「只有自己」时，整个 UI 必须退化成今天的样子**，不该让用户看到"全局/本机""节点层"这些在单节点下没有意义的结构。

#### 宽度是真约束（已按裁定定案）

菜单内容区 **336pt**（`MenuPanelHeightBridge.width`），当前预算（`Views/HarnessUsageMenuView.swift:13-16`）：模型名 ≤108 + 占比条 ≥72 + Token 40 + 命中 36 + 价值 48 + 4×6 间距 = 328pt。

加一层节点分组后，模型行相对 client 段头多缩进一级：

| 缩进方案 | 模型名可用宽度 | 代价 | 状态 |
|---|---|---|---|
| **节点行不缩进**（细分隔线 + 次要色节点名做视觉分组），模型行只相对 client 缩进一级 | **≈ 94pt** | 层级靠线条与颜色区分，不靠缩进 | **【已定】采用** |
| 节点行缩进一级、模型行缩进两级 | ≈ 80pt | 模型名明显变窄，`MiniMax-M3.1-Flash` 这类要靠 `compactDisplayName` 压 | 未采用 |

**落地细节：** 节点行做成**全宽行**（节点名 + 该节点合计，数字列与模型行对齐成竖线），用一条细分隔线 + 次要色节点名表示层级，模型行只缩进一级。数字列仍对齐成竖线，读起来不乱。

**节点行的标记：** 本机节点标「本机」；离线（stale）节点次要色 + 「离线」标签；排序 = 本机第一，其余按 token 降序。

#### 数据从哪来（大部分不需要新增 wire）

菜单的 fleet 版本从 `FleetSnapshot.fleet.dailyBuckets[today]` 与各节点同日 bucket 读取：

- client 段及节点行 token → 对应 bucket 的权威 `clientProviders` / `totals`
- 模型行 → `entries` 明细；当 `modelDetailsComplete` 为 false 时标明明细缺口，不以其反推上级 totals
- client / 节点金额 → 仅从该 bucket 的 entries 聚合；明细不完整时金额必须标部分或缺失

日桶、独立窗口记录和额度通道都由 DTO 明确表达，详情见 §5.5。

### 10.3 额度的来源标注（新增，必做）

elected quota 来自**某台机器的账号**，不是"全局真相"。所有展示 elected quota 的地方都必须标出来源：

| 位置 | 标注 |
|---|---|
| 菜单底部 provider 状态条胶囊 | 胶囊下加一行 `来自 iMac`（次要色）；本机额度则标 `本机` |
| popover provider 卡片 | 卡片标题行的额度胶囊旁标 `来自 iMac`；Account Info 行的账号邮箱照常显示 |
| 边缘窗圆环 | 圆环 hover 出的 caption 里加「额度来自 iMac」 |
| 菜单栏 iconDuo | **不标注**（图标没有文字位置）——但设置页能看到每个 provider 的额度来源 |

来源标识的三种状态：

| 状态 | 显示 |
|---|---|
| 本机额度 | 不标（默认就是本机） |
| 他机额度，额度新鲜（`fetchedAt` 在 `quotaMaxAgeSeconds` 内） | `来自 <节点名>` |
| 他机额度，额度陈旧 | `来自 <节点名> · 已过期`（次要色 + 警示） |

**这条标注不能省。** 省掉它，用户会把一台机器的账号余量当成全局余量——比如以为「ChatGPT 还有 43%」，实际那只是同事机器上另一个账号的 43%。这是整套设计里唯一会造成**错误决策**（而不是"数字不好看"）的地方。

> **全局 scope 下的额外标注。** 窗口区块标为「跨节点用量」；额度胶囊仍只对应来源节点的账号。两者范围不同，不能暗示窗口总量与单账号额度同源。多账号语义推迟，不从 elected quota 推算账号数。

### 10.4 设置页新增「多机联动」pane

副节点视角：

| 字段 | 类型 | 说明 |
|---|---|---|
| 启用多机联动 | 开关 | 关闭 = 完全不参与 |
| 上级主节点地址 | 文本框 | `http://192.168.1.20:8787`；留空 = 本机为主节点 |
| 上报周期 | 数值 | 默认 60s |
| 本机名称 | 文本框 | 默认 hostname |
| 连接状态 | 只读 | 「已连接 · 上次同步 14:32」/「离线」 |
| 已收到的全局摘要 | 只读 | 节点数、全局 token、全局金额 |
| **各 provider 的额度来源** | 只读列表 | provider 名 + 额度余量 + 来源（本机 / 某节点名 / 无） |
| **归因设置一致性** | 只读提示 | 正常时不显示；fleet 内归因指纹不一致时标黄「归因设置不一致，全局数字为各机口径之和」（§7.8） |

主节点视角（`hubURL` 为空时切换）：

| 字段 | 类型 | 说明 |
|---|---|---|
| 监听地址 / 端口 | 文本框 + 数值 | 默认 `0.0.0.0:8787` |
| **复制地址** | 按钮 | 复制 `http://<本机局域网IP>:8787`——副节点粘这个就行 |
| 已连接节点 | 只读列表 | 节点名 / 最后上报 / 今日 token / 金额 / 状态 / 「移除」 |
| **各 provider 的额度来源** | 只读列表 | provider 名 + 额度余量 + 来源（本机 / 某节点名 / 无） |
| **归因设置一致性** | 只读提示 | 同上（§7.8） |

### 10.5 菜单栏图标

**不加全局指示**。图标现在的语义是「额度健康度」，塞进「多机汇总」会过载。全局信息在菜单里两行足够。

> 但**额度读数本身会变**：菜单栏 iconDuo 的弧与扇形读的是「生效额度」。若本机没监控某 provider 而 fleet 有 elected quota，菜单栏图标会开始显示那个额度——**这是 §7.7 统一解析入口的直接后果**，各读额度的界面口径一致，不会出现「图标显示 43%、卡片显示未配置」。
>
> **iconDuo 不跟 scope 走**（理由同 §10.0）：它读的是额度，不是用量；且图标没有文字位置标来源。

### 10.6 三个已定的 UI 细则（2026-10-23）

| # | 问题 | 裁定 | 落在哪 |
|---|---|---|---|
| **J** | 菜单顶部两个合计是**并排两行**，还是也用分段控制二选一？ | **并排两行**。分段控制会让下面的段落在切到「本机」时丢掉节点层（只有一个节点），用户想看「全局里本机占多少」就没法看了 | §10.2 |
| **K** | 节点行的缩进方案 | **节点行不缩进**——细分隔线 + 次要色节点名做视觉分组，模型行只相对 client 缩进一级。模型名可用宽度 ≈94pt（比两级缩进的 ≈80pt 宽 14pt） | §10.2 |
| **L** | fleet 只有 1 台机器时，菜单的节点层要不要显示？ | **不显示**。段内直接是模型行，与今天完全一致——节点层只剩一个节点时是纯噪音 | §10.2 |

**L 的一条推论（也一并定下）：** 单节点时顶部也只显示「今日合计」一行，「今日全部 / 今日本机」两行不出现。

> 这三条合起来是一条原则：**fleet 退化到「只有自己」时，整个 UI 退化成今天的样子**——不出现「全局 / 本机」的分段、不出现节点层、不出现第二个合计行。老用户没开多机联动时看到的界面与现在**逐字一致**。

### 10.7 UI 倒逼出来的 wire 增补

两处 UI 需要，但 wire 里还没有：

### 10.7.1 额度窗口用量（fleet 需要）

`windowUsage` 是独立于日桶的行，键为 provider/model/windowKind/startAt/endAt，含四桶、同样本金额/currency/coverage、complete 与采样截止信息。GLM 闲时窗口作为独立 `windowKind` 报告。hub 只合并边界完全一致的行。stale 但边界匹配的行继续贡献，并携带离线、lastSeenAt、incomplete 标记；边界不匹配不混入。缺边界节点不猜、不用日合计补窗。

范围显示默认优先匹配 hub 当前有效额度边界，否则取已报告窗口最新 `endAt`（2026-10-24 用户已确认），并应明确显示实际范围。缺少完整扫描或成本样本时 coverage 标 partial/none，不能以截尾金额配完整 token 标 full。

### 10.7.2 「最近 7 天 token 用量」

`dailyBuckets` 固定包含今天和之前六天。每日权威 client/provider totals 与模型明细分开携带完整度：即使模型明细因预算截断不完整，权威日总量仍可完整；UI 分别标记总量和明细覆盖。成本聚合依据实际有价/无价贡献推导 coverage（有价且无价为 partial），不能取 coverage 枚举最差值。窗口摘要不从这七个日桶派生。

## 11. 与现有架构的关系

同步是独立 DTO 与独立 `fleet.sqlite`，不修改任何 client ledger 或本机缓存，不把来源字段塞进既有模型。每日归因沿用现有 L2 投影；窗口金额沿用现有 `LocalUsageSummaryBuilder.windowBounds/windowSamples` 和同样本计价。Codex `recentSamples` 有限额，可能需要 scanner 在截尾前生成共享日×模型/窗口摘要；未确认覆盖前标 incomplete。不得承诺零 scanner 改动，也不得让 Services 依赖 Views 的 `ProviderCardDerived`。不新增计价口径。

额度展示采用有效本机 `lastSuccess` 优先，否则 elected；失败但保留有效 lastSuccess 时仍优先。额度可用性与本机状态/展示入列分开，enabled 本机 provider 或拥有 elected quota 的 provider 均可入列。通知和禁用状态仍按现有本机规则，不因 elected 改写本机状态。额度来源按 nodeID 相等判断，不传 isLocal 字段。

## 12. 实施分解

本设计 DTO 尚未实现。建议顺序：协议 DTO / 日桶窗口聚合与校验 → Keychain identity+seq → `fleet.sqlite` 单表事务（generation 可比较到重启前的值）→ 报告 builder/scanner 覆盖 → hub 合并、额度选举与 generation → HTTP/Coordinator → UI 有效额度门控及范围状态 → 设置页与验收。

验收至少覆盖：Keychain 读取/写入失败不发且不换 UUID；seq 先持久化、日桶清理不丢 high-water、乱序响应不覆盖；报告省略日桶仍可更新验证通过的额度和 lastSeen；遗漏旧窗口范围不删除 retainDays 内摘要；hub 本机数据变化及重启后 generation 单调可比；强制新 UUID 后旧节点保留可手删；本机失败但有效 lastSuccess 仍优先；DeepSeek 零余额仍可选举且不触发窗口通知；disabled provider 有 elected 时入列但本机状态不被改写；`full + none => partial`；截尾样本不能让金额 coverage 标 full；同范围 stale 窗口计入并标离线、不匹配范围排除；没有边界不猜测；hub 缓存按 upstreamKey+hubUUID 隔离，未验证来源或旧 generation 不覆盖；fleet.sqlite 更新原子且不触碰客户端账本/缓存。

## 13. 裁定状态

### 13.1 已裁定与技术默认

**用户明确裁定：** 多副一主、不级联；副节点上报额度，主节点自身有额度时优先采用；多账号语义推迟；v1 不认证、使用明文传输；不支持跨时区；Dock 全局/本机切换与菜单节点分组。节点 UUID 首次运行生成并存入 Keychain，强制更换 UUID 就视为多个副节点；上报及回传数据使用独立同步表，不往原表添加来源区分字段。副节点明确上报统计起止时间，由 hub 判断是否能相加；不同范围不混加。额度候选按 `fetchedAt` 排序、全局窗口范围选择采用「边界匹配优先、最新 `endAt` 兜底」（均 2026-10-24）。

**技术默认，非用户另行裁定：** UUID 不经 iCloud 同步，Keychain 失败时不自动换身份；`fleet.sqlite` / `sync_records` 的名称和单表结构；UUID 与 `lastIssuedSeq` 同一 Keychain 项、序号先持久化再发送；scope、窗口记录和 generation 的持久化与缓存隔离；同范围离线贡献保留并标注截止时间。全局窗口默认优先匹配 hub 生效额度边界，否则选最新 `endAt`；这是展示选择，不改变副节点上报的范围，也不要求主节点下发范围。所有 DTO 与新存储均尚未实现。

### 13.2 待用户确认

**（2026-10-24：以下两项均已确认，本表已无待确认项。）**

| # | 问题 | 技术推荐 | 状态 |
|---|---|---|---|
| M | 副节点额度候选按 `fetchedAt` 还是上报时刻排序？ | `fetchedAt`，避免新上报的旧额度胜出 | **已裁定（2026-10-24）：按 `fetchedAt`** |
| W | 全局窗口无 hub quota 同边界时如何选范围？ | 最新已报告窗口的 `endAt` | **已确认（2026-10-24）：边界匹配优先，无匹配取最新 `endAt`** |

其它用户明确决定与推迟项见 §13.1、§13.3。

### 13.3 明确推迟的事

| # | 事 | 状态 |
|---|---|---|
| **UI** | 「本看板 vs 全看板」的切分、菜单里放几行 | **已定案**（2026-10-23：dock 详情分段控制 + 菜单加节点层 + 两个合计，见 §10；三个细则已定，见 §10.6） |
| **多账号** | 同一品牌多账号的用量/额度合并 | **推迟**（裁定 E） |
| **认证** | 共享密钥 / TLS / 路径前缀 | **推迟**（裁定 B2），缝已留在 §9.2 |

---

## 14. 附：与本次数据源梳理的衔接

`docs/reviews/ui-data-source.md` 的结论直接支撑本设计：

- 推送的是**本机用量**，其来源包括 **3 个 token 数据库、文件账本与本机 RPC**。副节点复用现有投影；为七日日桶和窗口金额可能需要扩展 scanner 在截尾前聚合，不承诺零新增读盘或零 scanner 改动。
- **金额来自打包的 `ModelPricing.json`**，所以「各节点自算金额」意味着**各节点的价目表版本可能不同** → 这就是为什么 UI 必须能逐节点展开（§2.2）。
- **节假日表会改变金额**（峰谷倍率）→ 各节点的金额口径天然可能不同 → 再次支持「金额由各节点自算、hub 只做币种内加法」的选择。
- **额度是另一条完全独立的通道**：它来自 provider 的**公网 HTTP 或 Antigravity 本机 RPC**（不是 token 账本），走的是「读取 `lastSuccess` → 上报 → 选举」的路子，与用量通道**不共用任何数据**。
- **用量来源包括 3 个 token 数据库、本地文件账本与本机 RPC**；同一底层数据被复制或 nodeID 更换后同时保留旧节点时可能重复计数。额度是账号级事实，用量仍按节点报告相加，见 §2.4。
- **归属（用量归到哪个 provider 桶）是本机配置决定的**（`clientBindings`，review 里的「配置」类数据源）→ 跨机归属裁决权归**各节点自己**，hub 只做加法；一致性靠指纹检测提示（§2.4 / §7.8）。
