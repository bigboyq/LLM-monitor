# 多机联动（Fleet Sync）— 核心链路

多副一主的局域网用量/额度联动：每个实例默认只当本机监控；配置了 `sync` 后，
无 upstream 的实例成为 hub（监听端口、合并报告），有 upstream 的实例成为
node（定期上报、消费回传快照）。拓扑严格两层，不级联。

- 设计事实源：`docs/reviews/fleet-sync-design.md`（含用户裁定与技术默认的
  记录）；本文件登记已落地的协议、存储、运行时与 UI 行为。
- 实现范围：协议 DTO 与校验、独立 `.deviceId` 文件中的稳定 nodeID 与 `fleet.sqlite` 序号、
  同步存储与报告构建、hub HTTP 服务、node 推送与快照缓存、Fleet 卡片和菜单
  scope、设置页、局域网地址解析及配置热更新。UI 已实现，见 §10。

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
| `POST` | `/v1/usage/day` | node 只上报自己的 `NodeUsageReport`；hub 同响应回全局聚合 + 本节点轻量回执（推 + 取一次往返）；**报告序号落后**（`seq ≤ high-water`）回 `409` + `{"error":…,"highWaterSeq":N}`，node 据此重建本机序号；仅通过序号门控的报告回 200 |
| `GET` | `/v1/usage/day` | 兜底拉取全局聚合快照，不包含逐节点明细 |
| `GET` | `/v1/health` | `{"ok":true,"nodeID":"<hubUUID>","protocolVersion":1}`——node 靠它验证 hub 身份 |

服务端（`Services/Sync/HubServer.swift`，`NWListener`）：`Content-Length` 定长
body（不支持 chunked）、`Connection: close`、请求体上限 4 MiB（超限立即 `413`
不等 body 读完）、响应体上限 2 MiB、路径白名单外 `404`、`Content-Type` 非
JSON `415`、同一 nodeID 两次请求间隔 < 1s `429`、请求头 > 16 KiB `431`、
30s 连接看门狗。v1 无认证无 TLS（用户裁定；认证缝见设计稿 §9.2）。
日志只记 `status bytes`，不记 body/header（§9.3）。

打包应用须声明本地网络用途及 ATS 局域网加载例外（`spec/config.md` 构建段）。
副节点地址为完整 URL，例如 `http://192.168.88.27:8787`；主节点保持应用运行并允许
所配置端口的入站连接。macOS 本地网络访问许可与主节点防火墙入站许可是不同机制。
ATS 拦截、系统限制网络、超时及无法连接应显示各自的脱敏错误；仅凭通用错误文本
不能断言是权限问题。安装新包后仍需在副节点实际验证权限与跨机 health 请求。

编解码统一走 `FleetCodec.encode/decode`（`dateEncodingStrategy = .iso8601`
只写一次；漏设会把 `Date` 静默错成 2001 基准 Double）。时刻一律 ISO8601、
日历日键用 `yyyy-MM-dd` 字符串 `dayKey`（单时区前提，用户裁定；`timezoneID`
仅诊断元数据，不产生换算分支）。
`dayKey` 校验要求 ASCII 数字、固定 `yyyy-MM-dd` 格式且对应真实 Gregorian 日期
（UTC 校验，年份 2000...2999）；非补零、非 ASCII 数字和不存在的日期均拒收。
生成日期键、计算七日窗口及 Fleet 图表反解日期键统一使用 Gregorian 日历，
保留调用方日历的时区；系统选择佛历、日本历等不会改变 wire 年份。

## 3. 报告与快照形状

DTO 全集（`Models/SyncModels.swift`）：hub 内部的 `FleetSnapshot`
保留完整 `nodes[]`，供主节点 UI 拆分查看；出网给副节点时，`nodes[]` 只在 POST
回包中含本节点轻量回执（nodeID / seq / dailyDigests，日桶、窗口、额度数组均为空），
GET 回包则为空数组。`participantCount` 只传节点总数，不传其他节点身份。副节点
收到旧 hub 的完整快照时，也会在缓存 / 发布前裁掉其他节点明细。
两种回包都含 `fleet` 汇总与 `electedQuotas`（每个 provider 的单一胜出额度仍带来源标注，
用于解释当前额度来源；不携带逐节点额度列表）。副节点只提供「全局 / 本机」范围切换，
不展示远端节点标签或节点拆分；主节点才展示逐节点范围和已连接节点列表。
Fleet 窗口聚合给副节点时清空 contributor/stale/missing 节点 ID 列表，并把缺失或
过期状态折入 `complete`，保留完整性提示但不泄露逐节点身份。

