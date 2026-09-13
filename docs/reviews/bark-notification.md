# Bark Notification 分支代码 Review

## 1. Review 信息

- Review 分支：`feat/bark-notification`
- 对比分支：`main`
- Review 日期：2026-09-13
- 涉及提交：4 个
- 涉及文件：10 个
- Review 范围：Bark 推送、额度事件检测、通知渠道配置、设置页、配置持久化及测试

## 2. 结论

当前实现的整体架构比较清晰，已经完成了通知器抽象、Bark 配置注入、事件检测与基础测试，具备继续迭代的基础。

但建议暂缓合并，优先修复以下两个问题：

1. 同一模型多个事件合并时，“不通知”的事件仍可能出现在其他渠道的通知正文中。
2. Bark 覆盖通知 ID 依赖当前事件类型组合，事件组合变化后无法覆盖旧通知，仍会产生历史通知堆积。

这两个问题都会直接影响用户收到的通知内容和数量。

## 3. 验证结果

本地执行：

```text
swift test
```

结果：446 个测试全部通过，0 失败。

此外，`git diff --check main...HEAD` 未发现空白或补丁格式问题。

当前工作区已有用户修改的 `.build_number`，本次 Review 未修改或覆盖该文件。

## 4. 风险明细

### R1 — 高风险：禁用事件仍可能被包含在通知正文中

相关代码：

