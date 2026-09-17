# LLM Monitor 中文帮助

[返回中文 README](../README.md) · [English Help](help.en.md)

## 系统要求

- macOS 14 Sonoma 或更高版本。
- 需要 Apple Silicon Mac（arm64）。
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

在设置中启用 Minimax 并填写 Token Plan API Key。本地用量读取 `~/.minimax/v2/sqlite/runtime-state.sqlite`；如需叠加 OpenCode 中的 `minimax-cn-coding-plan` 用量，把 `config.json` 中对应的 `clientBindings` 设为 `true`（见下文“OpenCode 合并”）。

### ChatGPT Plan / Codex

先确保 Codex CLI 已登录，并且 `~/.codex/auth.json` 存在。默认认证路径通常无需修改。应用从 ChatGPT usage API 获取额度，并从 `~/.codex/sessions` 与 `~/.codex/archived_sessions` 汇总本地用量。

### Antigravity

先启动并登录 Antigravity IDE 或 `agy` CLI。应用自动发现本机 `language_server`，通过 loopback RPC 获取账号、额度和 trajectory token 信息。若显示服务离线，请确认 Antigravity 仍在运行并已完成登录。

### GLM Coding Plan

填写 Coding Plan Key，通常为 `id.secret` 格式。远程 API 提供额度；本地 ZCode 用量来自 `~/.zcode/cli/db/db.sqlite`。高峰窗口默认是本机时区的周一至周五 14:00–18:00，可在设置中调整。

ZCode 的任务按 provider 分为日常（Coding Plan）/ 闲时 / 其他智谱套餐三类：只有日常任务计入 5h / 周额度窗口，三类 token 都计入本地柱图；设置 → 客户端 → ZCode 可查看按分类拆分的柱图与名义价值。开启设置中的「解析活动套餐余额日志」后，卡片还会显示 zcode 活动套餐（如周末体验套餐）的剩余百分比与过期时间，数据来自 ZCode 本地余额轮询日志（`~/.zcode/v2/logs`），只读本地文件，默认关闭。

### DeepSeek

填写 `sk-...` 格式的 DeepSeek API Key。卡片显示账户余额；DeepSeek 没有 native 本地账本，只有启用 OpenCode 合并（`config.json` 的 `clientBindings`）后才会显示本地 token 图表。DeepSeek Flash 本地成本估算为：输入 ¥1/百万 token、缓存读取 ¥0.02/百万 token、输出 ¥4/百万 token；北京时间周一至周五 9:00–12:00、14:00–18:00 忙时按 2 倍计算，周末全天平价。

### OpenCode 合并

应用读取 `~/.local/share/opencode/opencode.db`，按 `providerID` 分片。OpenCode 不是独立卡片；合并由 `~/Library/Application Support/LLM-monitor/config.json` 中 `clientBindings[]` 的 `opencode` 绑定控制（GLM 默认开启，其他 Provider 默认关闭），设置页不提供独立开关。手工修改该文件并保存后应用会热加载，无需重启。

## 日常操作

- 点击菜单栏图标：打开或关闭主面板。
- 点击右上角刷新按钮：立即刷新全部 Provider。
- 右键单张卡片：刷新该 Provider 或打开配置文件。
- 悬停卡片标题、额度行或底部用量：查看账号、窗口、最近请求及七天图表。
- 设置 → 常规：修改刷新间隔、状态栏图标、状态圆点显示开关和开机自启动。状态栏图标支持系统符号和 App 图标；App 图标是实时额度仪表盘，左右分别显示 5 小时与周额度弧线，中间用扇区显示当前剩余额度，底部最多显示 3 个模型健康度点，顶部圆点显示节能/睡眠健康度。
- 设置 → 常规 → 「主菜单 Provider 顺序」：用每行右侧的上/下箭头按钮调整主菜单 Provider 卡片的显示顺序；未自定义时按 Provider 名称排序。该顺序只作用于主菜单，客户端 tab 与设置页的 Provider 列表仍按字母排序。
- 底部「节能」按钮：单击就地开启/关闭「防止休眠」临时内存开关（右上角圆点同步反映三色睡眠健康状态）；详细排障进入设置窗口「节能」Tab。
- 禁用的 Provider 不会显示卡片，也不会发起网络请求。
- 客户端用量价值只覆盖有公开价格的模型；如果同一段用量包含未知模型，菜单和 7 天表格会显示“部分计价”。

## 系统睡眠健康度与节能管理

应用在主面板底部提供「节能」快捷按钮（带三色状态圆点），并在「设置 → 节能」提供完整的睡眠健康度诊断与系统电源参数矩阵：
- **快捷防休眠切换**：单击主面板底部的「节能」按钮即可就地开启/关闭「防止休眠」模式。指示灯变红时表示防休眠已激活；此开关为纯内存开关，退出应用或重启后自动复位为关闭，安全无后患。
- **三色健康度指示**：
  - 🟢 **绿色**：系统休眠机制正常，无外部应用霸占睡眠锁且已开启自动休眠；
  - 🟡 **黄色**：休眠受阻（检测到第三方应用持有睡眠锁，或插电下 `ac_sleep=0` 禁用了自动休眠）；
  - 🔴 **红色**：已手动开启「防止休眠」模式。
- **排障诊断与电源参数**：前往「设置 → 节能」可查看具体有哪些外部进程（带 PID 与持有时长）在霸占睡眠锁，以及 `sleep`、`womp`、`tcpkeepalive`、`powernap`、`displaysleep` 等关键系统电源参数在电源适配器与电池下的当前取值与修复指引。

## 通知与 Bark 推送

