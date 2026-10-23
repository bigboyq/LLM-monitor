# 多机联动（Fleet Sync）— 核心链路

多副一主的局域网用量/额度联动：每个实例默认只当本机监控；配置了 `sync` 后，
无 upstream 的实例成为 hub（监听端口、合并报告），有 upstream 的实例成为
node（定期上报、消费回传快照）。拓扑严格两层，不级联。

- 设计事实源：`docs/reviews/fleet-sync-design.md`（含全部用户裁定与技术默认的
  裁定记录）。本文件只登记**已实现**的核心链路；UI 与设置页落点尚未实现，
  见该设计稿 §10 / §10.4。
- 实现范围（2.0 第一批）：协议 DTO 与校验、Keychain 身份与 seq、`fleet.sqlite`
  单表存储、报告构建、hub HTTP 服务、node 推送与快照缓存、AppConfig `sync`
  节（schemaVersion 3）、AppState 按需启动。

## 1. 角色与拓扑不变量

角色由 `SyncRole.derive(config:)` 单源派生（`Models/SyncModels.swift`）：

| 条件 | 角色 |
|---|---|
| `sync.enabled != true`（缺省） | `.off`——完全不参与，现有用户零影响 |
| `sync.enabled` 且 `hubURL` 空白 | `.hub`——监听 `hubPort` |
| `sync.enabled` 且 `hubURL` 非空 | `.node`——只上报，**不创建** `NWListener` |

写进代码的不变量（§3 of 设计稿）：node 不监听端口；hub 从不主动连 node；
任一节点的本地显示永不依赖网络（`AppState.startFleetSync` 构造失败只记日志）。

## 2. Wire 协议（HTTP/1.1 最小子集）

| 方法 | 路径 | 语义 |
|---|---|---|
| `POST` | `/v1/usage/day` | node 上报 `NodeUsageReport`，hub 同响应回 `FleetSnapshot`（推 + 取一次往返） |
| `GET` | `/v1/usage/day` | 兜底拉取当前快照 |
| `GET` | `/v1/health` | `{"ok":true,"nodeID":"<hubUUID>","protocolVersion":1}`——node 靠它验证 hub 身份 |

服务端（`Services/Sync/HubServer.swift`，`NWListener`）：`Content-Length` 定长
body（不支持 chunked）、`Connection: close`、请求体上限 4 MiB（超限立即 `413`
不等 body 读完）、响应体上限 2 MiB、路径白名单外 `404`、`Content-Type` 非
JSON `415`、同一 nodeID 两次请求间隔 < 1s `429`、请求头 > 16 KiB `431`、
30s 连接看门狗。v1 无认证无 TLS（用户裁定；认证缝见设计稿 §9.2）。
日志只记 `status bytes`，不记 body/header（§9.3）。

编解码统一走 `FleetCodec.encode/decode`（`dateEncodingStrategy = .iso8601`
只写一次；漏设会把 `Date` 静默错成 2001 基准 Double）。时刻一律 ISO8601、
日历日键用 `yyyy-MM-dd` 字符串 `dayKey`（单时区前提，用户裁定；`timezoneID`
仅诊断元数据，不产生换算分支）。

## 3. 报告与快照形状

DTO 全集（`Models/SyncModels.swift`，对齐设计稿 §5.5）：`NodeUsageReport`
（外壳：nodeID + 单调 `seq` + `attributionFingerprint`；三通道
`dailyBuckets` / `windowUsage` / `quotas` 均可选）与 `FleetSnapshot`
（`hubUUID` + 持久 `generation` + `nodes[]` + `fleet` 聚合 + `electedQuotas`）。

通道语义（§5.1）：`nil` = 本次不更新；日桶存在时必须恰有 7 桶
（today + previous six）且 authoritative totals 均 complete 才整体替换；
窗口行按完整边界 `(provider, model, kind, startAt, endAt)` 独立 upsert，
空数组不删除保留期内旧范围；额度通道独立校验独立替换。金额与 token 必须
来自同一批样本（同源计价硬纪律）；`FleetCostCoverage` full 额外要求样本集
完整（截尾金额不能配完整 token 标 full）。