`NodeUsageReport`
（外壳：nodeID + 单调 `seq` + `attributionFingerprint`；三通道
`dailyBuckets` / `windowUsage` / `quotas` 均可选）与 `FleetSnapshot`
（hubUUID + 持久 `generation` + `participantCount` + `fleet` 聚合 +
`electedQuotas`；hub 内部完整快照另保留逐节点 `nodes[]`）。

通道语义（§5.1）：`nil` = 本次不更新；日桶存在时**最多 7 桶**
（today + previous six；增量裁定 2026-10-24：可只带需要补发/修正的天，
dayKey 互异）。旧格式（`unavailableSources == nil`）仍要求 totals complete 才逐桶替换；
来源感知格式按 `(clientID, quotaProviderID)` 更新健康来源，明确不可用来源保留旧值；
窗口行按完整边界 `(provider, model, kind, startAt, endAt)` 独立 upsert，
空数组不删除保留期内旧范围；额度通道独立校验独立替换。金额与 token 必须
来自同一批样本（同源计价硬纪律）；`FleetCostCoverage` full 额外要求样本集
完整（截尾金额不能配完整 token 标 full）。

**逐天摘要回执（增量裁定 2026-10-24）**：快照的每个节点条目带
`dailyDigests`（dayKey → 内容摘要，`FleetCodec` 规范编码后 SHA256 前 16 hex）。
副节点据此**只上报摘要不一致的天**（首次配置 / 本机重启 / hub 丢数据时回执
为空 → 全量七天重建基线；全部一致 → 整条通道置 nil，等价心跳）。
摘要失配的最坏后果是多发一次幂等补发。回执与日桶同窗口（只覆盖节点还会
产出的天）。来源感知 partial 桶落库后可能含保留的旧数据，因此回执使用最后接受的
**输入桶**摘要（`dailyInputDigests`），而非合并后桶摘要；旧记录缺该字段时回退
存桶摘要。被拒收的通道不更新回执，恢复完整后的输入摘要变化会触发重传。

hub 侧校验（`FleetReportValidator`，§5.6）：信封（protocolVersion / UUID /
seq / 时刻有限性）失败整包 400；日桶校验失败保留旧值（totals 与
clientProviders 汇总逐字段核对；来源感知桶另校验不可用来源已注册且唯一、
不可混入本次行数据，`totalsComplete` 等价于不可用列表为空，非空时
`modelDetailsComplete=false`，`sourceTruncated` 等价于含 `.truncated` 原因）；
窗口行失败只丢该行；`seq <= high-water`
时所有通道不应用并回 `409` + high-water（§2）；node 重建本机序号后 GET
一次当前快照。其他通过序号门控的报告即使某个可选通道被单独拒绝，仍回
当前快照与 `200`。

## 4. 合并与选举（`FleetMerger` 纯函数）

- 日桶：按 dayKey 求权威 totals；clientProviders 按 (client, provider) 相加；
  entries 按 (client, provider, model) 相加——金额仅同币种相加，币种冲突整体
  作废金额（不给跨币种假总价）；coverage 按「有价 + 完整」重推导（full+none
  → partial）；`totalsComplete` 取 AND、`sourceTruncated` 取 OR。快照只含
  today + previous six（日切由装配时的 `now` 决定，不等新报告）。不可用来源按
  client/provider 稳定去重合并，并保留 partial 状态；空跑副节点只贡献零值。
