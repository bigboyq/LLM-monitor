# LLM Monitor 中文帮助

[返回中文 README](../README.md) · [English Help](help.en.md)

## 系统要求

- macOS 14 Sonoma 或更高版本。
- Apple Silicon 与 Intel Mac 均可运行。
- 菜单栏需要有足够空间显示应用图标。
- 远程额度查询需要网络；本地 token 扫描本身不会上传本地会话数据库。

## 安装与首次启动

1. 从 [GitHub Releases](https://github.com/bigboyq/LLM-monitor/releases/latest) 下载 DMG，并对照同一 Release 中的 `SHA256SUMS.txt` 校验。
2. 打开 DMG，把 `LLM-monitor.app` 拖到 `/Applications`。
3. 当前 snapshot 未经 Apple notarization。若首次启动被阻止，请在 Finder 中右键应用，选择“打开”，再确认一次。
4. 点击菜单栏图标，选择底部的“设置”。首次启动会创建本地配置，但不会默认启用任何 Provider。
5. 启用需要的 Provider，填写凭据或本地认证路径，然后保存并刷新。

校验下载文件：

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## Provider 配置

### Minimax Token Plan

在设置中启用 Minimax 并填写 Token Plan API Key。本地用量读取 `~/.minimax/v2/sqlite/runtime-state.sqlite`；如需叠加 OpenCode 中的 `minimax-cn-coding-plan` 用量，开启“合并 OpenCode 数据”。

### ChatGPT Plan / Codex

先确保 Codex CLI 已登录，并且 `~/.codex/auth.json` 存在。默认认证路径通常无需修改。应用从 ChatGPT usage API 获取额度，并从 `~/.codex/sessions` 与 `~/.codex/archived_sessions` 汇总本地用量。

### Antigravity

先启动并登录 Antigravity IDE 或 `agy` CLI。应用自动发现本机 `language_server`，通过 loopback RPC 获取账号、额度和 trajectory token 信息。若显示服务离线，请确认 Antigravity 仍在运行并已完成登录。

### GLM Coding Plan

填写 Coding Plan Key，通常为 `id.secret` 格式。远程 API 提供额度；本地 ZCode 用量来自 `~/.zcode/cli/db/db.sqlite`。高峰窗口默认是本机时区的周一至周五 14:00–18:00，可在设置中调整。

### DeepSeek

填写 `sk-...` 格式的 DeepSeek API Key。卡片显示账户余额；DeepSeek 没有 native 本地账本，只有开启 OpenCode 合并后才会显示本地 token 图表。高峰提示按北京时间计算，默认周末平价。

### OpenCode 合并

应用读取 `~/.local/share/opencode/opencode.db`，按 `providerID` 分片。OpenCode 不是独立卡片；请在每个 Provider 的设置页单独开启或关闭合并。GLM 默认开启，其他 Provider 默认关闭。

## 日常操作

- 点击菜单栏图标：打开或关闭主面板。
- 点击右上角刷新按钮：立即刷新全部 Provider。
- 右键单张卡片：刷新该 Provider 或打开配置文件。
- 悬停卡片标题、额度行或底部用量：查看账号、窗口、最近请求及七天图表。
- 设置 → 通用：修改刷新间隔、状态栏图标、状态圆点显示开关和开机自启动。开关开启时，右下角显示 10pt 状态圆点：绿色表示额度健康，橙色表示预警，红色表示异常。
- 禁用的 Provider 不会显示卡片，也不会发起网络请求。

## 配置与本地文件

| 内容 | 路径 |
|---|---|
| 配置 | `~/Library/Application Support/LLM-monitor/config.json` |
| 日志 | `~/Library/Application Support/LLM-monitor/log.txt` |
| 远程额度最近成功状态 | `~/Library/Application Support/LLM-monitor/last-refresh.json` |
| Minimax scanner 缓存 | `~/.minimax/.token-monitor/` |
| Antigravity scanner 缓存 | `~/.gemini/antigravity/.token-monitor/` |
| ZCode scanner 缓存 | `~/.zcode/cli/.token-monitor/` |
| OpenCode scanner 缓存 | `~/.local/share/opencode/.token-monitor/` |

配置保存后会自动重载。若配置无法解析，应用会先备份为同目录的 `config.json.corrupt-*.json`，再恢复默认配置。请勿把真实 API Key 提交到 Git 仓库、issue 或日志附件中。

## 常见问题

### 菜单栏没有图标

应用是纯菜单栏程序，不会显示 Dock 图标。先在“活动监视器”确认 `LLM-monitor` 正在运行；菜单栏空间不足时，关闭部分常驻图标后重试。应用使用单实例锁，重复启动不会打开第二份。

### 显示“未配置”或灰色状态点

确认 Provider 已启用，凭据不是模板占位符，并保存设置。灰点表示尚未获得一次成功数据，不一定代表故障。

### 额度刷新失败

检查网络、API Key、套餐类型和本地登录状态。应用会自动退避重试；也可右键对应卡片手动刷新。详细错误在 `log.txt`，分享日志前请检查并脱敏。

### 本地 token 用量为空

对应客户端必须实际产生过会话记录。确认数据库/会话路径存在，并授予应用读取这些用户目录的权限。Antigravity 还要求本地服务正在运行；DeepSeek 需要启用 OpenCode 合并才有本地用量。

### 无法开启“开机自启动”

先把应用移动到 `/Applications`。若 macOS 显示需要批准，请前往“系统设置 → 通用 → 登录项”完成授权。

### macOS 阻止打开应用

当前 Release 是 ad-hoc 签名的 snapshot。先核对 SHA-256，然后在 Finder 中右键应用并选择“打开”。不要对来源不明的副本绕过 Gatekeeper。

## 卸载

1. 在设置中关闭开机自启动并退出应用。
2. 删除 `/Applications/LLM-monitor.app`。
3. 如需同时清除设置和日志，删除 `~/Library/Application Support/LLM-monitor/`。
4. 各客户端的原始数据库不会被删除；`.token-monitor` 缓存目录可按上表单独移除，并可由应用重新生成。

## 隐私说明

API Key 只作为认证信息发给对应 Provider 的 HTTPS endpoint，不写入应用日志。本地 scanner 读取当前用户目录中的使用记录并在本机聚合，不会由 LLM Monitor 上传这些数据库。配置目录权限为 `0700`，配置和日志文件权限为 `0600`。