hub 侧校验（`FleetReportValidator`，§5.6）：信封（protocolVersion / UUID /
seq / 时刻有限性）失败整包 400；日桶校验失败保留旧值（totals 与
clientProviders 汇总逐字段核对）；窗口行失败只丢该行；`seq <= high-water`
时所有通道不应用但仍回当前快照（幂等重试）。

## 4. 合并与选举（`FleetMerger` 纯函数）

- 日桶：按 dayKey 求权威 totals；clientProviders 按 (client, provider) 相加；
  entries 按 (client, provider, model) 相加——金额仅同币种相加，币种冲突整体
  作废金额（不给跨币种假总价）；coverage 按「有价 + 完整」重推导（full+none
  → partial）；`totalsComplete` 取 AND、`sourceTruncated` 取 OR。快照只含
  today + previous six（日切由装配时的 `now` 决定，不等新报告）。
- 窗口：只合并边界完全相同的行（时刻精确比较）；stale 节点同范围仍贡献并进
  `staleNodeIDs`；缺该范围的已知节点进 `missingNodeIDs`；金额按币种分列
  `valueByCurrency`。
- 额度选举（§2.1 / §7.7）：候选须有 ≥1 `ModelQuota.hasActiveQuotaWindow`
  （DeepSeek present 余额含 0% 有效）；hub 本机有效额度无条件优先（即使更陈旧）；
  否则取副节点候选中 `fetchedAt` 最新者（2026-10-24 用户裁定，不按上报时刻）；
  超过 `quotaMaxAgeSeconds` 只标 `isStale` 不淘汰。来源经
  `sourceNodeID/sourceNodeName` 表达，wire 不传 `isLocal`。

## 5. 身份与序号（`Services/Sync/NodeIdentity.swift`）

`nodeID`（UUID）与 `lastIssuedSeq` 存**同一个** Keychain 条目
（`kSecAttrSynchronizable = false`，不随 iCloud 同步——用户裁定）。
`allocateSeq` 先持久化递增后的序号、成功才返回；Keychain 读写失败抛错、
不发送、**不静默换 UUID**；损坏负载报错而不是重置。强制换 UUID
（`forceReset`）= 新节点，旧 nodeID 由 hub 保留至用户手动移除。

## 6. 存储（`Services/Sync/FleetStore.swift`）

应用自有 `fleet.sqlite`（与 `config.json` 同目录）单表 `sync_records`，
主键 `(kind, scope, node_id, record_key)`，WAL 模式，NSLock 串行：

| kind | 内容 |
|---|---|
| `report` | 每节点当前接受的报告（`FleetStoredReport`：daily/quotas 独立通道 + nodeName/timezoneID/指纹） |
| `node_meta` | high-water seq + lastSeen（窗口/日桶清理不清除，§7.6） |
| `window` | 每节点每窗口范围一行；`observedAt` 由 hub 覆写为接收时刻（不信任上报值） |
| `hub_meta` | generation（跨重启单调可比） |
| `snapshot` | 副节点快照缓存（scope = upstreamKey + hubUUID，隔离不同上游） |

`applyReport` 单事务：seq 门控 → 通道独立替换/保留 → 窗口 upsert →
node_meta → 任何可见变化递增 generation。窗口按 `endAt` 早于
`now - retainDays` 清理；`removeNode` 删除该节点全部行并递增 generation。

## 7. 报告构建（`Services/Sync/UsageReportBuilder.swift`）

从 `ProviderStatus.usageProjection`（既有 L1→L2 投影，归属已裁决）构建：

- 日桶：权威 totals = 各 (client, provider) 日聚合的规范化汇总
  （`FleetTotals(summing:)`，uncached input / cacheRead 分列，
  与 `TokenUsageBuckets.fromSample` 同口径）；模型明细从 `recentSamples`
  分组，金额走 `ModelPricingCatalog.estimate`（同一批样本）。任一来源截断
  或 freshness `.failed` → `totalsComplete/modelDetailsComplete = false`、
  `sourceTruncated = true`。