- 窗口：只合并边界完全相同的行（时刻精确比较）；stale 节点同范围仍贡献并进
  `staleNodeIDs`；缺该范围的已知节点进 `missingNodeIDs`；金额按币种分列
  `valueByCurrency`。输入行已有的部分计价状态必须保留，不能仅因金额非空便
  升级为 full；窗口不完整或来源截断同样不能标 full。日桶模型明细合并也保留
  输入明细的部分计价状态。
- 额度选举（§2.1 / §7.7）：候选须有 ≥1 `ModelQuota.hasActiveQuotaWindow`
  （DeepSeek present 余额含 0% 有效）；hub 本机有效额度无条件优先（即使更陈旧）；
  否则取副节点候选中 `fetchedAt` 最新者（2026-10-24 用户裁定，不按上报时刻）；
  超过 `quotaMaxAgeSeconds` 只标 `isStale` 不淘汰。来源经
  `sourceNodeID/sourceNodeName` 表达，wire 不传 `isLocal`。

## 5. 身份与序号（用户裁定 2026-10-25：独立设备身份文件）

wire 上的 `nodeID` 字段保持不变；本机身份由
`DeviceIdentityStore(configDirectory:)` 管理，文件路径为配置目录下的 `.deviceId`，
接口为 `fileURL` 与 `loadOrCreate() throws -> UUID`。仅在联动启用且需要运行
hub/node 时加载或创建身份；联动关闭时不得创建该文件。有效文件中的 UUID 跨进程、
配置替换与应用重装保持稳定。文件不存在时生成新的 UUID，成功持久化后才交给同步
协调器使用；读写失败不得使用临时身份，错误应可见并允许后续重试。
文件内容为 UTF-8 UUID 文本（新建时带末尾换行），读取允许首尾空白；新文件权限
`0600`、配置目录权限 `0700`。只在明确不存在时新建；不可读、格式无效或其他
I/O 错误均保留原文件并报错，不自动覆盖或更换身份。运行时成功加载后复用该 UUID。

旧 `config.json` 中的 `sync.nodeID` 不迁移、不继承：首次升级若没有 `.deviceId`，
会生成新身份；hub 上旧 UUID 节点仍保留，用户可手动移除。复制 config 到另一台
机器无需改 `sync.nodeID`，但不要连同 `.deviceId` 一起复制，否则会复制节点身份。
改动或替换 config 中遗留的旧 UUID 不会改变当前身份。身份文件缺失后的首次创建
与配置目录写入失败均不得继续采用尚未持久化的 UUID。

`lastIssuedSeq` 不进 config（每轮推送都递增，写配置会把热加载管线变成
推送回路），存 `fleet.sqlite` 的 `kind=seq` 单行：
`FleetStore.allocateLocalSeq()` 事务内 读→+1→写，**持久化成功才返回**——
hub 的 high-water 据此拒绝迟到报告（§7.3）。持久化失败本轮不发送、不换身份。

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
node_meta → 任何可见变化递增 generation。日桶按 **dayKey 逐桶 upsert**
（通道缺席的天保留旧值），**窗口外的天必须清掉**——节点的报告窗口逐日
滚动，只增不删会让 hub 存的天数一天涨一格（快照载荷越界 → 全员 500；
节点卡片画出 N 根柱子而不是 7 根）；协议把日桶通道限死在 7 桶，窗口即上限。
来源感知日桶只保留旧桶中显式不可用来源的 clientProviders/entries，与本次健康
行合并后重算 totals；健康真实零值、禁用或移除的来源清除旧贡献，不累加新旧整桶。
输入摘要与日桶一同裁剪、持久化；无需新增 SQLite 表，旧 payload 可直接解码。
窗口按 `endAt` 早于 `now - retainDays` 清理；`removeNode` 删除该节点全部行
并递增 generation。

**坏行降级**：无法解码的行（磁盘损坏 / 跨版本 DTO 形状变化写下的旧行）
跳过并删除，不让整次装配失败。`loadHubState` 与 `pruneWindows` 的坏行清理
都与 generation 递增放在同一事务内、每批只递增一次，使快照消费者能观察到
清理后的可见状态。

## 7. 报告构建（`Services/Sync/UsageReportBuilder.swift`）

从 `ProviderStatus.usageProjection`（既有 L1→L2 投影，归属已裁决）构建：

