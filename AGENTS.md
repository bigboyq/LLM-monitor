# AGENTS.md — LLM-monitor

macOS 菜单栏 LLM 配额监控（SwiftPM 单 target，源码在 `Sources/LLM-monitor/`）。本文件约束在本仓库工作的所有人与智能体；项目规则优先于全局默认。

## Spec 优先规则

`spec/` 是代码之外的第二事实源，按主题分文件维护。每份 spec 末尾有一行「核对基线」，声明该文件内容与某 commit 时点的代码逐条核对一致——基线越新，越可以放心当作认知入口。

1. **先读 spec，再按需读代码**：任务涉及现有功能、逻辑、函数时，先读下表对应的 spec 建立整体认知，只有需要实现级细节（确切签名、字面量、行内逻辑）才定位代码。新功能设计同样先读 spec——分层依赖约束与源码地图都在 `spec/overview.md`。
2. **冲突处理**：代码是运行时事实，spec 是设计意图。两者冲突时先判断哪边过期：spec 过期 → 按代码修正 spec；代码疑似违背 spec → 先向用户确认意图再改代码，不要擅自单边定论。
3. **提交前必须同步 spec**：任何功能、逻辑、函数层面的变更（新增/删除/改名、行为、默认值、文件路径、价格表、阈值），提交前必须修订受影响的 spec 小节，并把该文件的核对基线更新为本次 commit。纯测试、纯文档、纯格式改动可豁免。

## Spec 路由表

| 任务涉及 | 先读 |
|---|---|
| 总体架构、分层依赖规则、源码地图 | `spec/overview.md` |
| token 计量、思考分摊、价格表、货币折算 | `spec/accounting.md` |
| 本地 transcript 账本与配额对账（reconcile） | `spec/local-usage-reconcile.md` |
| 通知（阈值提醒、误报防抖） | `spec/notifications.md` |
| 菜单、设置窗口、边缘 dock、hover 面板等 UI | `spec/ui-design.md` |
| 某个 provider/client 的扫描、解析、缓存、帧适配 | `spec/providers/<名>.md`：antigravity / agy / codex / deepseek / dsh / glm / minimax / opencode |

## Spec 修订纪律

- 保持原文件结构、小节划分与中英混排风格；只修漂移、补缺失、删过时，不做无差别重写。
- spec 里的 `file:line` 引用、类型/函数名必须能在代码中 grep 命中；数值断言（价格、阈值、默认值）与代码字面量逐一核对。
- 修订完成后更新文件末尾核对基线行，格式统一为：`> 核对基线：<YYYY-MM-DD> · 代码 <short-commit>`。