- reconcile 扫描中（`isScanningLocalUsage` 或 freshness `.scanning`）**省略
  整条日桶通道**（缓存恢复值不等于已验证，不能当权威值覆盖 hub）；窗口与
  额度照常。
- 窗口行：按各 model 的真实窗口边界（`LocalUsageSummaryBuilder.windowBounds`
  + `windowSamples`，同样本计价）产出 `interval` / `weekly` 行；GLM 闲时任务
  每窗口单独一行（`windowKind = glmOffPeak`，真实起止）。
- 额度：仅有有效 `lastSuccess` 且 ≥1 活跃窗口的 provider 上报；
  DTO 裁掉与用量重复的 `codexUsageDetails`。

## 8. 运行时编排（`Services/Sync/SyncCoordinator.swift`，@MainActor）

- hub：`startHub` 起 `HubServer`（`hubBindHost` 为回环地址时只绑 127.0.0.1）；
  本机数据变化（防抖 2s）→ 同一 builder 生成报告**不经 HTTP** 直接
  `applyReport` 并入合并（hub 自己就是一个节点）；60s 维护节拍做窗口清理
  与快照重算——日切 / stale 翻转这类无报告变化经「可见签名」比对递增
  generation（§7.5）。
- node：推送循环由周期节拍（`pushIntervalSeconds`）与数据变更唤醒（5s 节流）
  共同驱动；每轮 `allocateSeq` → build → （首次）`/v1/health` 握手学 hubUUID
  → POST。仅当响应对应当前 upstreamKey、已验证 hubUUID 且 generation 严格更新
  时才写快照缓存（§6.5）；`configVersion` 在任何配置/角色变化时递增，迟到响应
  丢弃。网络失败保留最后有效快照并标离线；429 视为限流不算离线。
- 状态：`FleetSyncStatusInfo`（role / online / lastSyncAt / lastError /
  snapshotGeneration）与 `latestSnapshot` 已 `@Published`，供后续 UI 批次消费。

## 9. 配置与接线

`config.json` 新增 `sync` 节（`SyncConfig`，逐字段容错，坏值按未配置处理），
`schemaVersion` 2 → 3；缺省 `enabled = false`。字段与默认值见 `config.md`
§Config Schema 的 `sync` 行。

`AppState`：`start()` 时仅当 `sync.enabled` 才构造 `FleetSyncCoordinator`
（`fleet.sqlite` 落 `config.json` 同目录；Keychain 身份）；运行期配置启用由
配置订阅补启动；`statusDidChange`（quota 刷新 / scanner 应用 / rebuild 的
统一广播）驱动 `update(config:statuses:)`；`stop()` 停机。未启用时
`fleetSync == nil`，现有行为零变化。

## 10. 尚未实现（下一批）

- UI：dock 卡片「本机/全局」分段控制、菜单节点分组与两个合计、额度来源标注
  （设计稿 §10，细则 §10.6 已定）。
- 设置页「多机联动」pane（§10.4，含复制地址 / 已连接节点 / 移除 / 归因一致性
  提示）。
- `effectiveQuota(for:)` 统一解析入口（§7.7 的入列并集规则）。
- node 侧 GET 兜底拉取的调度（端点已实现，`SyncClient.fetchSnapshot` 可用）。

## 测试

`SyncModelsTests`（codec 往返 / 校验 / 合并 / 选举 / 指纹 / 角色派生）、
`NodeIdentityTests`（seq 先持久化、失败不换身份、强制重置）、
`FleetStoreTests`（重放拒绝、通道独立、窗口 upsert 与清理、generation 跨重启、
快照缓存隔离）、`UsageReportBuilderTests`（七桶权威 totals、同样本计价、
额度门控、扫描省略日桶）、`FleetSyncIntegrationTests`（回环端到端：health
握手、合并与选举入快照、重放不覆盖、心跳、429/413/415/404、hub 本机并入、
node 协调器上线与缓存落盘）。

> 核对基线：2026-10-24 · 代码 a3d4553