- 日桶：权威 totals = 各 (client, provider) 日聚合的规范化汇总
  （`FleetTotals(summing:)`，uncached input / cacheRead 分列，
  与 `TokenUsageBuckets.fromSample` 同口径）；模型明细从 `recentSamples`
  分组，金额走 `ModelPricingCatalog.estimate`（同一批样本）。扫描预算截断的来源
  从本次健康行中排除并以 `.truncated` 标记；partial 桶的
  `totalsComplete/modelDetailsComplete = false`，有预算截断标记时 `sourceTruncated = true`。
  DSH 即使因预算截断后没有任何 provider 帧，也保留源级截断状态；只影响启用了
  DSH 绑定的 provider，不制造空贡献。日桶与窗口均不得把该状态解释为完整零值。
- DSH 最近样本数量上限与扫描文件 / 字节预算分开记录。仅逐次样本被裁剪时，
  权威日总量仍可完整上报（`totalsComplete = true`），模型明细标记
  `modelDetailsComplete = false`，其 entries 与窗口金额不得宣称完整计价。
  `samplesTruncated` 按贡献来源 / provider 传递，关闭绑定的来源不影响该卡。
  旧缓存缺样本完整性元数据或样本上限发生变化时重新聚合；遗漏样本全部离开
  保留窗口后，cached rebase 可以恢复样本完整性。
- reconcile 扫描中或失败时按 `ProviderStatus.localUsageConsumers` 映射到实际
  启用的 client/provider，使用 `FleetDailyUnavailableSource` 标记 `.scanning` /
  `.failed`；健康来源继续上报。失败来源没有 contribution 时也必须标记，
  防止空帧覆盖 hub 上次成功值。DSH 等共享来源尊重 clientBindings；关闭绑定
  不构成不可用来源。旧 provider 级 `isScanningLocalUsage` 保守覆盖该 provider 的
  实际消费者。所有来源不可用时仍发 partial 桶，不宣称完整零值。
  对应 provider 的窗口行保持原有整 provider 省略保护，其他 provider 窗口和有效
  `lastSuccess` 额度照常构建。
- `unavailableSources` 为可选 v1 扩展：健康报告仍省略此字段；新版 hub 兼容旧版
  complete 日桶，旧版 hub 会拒收新 partial 日桶，因此多机部署应先升级 hub。
- 窗口行：按各 model 的真实窗口边界（`LocalUsageSummaryBuilder.windowBounds`
  + `windowSamples`，同样本计价）产出 `interval` / `weekly` 行；GLM 闲时任务
  每窗口单独一行（`windowKind = glmOffPeak`，真实起止）；GLM「免 / 速 / 它」
  三分类（Start Plan / 加速卡 / 其他智谱任务）各一行自然日窗口
  （`windowKind = glmStartPlan` / `glmHighspeed` / `glmOtherPlan`，边界
  `[startOfDay, +1d)`、与本地卡动态行同一份 `glmCategoryTodaySamples` 切片；
  当日无样本的分类照常上报全零行——展示层跳过全零，而缺行会让 hub 把同边界
  聚合误标 missing）。展示侧 `windowLabel` 把三个 kind 映回本地卡的行标签常量
  （免 / 速 / 它）。
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
  时才写快照缓存（§6.5）。网络失败保留最后有效快照并标离线；429 视为限流
  不算离线；hub 返回 5xx 是 hub 侧的问题（链路仍通）→ 报错但不判离线。
  GET 兜底成功仅恢复聚合快照读取，不等价于报告上传成功；非 429 的 POST 错误仍
  保留在 `lastError`，直到后续 POST 成功。409 保留序号重建提示，429 不清除旧错误。
- **hub 数据库重建 / 回滚恢复**：当前串行 POST 成功、已验证 hub 身份与配置版本
  均匹配，且响应内本节点的 seq 精确等于本次提交 seq 时，允许重建 generation
  基线并更新摘要回执；空 / 旧回执使下一拍补发缺失日桶。普通 GET、序号不匹配
  和配置切换后的迟到响应仍不允许用低 generation 覆盖缓存。