有窗口额度的 Provider（ChatGPT/Codex、GLM、Minimax、Antigravity）支持四类额度事件，每类可独立选择通知渠道（不通知 / 仅系统通知 / 系统通知 + Bark）：

| 事件 | 触发时机 |
|---|---|
| 5 小时额度恢复 | 剩余比例回升超过 5 个百分点，或回到 98% 以上 |
| 5 小时额度耗尽 | 剩余比例降到约 0%（边沿触发一次，不重复提醒） |
| 周额度恢复 / 耗尽 | 同上，作用于周窗口 |

- 每个窗口类 Provider 的设置页顶部有「通知配置」节；渠道默认与历史行为一致：恢复 → 系统通知、耗尽 → 不通知（恢复的判定阈值本身是新规则，见上表）。
- 系统通知由 macOS 投递，前台也会显示横幅；权限在应用启动且状态为“未决定”时才申请。若之前选择了拒绝，请到“系统设置 → 通知 → LLM Monitor”重新允许。
- Bark 推送在「设置 → 常规 → Bark 推送」配置：服务端地址（默认官方 `api.day.app`，支持自建 https 地址，可保留反向代理子路径）、Device Key（从 Bark App 复制）、可选铃声、分组与消息有效期 TTL（秒；大于 0 时消息到期后手机端自动删除，留空或 0 = 不自动过期）。保存后可用“发送测试推送”验证。
- Bark 推送按 Provider + 模型生成稳定覆盖 ID：同一模型的新推送会覆盖手机上的旧通知，不会堆积历史提醒。
- 「人在电脑前时跳过推送」开启后，屏幕亮着且未锁屏时跳过 Bark（此时看得到系统通知）；显示器休眠或已锁屏（人不在）时正常推送。
- 事件检测基于持久化的基线文件：应用没有运行期间发生的耗尽 / 恢复，会在启动后第一次刷新时补报一次。

## 配置与本地文件

| 内容 | 路径 |
|---|---|
| 配置 | `~/Library/Application Support/LLM-monitor/config.json` |
| 日志 | `~/Library/Application Support/LLM-monitor/log.txt` |
| 远程额度最近成功状态 | `~/Library/Application Support/LLM-monitor/last-refresh.json` |
| 通知触发器基线 | `~/Library/Application Support/LLM-monitor/notification-state.json` |
| Minimax scanner 缓存 | `~/.minimax/.token-monitor/` |
| Antigravity scanner 缓存 | `~/.gemini/antigravity/.token-monitor/` |
| ZCode scanner 缓存 | `~/.zcode/cli/.token-monitor/` |
| OpenCode scanner 缓存 | `~/Library/Application Support/LLM-monitor/token-monitor/` |
| DSH scanner 缓存 | `~/.dsh/.token-monitor/` |

配置保存后会自动重载。若配置无法解析，应用会先备份为同目录的 `config.json.corrupt-*.json`，再恢复默认配置。请勿把真实 API Key 提交到 Git 仓库、issue 或日志附件中。

## 常见问题

### 菜单栏没有图标

应用是纯菜单栏程序，不会显示 Dock 图标。先在“活动监视器”确认 `LLM-monitor` 正在运行；菜单栏空间不足时，关闭部分常驻图标后重试。应用使用单实例锁，重复启动不会打开第二份。

### 显示“未配置”或灰色状态点

确认 Provider 已启用，凭据不是模板占位符，并保存设置。灰点表示尚未获得一次成功数据，不一定代表故障。

### 额度刷新失败

检查网络、API Key、套餐类型和本地登录状态。应用会按固定刷新间隔自动重试；也可右键对应卡片手动刷新。详细错误在 `log.txt`，分享日志前请检查并脱敏。

### 本地 token 用量为空

对应客户端必须实际产生过会话记录。确认数据库/会话路径存在，并授予应用读取这些用户目录的权限。Antigravity 还要求本地服务正在运行；DeepSeek 需要启用 OpenCode 合并才有本地用量。

### 无法开启“开机自启动”

先把应用移动到 `/Applications`。若 macOS 显示需要批准，请前往“系统设置 → 通用 → 登录项”完成授权。

### 收不到 Bark 推送

依次确认：Bark 已启用且服务端地址、Device Key 填写完整；用“发送测试推送”验证连通性（仅支持 https 与本机 http 调试地址）；对应事件的渠道选了「Bark + 系统通知」；若开启了「人在电脑前时跳过推送」，屏幕亮着且未锁屏时会被有意跳过。Bark 服务端需 v2.2.5+、Bark App 需 v1.5.2+ 才支持覆盖 ID。发送失败会在 `log.txt` 记录状态码（不含凭据）。

### macOS 阻止打开应用

当前 Release 是 ad-hoc 签名的 snapshot。先核对 SHA-256，然后在 Finder 中右键应用并选择“打开”。不要对来源不明的副本绕过 Gatekeeper。

## 卸载

1. 在设置中关闭开机自启动并退出应用。
2. 删除 `/Applications/LLM-monitor.app`。
3. 如需同时清除设置和日志，删除 `~/Library/Application Support/LLM-monitor/`。
4. 各客户端的原始数据库不会被删除；`.token-monitor` 缓存目录可按上表单独移除，并可由应用重新生成。

## 隐私说明

API Key 只作为认证信息发给对应 Provider 的 HTTPS endpoint，不写入应用日志。本地 scanner 读取当前用户目录中的使用记录并在本机聚合，不会由 LLM Monitor 上传这些数据库。配置目录权限为 `0700`，配置和日志文件权限为 `0600`。
