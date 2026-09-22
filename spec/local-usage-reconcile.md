# LocalUsage reconcile 分层策略

## 目标

LocalUsage 的触发原因、是否需要执行一次 reconcile、以及某个 Provider 是否真的需要重算，必须是三层独立决策。`dirty` 不能直接等价为“全量重算”，`full` 也不能直接等价为“绕过缓存”。这样才能让一次 Provider quota 事务只产生一次全局 reconcile，同时避免没有本地变化时重新读取大文件或重新请求 Antigravity trajectory。

## 三层模型

```text
触发层
  startup / automatic batch / manual / wakeup / source dirty / calendar invalidation
                         |
                         v
协调层（LocalUsageOrchestration）
  coalesce in-flight reconcile
  首次启动 -> cache-assisted-full
  普通事件 -> dirty-reconcile
  日历失效/显式恢复 -> hard-full
                         |
                         v
Provider 策略层
  stat/fingerprint -> unchanged / append-only / rewrite / missing / uncertain
                         |
                         v
执行层
  reuse cache / rebase / offset or suffix / bounded full rebuild / last-good
```

## 三种扫描模式

| 模式 | 全局含义 | Provider 行为 |
| --- | --- | --- |
| `full` | 启动首拍需要建立并验证完整 source inventory | 仍先使用 Provider 缓存和 fingerprint；未变化直接复用，变化源按自己的安全策略处理 |
| `dirty` | 普通 reconcile，dirty 是 freshness 提示 | 仍必须重新 stat/fingerprint；没有变化可以 no-op/rebase，有变化才增量或重算 |
| `hardFull` | 操作者或日历失效明确要求绕过缓存 | 只在支持该语义的 Provider 执行 cold rebuild；失败保留 last-good，并保留 dirty 让下一次普通 reconcile 重试 |

FSEvents/vnode 只负责把 source 标记为 dirty 和驱动 freshness UI；它不直接启动一个新的扫描，也不决定扫描范围。Provider batch settled 后由唯一的 reconcile 协调器消费这个状态。

协调器只有一个待处理模式槽位，优先级为 `dirty < full < hardFull`；运行期间到达的请求只提升这个槽位，不再创建并行 reconcile。日历/时区失效使用单调 revision 标记：如果失效发生在当前事务期间，当前事务不能消费这次失效，事务结束后必须再执行一次 `hardFull`。

## Provider 策略矩阵

| Provider | 变化识别 | 普通/启动策略 | 不安全变化的兜底 |
| --- | --- | --- | --- |
| Antigravity | session + WAL `mtime/size`，并校验枚举是否完整；缓存带日历签名 | 未变化复用 `antigravity.json`；append 使用 generator metadata offset；只替换 dirty session 的 daily/sample 贡献 | shrink、缺 cache、日历变化、枚举不完整、RPC 失败保留 last-good；设置页 hard-full 才逐 session cold RPC，结果不完整时保持 dirty |
| MiniMax | runtime DB + WAL 指纹，逐 source cache；缓存带日历签名 | 未变化复用；变化 source 重聚合最近窗口，保留 sample cache | stat/SQL 不确定、日历变化或 session 失败时保留 last-good，不推进成功指纹，结果不完整时保持 dirty |
| GLM / OpenCode | DB + WAL 指纹，快照带日历签名 | 未变化 rebase 本地日窗口；变化时重建单库 snapshot | DB/WAL 不可读、日历变化或 cache 版本不匹配时重建；失败不覆盖 last-good |
| DSH | session 文件集合和每文件 fingerprint；聚合快照带日历签名 | 未变化复用；只解析变化文件，复用 parsed-file cache | 删除/压缩重写/预算截断等不安全状态回退单文件或受限全量；单文件失败时整份 index 保持 last-good 且保持 dirty，避免 fingerprint 与 aggregate 不一致 |
| Codex | session JSONL per-file `mtime/size`，并检测 append/truncate/rewrite | 进程内未变化复用；append 从 offset 续读；启动 cache 缺失时冷扫一次 | truncate、同尺寸改写、部分行或预算未读保留 pending，下一拍续读/重扫；当前事件 cache 不跨进程持久化 |

## 事务和并发契约

1. Scheduler 的一个自动 batch 可以包含同时到期的多个 Provider，并行执行 quota；全局排他覆盖 quota batch 到 LocalUsage reconcile 完成的整个事务。
2. Manual/Wakeup 不在运行中的事务期间排队成第二个刷新事务；入口应直接拒绝或由明确的 wakeup pending 机制合并，不能一边清理旧 deadline 一边继续执行旧任务。
3. `refreshOne` 也必须经过同一个全局事务入口；它不能绕过 LocalUsage reconcile 或 gate。
4. regular Interval 从完整事务完成时间结算；旧 generation 在取消、stop、配置重载后不能写回新的 deadline、freshness 或 cache。
5. 自动 batch 只触发一次 reconcile；启动错峰 quota 结束后只触发一次 cache-assisted-full。Provider 之间可以分批控制内存峰值，但不能把每个 Provider 拆成一次全局 full scan。
6. Scanner 的结果必须区分完整和可重试的 partial；partial 可以暂时展示，但不能推进 freshness、日历签名或成功 fingerprint。旧 generation 不能释放新 generation 的 gate，也不能覆盖新的 deadline、freshness 或 cache。

## 执行阶段

### 已落地

- 将 `full` 和 `hardFull` 语义分开；启动 full 改为 cache-assisted。
- MiniMax、GLM、OpenCode、DSH、Codex 不再因为启动 `full` 无条件绕过自身缓存。
- 日历/时区失效进入 `hardFull`；手工、唤醒、自动和普通日切保留 dirty/offset 路径。
- 保留 Antigravity 设置页显式 hard-full，不扩大为全局硬全量。
- 所有可持久化的日窗口快照都绑定 calendar/time-zone signature；冷启动遇到缺失或不匹配的签名会重建。
- Antigravity、MiniMax 和 DSH 的 partial/文件失败不会被标记为 fresh；DSH 在失败轮次不改动 index，保留上一份自洽的成功聚合和 fingerprint。
- reconcile 使用单一 `pendingMode` 和 calendar revision，保证 in-flight 的 `hardFull` 不被 dirty 降级或吞掉。

### 下一阶段

- 为每个 Provider 输出统一的 decision log：`sourceFingerprint`、`decision`、`readBytes`、`rpcCount`、`cacheHit`、`fallback` 和 `commit`。
- 将 Codex event cache 持久化评估为独立任务；在没有可靠跨进程 cache 前，重启 cold scan 是有意的兜底。
- 以实际数据验证 startup、manual、automatic、calendar invalidation 四条路径的 no-op/incremental/full 比例和内存峰值，再决定是否引入 MiniMax ledger watermark 或其他 Provider 的增量接口。

## 验收条件

- 无源变化时，启动 `full` 不产生 Antigravity trajectory RPC、不重读 DSH 大文件、不执行 SQLite 聚合。
- append-only 变化只消费可安全续读的 suffix；truncate、rewrite、删除和不完整枚举必须进入对应 fallback。
- dirty 在扫描期间再次发生时，当前结果可以提交但 freshness 必须继续为 dirty，下一次 reconcile 才消费新变化。
- hard-full 是显式可见、可测试、可取消的恢复操作，不会被普通 dirty 或自动 full 误触发。
- 自动 batch、Manual、Wakeup、calendar invalidation 均只有一个全局 LocalUsage reconcile；完整测试和 release build 通过。
