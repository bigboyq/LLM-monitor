# LLM Monitor

[English](README.en.md) | **简体中文**

适用于 macOS 14 及以上版本的菜单栏额度与本地用量监视器。一个入口集中查看 Minimax、ChatGPT/Codex、Antigravity、GLM Coding Plan 与 DeepSeek，并可选择合并 OpenCode 的本地 token 账本。

> 当前版本：**1.4.2** · 支持 Apple Silicon 与 Intel Mac · 所有凭据和用量缓存只保存在本机

## 下载与安装

1. 从 [GitHub Releases](https://github.com/bigboyq/LLM-monitor/releases/latest) 下载 `LLM-monitor-1.4.2.dmg`。
2. 打开 DMG，将 **LLM-monitor.app** 拖到 **Applications**。
3. 启动应用，点击菜单栏图标，进入“设置”启用并配置需要的 Provider。

当前公开版本使用 ad-hoc 签名，未经过 Apple notarization。若 macOS 阻止首次打开，请在 Finder 中右键应用并选择“打开”；请只安装本仓库 Releases 提供、且 SHA-256 与 `SHA256SUMS.txt` 一致的文件。

## 主要能力

- 在菜单栏集中查看额度、余额、重置时间、健康状态和最近刷新结果。
- 保留用户选择的菜单栏主图标，并可通过右下角绿、橙、红色圆点快速识别整体健康状态。
- 当同一模型的剩余额度较上一次成功请求增加时发送 macOS 通知；应用启动时检查通知权限。
- 汇总 Codex、Minimax、Antigravity、ZCode 与 OpenCode 的本地 token 用量。
- 支持每个 Provider 独立刷新、失败退避、手动刷新和配置热重载。
- 提供 GLM/DeepSeek 高峰时段提示、最近 7 天图表和开机自启动。
- 配置目录权限为 `0700`，配置、日志与凭据文件权限为 `0600`。

## 界面预览

<p align="center">
  <img src="docs/images/menu-overview.png" alt="LLM Monitor 菜单栏主面板" width="420">
</p>

<p align="center"><sub>集中查看 Provider 额度、余额、重置时间、高峰提示和本地用量。</sub></p>

<table>
  <tr>
    <td><img src="docs/images/settings-general.png" alt="LLM Monitor 通用设置界面"></td>
    <td><img src="docs/images/token-usage-seven-days.png" alt="最近七天 Token 用量图表"></td>
  </tr>
  <tr>
    <td align="center">通用设置与 Provider 导航</td>
    <td align="center">最近七天 Token 用量明细</td>
  </tr>
</table>

## 支持的 Provider

| Provider | 远程数据 | 本地用量 | 认证方式 |
|---|---|---|---|
| Minimax Token Plan | 套餐额度 API | Minimax v2 SQLite；可选合并 OpenCode | Token Plan API Key |
| ChatGPT Plan / Codex | ChatGPT usage API | Codex session 日志；可选合并 OpenCode | `~/.codex/auth.json` |
| Antigravity | 本地 language-server RPC | 本地 trajectory metadata RPC；可选合并 OpenCode | 已登录的 Antigravity 会话 |
| GLM Coding Plan | GLM quota API | ZCode SQLite；可选合并 OpenCode | Coding Plan Key |
| DeepSeek | 账户余额 API | 可选合并 OpenCode | DeepSeek API Key |

各数据源、token 口径、高峰窗口和合并规则见下方 Provider 规格文档。

## 文档索引

| 主题 | 中文 | English / 技术规格 |
|---|---|---|
| 安装、配置、日常操作与排错 | [中文帮助](docs/help.zh-CN.md) | [English user guide](docs/help.en.md) |
| 界面结构与交互规则 | [交互设计规格](spec/ui-design.md) | 同一文档 |
| 架构、状态机、刷新与数据模型 | [项目架构规格](spec/overview.md) | 同一文档 |
| Provider 数据源与口径 | [Minimax](spec/providers/minimax.md) · [ChatGPT/Codex](spec/providers/codex.md) · [Antigravity](spec/providers/antigravity.md) · [GLM](spec/providers/glm.md) · [DeepSeek](spec/providers/deepseek.md) · [OpenCode](spec/providers/opencode.md) | 同左 |
| 并发、错误、日志、性能与持久化策略 | [工程策略](docs/policy/) | 同一目录 |
| 版本变化 | [CHANGELOG](CHANGELOG.md) | [Release notes](docs/releases/) |

## 从源码构建

要求：macOS 14+、Xcode / Command Line Tools，以及 Swift 5.10 或更新版本。

```bash
git clone git@github.com:bigboyq/LLM-monitor.git
cd LLM-monitor
swift build
./.build/debug/LLM-monitor
```

直接运行 SwiftPM 生成的裸可执行文件可调试核心功能，但它没有 `.app` Bundle Identifier，因此 macOS 系统通知会被禁用。测试通知时请使用下方脚本构建并启动 `.app`。

运行测试与完整审计：

```bash
./scripts/test.sh
./scripts/audit.sh
```

构建 universal `.app`、DMG 和 SHA-256 校验文件：

```bash
./scripts/build-release.sh 1.4.2 95
```

`build-app.sh` 的参数决定是否会修改仓库内的 `.build_number`：

| 命令 | 版本来源 | 是否递增 `.build_number` |
|---|---|---|
| `./scripts/build-app.sh` | `VERSION` 文件 | 是（本地构建自动 +1） |
| `./scripts/build-app.sh 1.4.1` | 参数 | 是（仅给版本号时仍自动 +1） |
| `./scripts/build-app.sh 1.4.1 94` | 参数 | 否（同时给出版本与 build 号，可重复构建） |

`build-release.sh [version] [build-number]` 永不递增 `.build_number`（省略参数时读取当前值），适合发布前做可重复构建。

默认构建使用 ad-hoc 签名。Developer ID 签名与 notarization 参数见 `scripts/build-app.sh` 和 `scripts/build-dmg.sh` 的文件注释；完整构建与发布约定见[项目架构规格](spec/overview.md#build-and-packaging)。

## 隐私与安全

API Key 只会发送到对应 Provider 的接口，不会写入应用日志。配置、日志和 scanner 缓存均保存在当前用户目录，不会复制到仓库；具体路径及卸载方式见[中文帮助](docs/help.zh-CN.md#配置与本地文件)。