- **`configVersion` 只在配置/角色变化时递增**（不是每次数据变化）：statuses
  变化（每次配额刷新、每次扫描落库、每次 rebuild）也走同一条更新路径，若
  一并自增，在飞推送的响应会被当成「迟到响应」丢掉——快照不落缓存、摘要
  回执不推进（增量补发退化成每拍全量）、`lastSyncAt` 不刷新。
- **hub 身份复验**：响应的 `hubUUID` 与已验证身份不一致（hub 在同一地址换机）
  → 不采纳该快照、清空已验证身份、下拍重新握手，并把原因写进 `lastError`；
  不复验的话 node 会永远收不到数据而界面仍显示「已连接」。
- **序号落后自愈**：hub 拒收（`seq ≤ high-water`）时回 `409` + high-water，
  node 据此把本机序号抬到 hub 之上（`fleet.sqlite` 的 `kind=seq` 行），
  下一拍即可收下；否则这份报告会被**永久**拒收而界面一直显示「已连接」。
- 状态：`FleetSyncStatusInfo`（role / online / lastSyncAt / lastError /
  snapshotGeneration）与 `latestSnapshot` 已发布给设置和展示层。hub 监听器的
  `.ready` / `.failed` 事件更新 online 与错误状态；配置热更立即切换角色、监听
  参数、upstream 或推送间隔。关闭联动或切换上游会清空旧快照、同步状态和
  scope 展示，避免把旧上游内容留在新角色界面。
- node 初次构造时若非空上游 URL 非法，客户端初始化失败且尚未建立 consumer / ticker；
  后续同角色将 URL 修正为合法值时会补建推送运行时。已运行的 node 在 URL 暂时
  非法后再修正，也会复用串行 consumer 并重新排好 ticker。只改推送间隔时同样确保
  consumer 与 ticker 都存在；失败初始化不会留下单独运行的 ticker。

## 9. 配置与接线

`config.json` 新增 `sync` 节（`SyncConfig`，逐字段容错，坏值按未配置处理），
`schemaVersion` 2 → 3；缺省 `enabled = false`。字段与默认值见 `config.md`
§Config Schema 的 `sync` 行。
`pushIntervalSeconds` 默认为 `0`，表示“跟随常规”：缺失、类型错误或越界值
也回退为 `0`，并使用 `effectiveGlobalRefreshInterval`；已显式配置的正数（包括
旧配置里的 `60`）保持原值，不做迁移。设置页滑条范围仍为 `0...3600` 秒。

`AppState`：`start()` 时仅当 `sync.enabled` 才构造 `FleetSyncCoordinator`
（`fleet.sqlite` 与 `.deviceId` 落 `config.json` 同目录；身份由
`DeviceIdentityStore` 持久化）；运行期配置启用由
配置订阅补启动；`statusDidChange`（quota 刷新 / scanner 应用 / rebuild 的
统一广播）驱动 `update(config:statuses:)`；`stop()` 停机。Fleet 快照与 scope
展示走独立 `fleetDidChange` 广播，避免 UI 快照刷新再次触发 hub 报告构建。
首次启动时未启用则不构造 coordinator（`fleetSync == nil`），现有行为零变化；
运行中从 enabled 改为 disabled 时保留 coordinator 对象但停止其 runtime、清空
已同步快照与状态，并将无效的 Fleet/node scope 回到本机。

## 10. UI 落点（已实现）

两条轴（§10.0）：**用量 scope** 在主节点切全局 / 本机 / 远端节点；副节点只切
全局 / 本机（`AppState.fleetScope`，dock 浮层与菜单兜底 hover 卡共用同一份，
仅内存态）；**额度来源** 自动
（`AppState.fleetEffectiveQuota(for:)` 统一入口：本机有效 lastSuccess 优先，
否则 elected，来源经 `FleetEffectiveQuota.sourceTagText` 标注——本机不标 /
`来自 X` / `来自 X · 已过期`）。额度不跟 scope 走。