- [`QuotaUpdateNotifier.swift:212`](../../Sources/LLM-monitor/Services/QuotaUpdateNotifier.swift#L212)
- [`QuotaUpdateNotifier.swift:214`](../../Sources/LLM-monitor/Services/QuotaUpdateNotifier.swift#L214)
- [`QuotaUpdateNotifier.swift:335`](../../Sources/LLM-monitor/Services/QuotaUpdateNotifier.swift#L335)

`QuotaEventBatch` 按模型计算通知渠道并集，但 `lines` 使用模型的全部事件：

```swift
lines: modelEvents.map(SystemQuotaUpdateNotifier.messageLine)
```

例如用户配置为：

- 5 小时额度恢复：系统通知
- 周额度耗尽：不通知

当两个事件同时发生时，系统通知仍会包含“周额度耗尽”这一行。Bark 也存在同样行为。

这会使“独立配置每类事件”的设置语义失效。

改进建议：

- 在每个通知器内部按目标渠道过滤事件正文；或
- 构建按渠道拆分的事件组，例如 `systemEvents` 和 `barkEvents`；或
- 如果产品确实希望采用“模型级并集”语义，应在 UI 和文档中明确说明：只要模型有一个事件触发，该模型本次所有事件都会进入通知。

建议补充混合渠道场景的单元测试。

### R2 — 高风险：Bark 覆盖 ID 在事件组合变化时失效

相关代码：

- [`QuotaUpdateNotifier.swift:224`](../../Sources/LLM-monitor/Services/QuotaUpdateNotifier.swift#L224)
- [`QuotaUpdateNotifier.swift:231`](../../Sources/LLM-monitor/Services/QuotaUpdateNotifier.swift#L231)

当前 ID 包含当前刷新中所有事件类型的集合：

```text
llmmonitor-{providerID}-{model}-{kinds}
```

因此以下两次推送不会覆盖：

```text
第一次：provider/model/intervalRestored
第二次：provider/model/intervalRestored-weeklyRestored
```

因为两次生成的 ID 不同，第一次通知会继续保留。类似地，从“双事件”变成“单事件”时也会产生新的通知。

改进建议：

- 如果坚持模型级合并，使用稳定的 `providerID + modelName` 作为 ID；或
- 取消模型内合并，按事件类型单独推送，并使用 `providerID + modelName + kind` 作为 ID；或
- 维护每个模型/事件类型的状态，将合并后的最新正文同步到所有相关 ID。

当前“同类事件覆盖、不同类型互不影响”的注释与实际行为不一致，建议同步修正文档或实现。

官方 Bark 文档说明，相同 `id` 会更新对应通知，且该能力需要 Bark v1.5.2+ / bark-server v2.2.5+：[Bark 官方 API 文档](https://github.com/Finb/Bark/blob/master/docs/en-us/tutorial.md)。

### R3 — 中风险：系统通知线程缺少 Provider 维度

相关代码：

- [`QuotaUpdateNotifier.swift:367`](../../Sources/LLM-monitor/Services/QuotaUpdateNotifier.swift#L367)
- [`QuotaUpdateNotifier.swift:374`](../../Sources/LLM-monitor/Services/QuotaUpdateNotifier.swift#L374)

线程 ID 当前为：

```text
quota-update-{modelName}
```

不同 Provider 中同名模型会进入同一个 macOS 通知线程，例如 `minimax/general` 和 `antigravity/general`。

建议改为：

```text
quota-update-{providerID}-{modelName}
```

同时建议在通知请求的日志标识中也保留 Provider 信息，便于排查。

### R4 — 中风险：自建 Bark 服务的 base path 会被覆盖

相关代码：

- [`BarkNotifier.swift:153`](../../Sources/LLM-monitor/Services/BarkNotifier.swift#L153)
- [`BarkNotifier.swift:162`](../../Sources/LLM-monitor/Services/BarkNotifier.swift#L162)

`buildURL` 解析 server URL 后直接替换 `percentEncodedPath`。如果用户配置：

```text
https://example.com/bark
```

最终请求会变成：

```text
https://example.com/{key}/{title}/{body}
```

其中 `/bark` 被丢弃，部署在反向代理子路径下的自建服务无法工作。

改进建议：

- 保留并规范化 server URL 的 base path；或
- 使用 Bark 的 POST JSON API，将服务端入口和通知参数分离。

Bark 官方文档同时定义了 GET 路径参数和 POST/JSON 请求形式：[Bark Sending Push Notifications](https://github.com/Finb/Bark/blob/master/docs/en-us/tutorial.md)。

### R5 — 中风险：配置 trim 只用于校验，实际请求仍使用原值

相关代码：

- [`BarkNotifier.swift:130`](../../Sources/LLM-monitor/Services/BarkNotifier.swift#L130)
- [`BarkNotifier.swift:132`](../../Sources/LLM-monitor/Services/BarkNotifier.swift#L132)

`effectiveConfig` 使用 trim 后的 server/key 判断是否为空，但返回的是原始 `BarkConfig`。手工配置如下内容时：

```text
serverURL = "https://api.day.app "
deviceKey = " key "
```

实际请求可能将空格编码到 URL 中，导致服务端无法识别 Device Key 或 URL。

建议在 `effectiveConfig` 中返回规范化后的配置副本，而不是只使用规范化值做校验。

### R6 — 中风险：缺少推送节流、重试与并发控制

相关代码：

- [`BarkNotifier.swift:84`](../../Sources/LLM-monitor/Services/BarkNotifier.swift#L84)
- [`BarkNotifier.swift:98`](../../Sources/LLM-monitor/Services/BarkNotifier.swift#L98)

每个模型都会创建一个非结构化 `Task`。在以下场景下可能产生突发请求：

- 多个模型同一轮同时发生事件；
- 刷新间隔较短；
- 额度因服务端波动在阈值附近反复变化；
- Bark 服务端短暂失败后用户重复刷新。

建议增加：

- 每个 Provider/模型的冷却时间；
- 有界并发；
- 短暂网络错误的有限重试；
- 可取消、可追踪的发送任务集合。

### R7 — 低至中风险：测试推送与正式推送配置不完全一致

相关代码：

- [`SettingsView.swift:1025`](../../Sources/LLM-monitor/Views/SettingsView.swift#L1025)
- [`SettingsView.swift:1034`](../../Sources/LLM-monitor/Views/SettingsView.swift#L1034)

测试推送使用当前表单草稿，但没有携带 `group`，也没有应用 `skipWhenUnlocked`。用户点击测试按钮时验证的不是完整的正式发送路径。

建议让测试推送复用统一的请求构造和发送逻辑，至少保证以下配置一致：

- server URL；
- Device Key；
- sound；
- group；
- 锁屏跳过策略。

### R8 — 低至中风险：Device Key 的保护级别低于普通输入字段

相关代码：

- [`SettingsView.swift:382`](../../Sources/LLM-monitor/Views/SettingsView.swift#L382)
- [`ConfigStore.swift:112`](../../Sources/LLM-monitor/Services/ConfigStore.swift#L112)

Device Key 当前使用普通 `TextField`，并与配置一起保存到 `config.json`。项目现有 API Key 也采用明文配置，但 Bark Device Key 同样具备推送凭证属性。

建议：

- 至少使用 `SecureField`；
- 更严格的方案是迁移到 Keychain；
- 错误日志中避免输出完整 URL、Device Key 或自建服务响应中的敏感内容。

## 5. 测试覆盖建议

建议新增以下测试：

1. 同一模型同时出现 `system` 与 `none` 事件时，禁用事件不会出现在系统通知正文。
2. 同一模型事件集合从单事件变为双事件时，Bark ID 的覆盖行为符合设计。
3. 不同 Provider 的同名模型不会共享系统通知 thread。
4. server URL 带 `/bark` 等 base path 时，最终 URL 保留该路径。
5. server URL 和 Device Key 包含首尾空白时会被规范化。
6. 非法 scheme（如 `ftp`、`file`）被拒绝，或至少给出明确错误。
7. Bark HTTP 失败、超时和取消行为。
8. 测试推送完整复用正式推送参数。

现有 Bark 测试使用固定时间的 `RunLoop` 等待异步请求，例如 0.2/0.5 秒。建议改为 `XCTestExpectation`，减少 CI 上的偶发 flaky。

## 6. 做得较好的部分

- `QuotaEventDetector`、`QuotaEventBatch`、系统通知和 Bark 通知职责拆分较清晰。
- `CompositeQuotaUpdateNotifier` 让新增通知渠道不需要继续扩大 `AppState` 的职责。
- 新增配置字段基本保持向后兼容，缺失字段可以沿用旧行为。
- 对错误渠道枚举和 Bark 配置字段做了容错解码，降低手工配置导致整份配置损坏的概率。
- Bark URL 的路径段和 query 参数进行了编码处理，覆盖了中文、空格、换行等常见内容。
- 已有完整测试集全部通过，说明本次改动没有引入明显的编译或现有行为回归。

## 7. 建议实施顺序

### 第一阶段：合并前必须修复

1. 明确并实现混合事件的渠道过滤语义。
2. 重设计 Bark 覆盖 ID，并增加事件组合变化测试。
3. 修复系统通知 thread 的 Provider 冲突。

### 第二阶段：增强自建服务兼容性

1. 保留 server base path。
2. 限制 scheme 为 `https`，开发环境单独允许本地 HTTP。
3. 评估迁移到 POST JSON API。

### 第三阶段：可靠性与安全增强

1. 增加发送节流、重试和任务取消。
2. 统一正式推送与测试推送路径。
3. 使用 `SecureField`，并评估使用 Keychain 保存 Device Key。
4. 将异步测试改为 `XCTestExpectation`。