- **卡片**（`ProviderCardView` + `FleetCardContext`，两宿主同源注入）：
  多节点时出现 scope 控制 + 来源标注。主节点显示远端节点选项；副节点只显示
  全局 / 本机。scope 控制用 `FleetScopeSwitcher`
  ——**选项总数（全局 + 本机 + 远端节点）≤4 走分段控件**（一步切换），**>4 走
  菜单栏标题栏那套「label + ellipsis」下拉**（节点名放得下；形态见
  `spec/ui/menu-and-cards.md`）。位置：≤4 项时是标题行**下方**独占一行
  （`ProviderCardView.scopeRow`，宽度与卡片一致）——分段控件塞标题行会把
  provider 名挤成「minimax To…」；>4 项时紧凑形态回到卡头（状态胶囊左边）。
  下拉顺序**全局 → 本机 → 各远端节点**（`FleetNodeChoice`）。选具体节点时用量区块切到该节点
  **单机口径**（`FleetUsageProjection.nodeCardUsage`：它自己的 7 天日桶 /
  窗口行 / 今行，离线展示最后上报数据并提示），额度区块照常走生效额度
  （§10.0 两条轴不变）。切换先落卡片本地 @State（dock 浮层是一次性快照，
  只写 AppState 会弹回），再经 `onScopeChange` 同步全局选择。
  日图、今行和逐日金额按所选 node 或全局的完整日桶展示全 provider 合计；
  `quotaProviderID` 只过滤额度窗口行。此口径由用户裁定，避免 provider 卡片
  日统计把共享日桶误当成 provider-filtered 总量。
- **日桶可用性**：多节点全局 / 已存在的所选节点缺少今日桶时显示“尚未同步”
  与 `—`，不回落本机数据、不冒充完整零值；卡片仍保留已同步的历史日图。
  partial 桶显示健康来源及保留值，并提示不可用客户端、原因及可能包含上次数据。
  完整零桶照常显示 0；单节点退化规则保持不变。
- **菜单**（`HarnessUsageMenuView`）：**范围切换**：主节点 ≤4 项时是「今日」卡片**上方**
  独占一行（分段控件，宽度与卡片一致，`HarnessUsageMenuView.scopeRow`）；主节点 >4 项时
  是标题栏右组的下拉（`FleetScopeMenu`：全局 / 本机 / 各节点）；副节点只有全局 / 本机。段内**不分设备**——每个 client 段
  头 = 该 client 的 fleet 权威日合计，段内直接是 fleet 已合并的模型明细
  （同币相加、币种冲突置空由 hub 完成）。当前范围只有**一行**总览（标签统一
  「今日」，范围由顶部切换表达）+ 一根客户端占比条与图例（与本机 scope 的总览
  卡同一实现；段 = `FleetMenuSummary.sections`，段色 = `ClientSection.dominantQuotaProviderID`
  的 provider 卡 accent，细节见 `ui/menu-and-cards.md` Global today summary）。**零数据不占位**（2026-10-24
  裁定）：段内模型行 token 为 0 不出，整段全零不出段。fleet 段头有右键
  「刷新本机 <客户端名>」——按 clientID 复用本地段的 `refreshSectionFromMenu`
  （只刷本机数据）。**单节点 / 未启用时整棵树逐字保持
  现状**（§10.6 L 退化规则，`FleetMenuSummary.multiNode` 门控）。
  > 2026-10-24 实现侧定案：设计稿 §10.6 J/K（「并排两行」+「节点层」）已被
  > 标题栏 scope 切换 + 合并模型行取代——节点层算出来的数据不再渲染
  > （`section.nodes` / `FleetNodeGroupView`）。本节为准。
- **入列并集**（§7.7）：`AppState.fleetVisibleStatuses()` = 本机已启用
  provider ∪ 仅有 elected 额度的 provider（后者合成最小 status，卡片上有
  来源标注说明非本机抓取）；菜单兜底行与 iconDuo
  （`statusBarQuotaMetrics`）都走它。**用户显式禁用的 provider 不入列**：
  否则别的机器有额度就会让用户在 config 里关掉的 provider 重新出现在状态栏
  圆环里。
- **设置页**（`SettingsSyncPane`，SettingsTab.sync，排版走设置页统一组件
  `SettingsSection`/`SettingsControlRow`）：启用开关、hubURL /
  端口 / 上报周期 / 节点名（`ConfigStore.applyAndSave` 写穿持久化）、
  主节点复制局域网地址、已连接节点（**只列副节点，hub 自身
  参加合并但不进列表**；最后上报 / seq / 离线 / 移除 →
  `removeNodeFromFleet`）、全局摘要（节点数标注含本机）、各 provider
  额度来源、归因指纹不一致标黄（`FleetNodeSnapshot.attributionFingerprint`）。
  - **主节点地址落盘前校验**：必须能解析成 http/https URL 且 host 非空
    （口径与 `SyncClient.init` 同一把尺子）；不合法**不落盘**并就地显示错误
    ——写进去的后果是角色被判成副节点、`SyncClient.init` 抛错，机器从此离线。
  - URL / 节点名 / 端口草稿各自独立 600ms 防抖；回车只提交对应字段，推送周期滑条
    即时写入。配置外部更新只重置发生变化的字段并取消该字段旧提交，其他未变字段
    的草稿与定时提交保留；离开 pane 时尝试 flush 所有字段，有效值保存、非法 URL
    或端口仍不落盘。
  - **写盘失败可见**：启用开关、URL、名称、端口与推送周期分别显示保存错误；
    失败保留文本 / 周期草稿以便重试，实际配置与角色维持最后成功值。某字段重试
    成功或该字段被外部配置替换后，只清除该字段错误，不掩盖其他未保存字段。
    草稿 controller 由设置窗口持有，切换 tab 后仍保留失败草稿；其他 tab 的底栏
    提示联动配置未保存，并可返回联动页重试。
    Sync 独立写穿或外部只改 Sync 字段时，不重载 General/provider 未保存表单；
    真正相关的外部配置变化仍会重载，使用 publisher 传入的新值而非 willSet 期间
    仍可能保留旧值的 `configStore.config`。
  - **连接状态行显示 `lastError`**：只写「离线」两个字时用户无从下手
    （地址写错 / 漏 scheme / 主节点没开 / 端口不通）。
    联动关闭时明确显示「未启用」并隐藏残留 runtime error。
  - **局域网地址按硬件语义挑接口**（Wi-Fi → 有线 → 其它）。探测与挑选都在
    `LANAddressResolver`：采集用 `getifaddrs`（排除回环、未 UP 的接口、虚拟
    接口前缀 `lo/bridge/utun/gif/stf/anpi/ap/awdl/llw`，以及与 `bridge0` 同
    MAC 的雷雳桥腿），硬件类型由 Network.framework 判定（`LANInterfaceKindResolver`
    用 `NWPathMonitor` 缓存 Wi-Fi / 有线接口名供同步读——`sysctl` 的 `ifi_type`
    在 macOS 上对 Wi-Fi 与有线都是 `IFT_ETHER`，区分不出来），挑选是纯函数
    `preferredLANAddress`（Wi-Fi → 有线 → 其它；同类先到先得）。
    旧口径「只认 en0」假设 `en0` = Wi-Fi，碰到「`en0` = 有线口、Wi-Fi 落在
    `en1`」的机型整条链路取不到地址——界面显示「未检测到局域网地址」、复制
    按钮禁用，而其实有一个完全可用的地址摆在那里。
    **不拿 127.0.0.1 兜底**——取不到就显示「未检测到局域网地址」并禁用
    复制按钮（回环地址对副节点永远连不上）。
  - **端口非法即回滚**：输入框不留没落盘的值（否则同屏出现「输入 99999 /
    监听中（端口 8787）」的自相矛盾）。

### 收尾（6b90b16，原遗留三项已全部实现）

- **边缘窗常驻圆环读生效额度**：`AppState.fleetQuotaEffectiveStatuses()`
  在入列并集之上，把「本机无有效额度但 fleet 有 elected」的卡替换为
  `.ok(elected)`；`EdgeDockContentView` 与 `EdgeDockController+Window`
  两个投影调用点都切换到该视图。`EdgeDockController` 对 `fleetDidChange`
  有**独立订阅**（失效 `cachedOrderedEntries` 缓存 + `reconcile`，开卡时
  追加 `updatePopover()`），不搭 statusDidChange 的车（见 `ui/edge-dock.md`）。
- **node 侧 GET 兜底**：推送被 hub 拒（4xx/5xx）但链路通时拉一次快照
  （`SyncClient.fetchSnapshot`），走同一 upstreamKey+hubUUID+generation
  门控；429 仍只记日志不算离线。
- **窗口范围选择器**（§10.7.1 W 裁定，2026-10-24 已确认）：
  `cardUsage(preferredWindowEnds:)` 与 `nodeCardUsage(preferredWindowEnds:)` 对同
  (model, kind) 的多个已报告范围，
  优先取与当前生效额度边界**完全一致**的范围（`preferredRange`），无匹配
  取 `endAt` 最新者；偏好边界由 `AppState.preferredWindowEnds(of:)` 从
  生效额度主 model 的 `intervalResetsAt` / `weeklyResetsAt` 派生。

## 测试

`SyncModelsTests`（codec 往返 / 校验 / 合并 / 选举 / 指纹 / 角色派生、跨日历
Gregorian 日键、不完整日桶拒收与部分计价保留）、
`FleetStoreTests`（重放拒绝、通道独立、窗口 upsert 与清理、坏行清理的 generation、
快照缓存隔离）、`UsageReportBuilderTests`（七桶权威 totals、同样本计价、
额度门控、扫描/失败空贡献的来源标记、健康来源独立更新、DSH 恢复及关闭绑定、
真实 DSH 截断空帧不会覆盖旧来源值）、
`FleetSyncLifecycleTests`（同 UUID hub 数据库重建回填、POST 序号确认与 GET/迟到
响应隔离、身份写盘失败停机及重试、关闭联动不生成身份）、`FleetSyncIntegrationTests`（回环端到端：health
握手、合并与选举入快照、重放不覆盖、心跳、429/413/415/404、hub 本机并入、
node 协调器上线与缓存落盘）、`FleetUsageModelsTests`（生效额度三态与来源
标注、菜单单节点退化 / 双行合计 / 节点排序、卡片窗口行与不完整标记、
双 provider 日桶全量口径、窗口筛选/历史选择、部分计价）、`FleetScopeSwitcherTests`
（分段 / 紧凑菜单阈值与选项）、`SettingsSyncPaneTests`（配置校验与连接状态、
真实写盘失败的逐字段提示和重试、注入草稿跨 pane 重建保留）、
`LANAddressResolverTests`（局域网地址挑选与 MAC 偏移边界）、`AppStateTests`
（Fleet 快照 / scope 的独立刷新广播、失效选择清理与事件时序）。
`FleetCostTextPropagationTests` 覆盖真实 DSH 部分计价经 builder / 合并 / UI 转换后
仍保留文案，以及混币 5h / 周 / 今与闲行；`SettingsDraftIsolationTests` 覆盖仅
Sync / dock 位置写入不清常规草稿，含首次从 nil 写入默认 dock 配置；DSH scanner
与 builder 测试覆盖样本 cap、旧缓存重建、限额变化、样本老化恢复和权威日桶保留。

> 核对基线：2026-10-26 · 代码 ca4d511
> 历史验证（代码 6f11831；记录于文档提交 3ccb3de）：`swift test` 1401 例 0 失败（63.1s）；定向验证 `FleetCostTextPropagationTests` 4 例、`UsageReportBuilderTests|SettingsDraftIsolationTests` 15 例均通过。
> 2026-10-25 提交前全量验证（即本基线工作区）：`swift test` 1435 例 0 失败（64.5s），覆盖独立 `.deviceId` 身份、默认上报周期跟随常规、菜单 / 设置自启同步、来源级日桶更新 / 输入摘要回执、节点卡片缺桶 / partial / 完整零提示，以及主节点健康用量 + DSH 失败 + 空副节点真实 POST 接入的集成回归。未替换或重启现场应用，DSH 解压依赖缺失仍通过来源不可用提示表达。
