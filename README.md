# LLM Monitor

[English](README.en.md) | **简体中文**

适用于 macOS 14 及以上版本的菜单栏额度与本地用量监视器。一个入口集中查看 Minimax、ChatGPT/Codex、Antigravity、GLM Coding Plan 与 DeepSeek，并可选择合并 OpenCode 的本地 token 账本。

> 当前版本：**1.4.0** · 支持 Apple Silicon 与 Intel Mac · 所有凭据和用量缓存只保存在本机

## 下载与安装

1. 从 [GitHub Releases](https://github.com/bigboyq/LLM-monitor/releases/latest) 下载 `LLM-monitor-1.4.0.dmg`。
2. 打开 DMG，将 **LLM-monitor.app** 拖到 **Applications**。
3. 首次启动后点击菜单栏图标，再进入“设置”启用并配置需要的 Provider。

当前公开 snapshot 使用 ad-hoc 签名，未经过 Apple notarization。若 macOS 阻止首次打开，请在 Finder 中右键应用并选择“打开”；请只安装本仓库 Releases 提供、且 SHA-256 与 `SHA256SUMS.txt` 一致的文件。

完整使用说明见[中文帮助](docs/help.zh-CN.md)，英文说明见 [English Help](docs/help.en.md)。从源码构建和发布流程见 [English README](README.en.md#build-from-source)。

## 主要能力

- 在菜单栏集中查看额度、余额、重置时间、健康状态和最近刷新结果。
- 汇总 Codex、Minimax、Antigravity、ZCode 与 OpenCode 的本地 token 用量。
- 支持每个 Provider 独立刷新、失败退避、手动刷新和配置热重载。
- 提供 GLM/DeepSeek 高峰时段提示、最近 7 天图表和开机自启动。
- 配置目录权限为 `0700`，配置、日志与凭据文件权限为 `0600`。

## 界面预览

<p align="center">
  <img src="docs/images/menu-overview.png" alt="LLM Monitor 菜单栏主面板" width="420">
</p>

<p align="center"><sub>菜单栏主面板：集中查看 Provider 额度、余额、重置时间、高峰提示和本地用量。</sub></p>

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

macOS 菜单栏小工具，展示各家 LLM 服务的剩余额度。
**展示与配置管理** — 点击菜单栏图标查看下拉，并提供了图形化设置页面直接修改配置。
所有配置（含 API Key）保存在本地 JSON 中，App 支持图形化配置或直接编辑 JSON，编辑保存后自动 reload。
如果你把发布版 `.app` 放到 `/Applications`，可以在设置界面开启开机自启动。

## 当前支持

| Provider | 状态 | 数据源 | 认证方式 |
|---|---|---|---|
| minimax Token Plan | ✅ 稳定 | 远程 API + 本地 v2 `.db`（`~/.minimax/v2/sqlite/runtime-state.sqlite`）；可选合并 OpenCode `minimax-cn-coding-plan` | `config.json` 的 `apiKey` 字段 |
| ChatGPT Plan (Codex) | ✅ 稳定 | `GET https://chatgpt.com/backend-api/wham/usage` + 本地 Codex session 日志；可选合并 OpenCode `openai` | 读 `~/.codex/auth.json` |
| Antigravity | ✅ 稳定 | 本地 `language_server`：`GetUserStatus` + `RetrieveUserQuotaSummary` + `GetCascadeTrajectoryGeneratorMetadata`，自动发现 IDE / agy CLI；可选合并 OpenCode 对应 provider | 复用运行中的 Antigravity 登录态 |
| GLM Coding Plan | ✅ 稳定 | 远程 API `GET https://open.bigmodel.cn/api/monitor/usage/quota/limit`（5h + 周积分窗口 + 套餐档位）+ 本地 ZCode `~/.zcode/cli/db/db.sqlite`（官方客户端 token 用量）；可选合并 OpenCode `zhipuai-coding-plan` | `config.json` 的 `apiKey` 字段（Coding Plan Key，格式 `id.secret`） |
| DeepSeek | ✅ 稳定 | 远程 API `GET https://api.deepseek.com/user/balance`（账户余额，金额口径）；无 native 本地账本，可选合并 OpenCode `deepseek` | `config.json` 的 `apiKey` 字段（`sk-...`） |

### GLM Coding Plan 高峰期

智谱官方规则：**每周一至周五 14:00–18:00**（本机时区）为高峰时段，高峰期按基础积分扣费，非高峰期按 **50% 抵扣**（省一半）。GLM 卡片在额度行下方显示倒计时，颜色分 3 档反映紧迫度：

- 高峰期 🔥：`高峰期 · 还剩 1小时30分`（**红色**）
- 非高峰期，距高峰 < 1 小时 ❄️：`距高峰期 45分 · 非高峰 5 折`（**橙色**，临近）
- 非高峰期，距高峰 ≥ 1 小时 ❄️：`距高峰期 2小时13分 · 非高峰 5 折`（**绿色**，余量充足）

窗口可在设置面板「GLM → 高峰期提示」自定义（开始/结束小时 + 仅工作日），也可在 `config.json` 配置 `peakStartHour` / `peakEndHour` / `peakWeekdaysOnly`（均可选，缺省即官方默认 14–18 / 周一–周五）。倒计时纯本地计算，与 GLM API 无关，刷新失败也能显示。

## DeepSeek 高峰期

DeepSeek 官方定价规则：**北京时间工作日 9:00–12:00 与 14:00–18:00** 为高峰时段，高峰期价格为平时 **2 倍**。判定全程基于北京时间（`Asia/Shanghai`），与用户本机时区无关。余额行右侧显示倒计时（纯本地计算，不依赖 API 响应，刷新失败也能显示），颜色分 3 档：

- 高峰期 🔥：`高峰 2× · 还剩 1小时30分`（**红色**）
- 非高峰期，距高峰 < 1 小时 ❄️：`距高峰 45分`（**橙色**，临近）
- 非高峰期，距高峰 ≥ 1 小时 ❄️：`距高峰 2小时13分`（**绿色**，余量充足）

DeepSeek 周六、周日不执行高峰定价（与 GLM 对齐）：设置页「DeepSeek → 高峰期提示」提供「仅工作日（周一–周五）」开关（默认开启），开启后周六、周日全天按平价（1×）计费，倒计时直接指向下周一 9:00。也可在 `config.json` 配置 `providers.deepseek.deepseekPeakWeekdaysOnly`（可选，缺省即默认 true）。高峰时段本身（9–12 / 14–18）为官方固定政策，不可调。

## DeepSeek 余额说明

DeepSeek 卡片展示的是**账户余额**（货币金额，非 5h / 周积分）：主行显示 `¥100.50`，hover 展开「充值: ¥90.50 | 赠金: ¥10.00」明细，数据来自 `GET https://api.deepseek.com/user/balance`（`is_available` + `balance_infos`）。API Key 在设置页或 `config.json` 的 `providers.deepseek.apiKey` 配置（格式 `sk-...`，可在 platform.deepseek.com 生成）。DeepSeek 官方没有本地 CLI 账本，所以本地 token 柱图只在开启 OpenCode 合并时才有数据。

## GLM 官方客户端（ZCode）本地用量

GLM Coding Plan 的 native 本地 token 账本来自智谱官方 CLI **ZCode**：扫描 `~/.zcode/cli/db/db.sqlite` 的 `model_usage` 表（正常请求 `provider_id='builtin:bigmodel-coding-plan'`，闲时任务 `provider_id='offpeak-idle-plan'`；每行 = 一次模型请求），按本地自然日聚合 5 类 token（input / output / reasoning / cache read / cache write）+ rounds / turns。

- **rounds** = `COUNT(*)`：一次模型请求 = 1 round（含主 agent / subagent / retry / 标题生成）。
- **turns** = `COUNT(DISTINCT turn_id)`：ZCode 原生 `turn_id` 去重，一次 user prompt 触发的多次模型调用共享同一个 turn。
- **input / cacheRead 口径（重要）**：ZCode 的 `input_tokens` 列是**完整输入（含 cacheRead）**，不是纯新输入（证据：`computed_total = input + output` 恒成立）。scanner 取 uncached input = `max(input - cacheRead, 0)`，与 Codex / OpenCode 对齐；`input + cacheRead + output + reasoning` 是对外消耗总量，`cacheWrite` 只作独立账簿，不计入 total。
- **reasoning 口径**：优先使用账单层非零 `reasoning_tokens`；否则若关联 assistant message 存在 `type='reasoning'` part，就把该 round 的 `output_tokens` 整轮归入 reason。它是 round 级分类，不是 token 级精确拆分；`output + reasoning` 总量保持不变。OpenCode 的 GLM 分片继续使用其原生 reasoning 字段。
- **闲时归属**：额度窗口优先按每条 sample 的原始 `provider_id` 精确排除 `offpeak-idle-plan`；旧缓存缺少来源字段时才回退到 `off_peak_tasks` 时间窗口。OpenCode 合并样本始终按正常消耗处理。
- mtime diff 增量扫描（db + WAL 指纹），缓存到 `~/.zcode/cli/.token-monitor/`；进 app 即触发一次，GLM 主 quota 刷新成功后补跑。

OpenCode 的 `zhipuai-coding-plan` 分片作为可选叠加源（`mergeOpencodeUsage` 开关，GLM 缺省开启），与 ZCode native 数据按字段逐项相加；sample 的 promptID 会加 `opencode:zhipuai-coding-plan:` 前缀，避免与 ZCode 的 `session_id:turn_id` 撞库后被去重。

### OpenCode 本地 token 数据源

应用会扫描 `~/.local/share/opencode/opencode.db`，按消息中的 `providerID` 分片。各卡片分别在对应 Provider 设置页通过「合并 OpenCode 数据」开关控制是否合并；关闭时只展示原有本地 Scanner 数据，开启时按字段相加。旧配置缺少该字段时，GLM 默认开启以保持历史行为，其他 Provider 默认关闭。

| 卡片 | OpenCode providerID | 默认值 |
|---|---|---|
| Minimax | `minimax-cn-coding-plan` | 关闭 |
| ChatGPT | `openai` | 关闭 |
| Antigravity | `antigravity` / `google-antigravity` / `google-vertex` / `google` | 关闭 |
| GLM | `zhipuai-coding-plan` | 开启 |
| DeepSeek | `deepseek` | 关闭 |

OpenCode 的 `minimax` provider 是本地能力账本，仅用于诊断，不会自动并入 Minimax Token Plan。OpenCode 的每条带 token 的 assistant message 算 1 个 `round`；同一 session 中相同 `parentID` 的调用归为同一个 `turn`。今日汇总与最近 7 天图表分别展示 Input、Cache read、Reason、Output 和 R/T；`cache write` 只作独立账簿字段，不计入总 token。

## 运行

```bash
git clone <repository-url>
cd LLM-monitor
swift build
./.build/debug/LLM-monitor
```

首次运行会自动生成模板配置文件：
```
~/Library/Application Support/LLM-monitor/config.json
```

然后用编辑器打开它，把 `sk-cp-REPLACE-WITH-YOUR-KEY` 替换成你的 Token Plan Key，
并将对应 provider 的 `enabled` 改为 `true`；也可以直接打开菜单栏里的“设置”完成配置。
保存后菜单栏 app 2 秒内自动 reload（基于 `DispatchSourceFileSystemObject` 目录监听，事件驱动，非轮询）。

## 配置文件

路径：`~/Library/Application Support/LLM-monitor/config.json`（权限 0600）

应用同一时间只运行一个实例，避免多个进程同时写入配置和日志。若已有配置文件无法解析，应用会先将原文件备份为同目录下的 `config.json.corrupt-*.json`，再使用默认配置恢复；请优先从该备份中修复原有设置。

**完整示例**（首次启动会自动写入，用户可手动改）：

```json
{
  "schemaVersion": 1,
  "refreshIntervalSeconds": 300,
  "providers": {
    "minimax_token_plan": {
      "enabled": true,
      "apiKey": "sk-cp-xxxx",
      "mergeOpencodeUsage": false
    },
    "codex_chatgpt": {
      "enabled": true,
      "refreshIntervalSeconds": 60,
      "authPath": "~/.codex/auth.json"
    },
    "antigravity": {
      "enabled": true,
      "refreshIntervalSeconds": 60
    },
    "glm_coding_plan": {
      "enabled": true,
      "apiKey": "your-coding-plan-key-id.secret",
      "mergeOpencodeUsage": true
    },
    "deepseek": {
      "enabled": true,
      "apiKey": "sk-REPLACE-WITH-YOUR-KEY",
      "mergeOpencodeUsage": false
    }
  }
}
```

### 字段说明

| 字段 | 范围 | 说明 |
|---|---|---|
| `refreshIntervalSeconds` | 全局 | 默认刷新间隔（秒），默认 300；被 clamp 到 10 秒～30 天防止 busy loop 和溢出 |
| `statusBarIconStyle` | 全局 | 状态栏图标款式：`"chartBar"` (默认柱状图)、`"sparkles"` (AI 星光)、`"brain"` (智能大脑)、`"cpu"` (芯片) |
| `statusBarIndicatorMode` | 全局 | 状态栏指示方式：`"colored"` (默认健康度着色模式)、`"monochrome"` (macOS 单色模版模式) |
| `providers.<id>.enabled` | 每个 provider | true / false |
| `providers.<id>.apiKey` | minimax 用 | 明文 Token Plan Key（0600 保护）；占位符（`REPLACE`）会被忽略 |
| `providers.<id>.displayName` | 通用 | 可选，覆盖默认显示名 |
| `providers.<id>.refreshIntervalSeconds` | 通用 | 该 provider 独立刷新间隔（同样 clamp 到 10 秒～30 天） |
| `providers.<id>.authPath` | codex 用 | `auth.json` 文件路径，或其所在目录（`~` 自动展开） |
| `providers.<id>.mergeOpencodeUsage` | Minimax / ChatGPT / Antigravity / GLM / DeepSeek | 是否把对应 OpenCode provider 的 token、rounds、turns 逐项合并到卡片；GLM 缺省为 `true`，其他 Provider 缺省为 `false` |

**自动补全**：每次启动检查所有已注册 provider，缺失段自动补上 placeholder（`enabled: false`），不覆盖已有配置。

### 刷新行为

- 同一 provider 不会并发发出重复请求；显式手动刷新若撞上后台刷新，会在后台请求结束后补跑一次完整刷新。不同 provider 仍并行。
- 请求失败会按每个 provider 独立指数退避（最长 30 分钟，带少量随机抖动）；成功后恢复配置的正常间隔。
- ChatGPT Plan 的本地 session 统计会按窗口与文件修改信息缓存；活跃 JSONL 更新时只重解析变化的文件，昨日及更早的 session 事件会复用内存缓存。
- OpenCode scanner 在应用启动时执行，并在 Minimax / GLM 刷新成功后触发；扫描结果共享给各卡，是否消费由各自的 `mergeOpencodeUsage` 开关决定。
- 配置变更通过 `DispatchSourceFileSystemObject` 事件触发 reload，毫秒级响应。

**当前已注册的 provider ID**：
- `minimax_token_plan` — minimax Token Plan（apiKey 鉴权 + 本地 v2 runtime .db 用量扫描）
- `codex_chatgpt` — ChatGPT Plan / Codex（读 `~/.codex/auth.json` + 本地 JSONL session 统计）
- `antigravity` — Antigravity（读取本地运行中的 `language_server`，通过 loopback RPC 获取本地用量）
- `glm_coding_plan` — 智谱 GLM Coding Plan（Coding Plan Key 鉴权，远程 5h / 周积分额度）
- `deepseek` — DeepSeek（API Key 鉴权，远程账户余额 + 北京时间高峰提示）
- OpenCode — 共享的本地 token 账本，不作为菜单栏 provider 展示；设置页提供只读诊断。

## Antigravity 说明

- 不直接使用 `state.vscdb` 里的 Google OAuth access token；该 token 可能已经过期，直连 cloudcode 会返回 `401`.
- 当前实现复用本地已登录的 Antigravity 后端，自动发现其 HTTPS 端口再请求本地 quota 接口：
  - **IDE**：`language_server` 二进制 + 命令行含 `antigravity` 字样 → 需要 `--csrf_token` 鉴权
  - **agy CLI**（`agy` / `antigravity-cli` 二进制）→ 无 CSRF 鉴权，路径锚定避免 `stragy` 之类的字眼误匹配
- 进程发现放在后台执行，菜单与设置页不会因 `pgrep` / `lsof` 探测而阻塞；服务离线时卡片会给出启动提示。
- 套餐名 / 登录邮箱通过 `GetUserStatus` 拿（`userTier.name` 优先，`planStatus.planInfo.*` 兜底；旧版本若没有 `userStatus` 字段则回退到 `GetLoadCodeAssist.currentTier.name`），卡片标题直接显示套餐名，hover 显示登录邮箱。
- **本地 token 用量历史**：仅扫描 Antigravity IDE conversation `.db` / `.pb` 文件的路径、扩展名和 mtime/size 指纹；对变化的 session 调本机 `language_server` 的 `GetCascadeTrajectoryGeneratorMetadata`，获取 per-event token 用量和 stepIndices（5 类：input / output / cacheRead / cacheWrite / reasoning）。聚合结果缓存到 `~/.gemini/antigravity/.token-monitor/`，下次扫描只拉 dirty sessions；不读取 session 文件内容、不访问外部网络，但会调用 loopback RPC。卡片底部展示今日汇总，hover 7 天堆叠柱图。
- **Turn/Round 口径**：rounds 等于 RPC 返回的带时间事件数；turns 和逐次 sample 的 prompt 分组根据 `stepIndices` 的间隙推断，是 best-effort 近似值，不等同于读取 SQLite `step_type=14/15` 得到的精确用户 prompt 边界。
- 使用前需要先启动 Antigravity（或 agy CLI），并确保已经登录成功。
- 如果只想导出原始 quota JSON，可运行：

```bash
./scripts/export-antigravity-quota.sh /tmp/antigravity-quota.json
```

Antigravity 卡片的 OpenCode 合并支持 `antigravity`、`google-antigravity`、`google-vertex` 和 `google` providerID；实际使用哪个 ID 取决于 OpenCode 配置。

## minimax 本地 token 用量说明

- **单源扫描（v2-only）** ——
  - `~/.minimax/v2/sqlite/runtime-state.sqlite`（热路径，活跃 session）的 `local_runtime_token_usage` 表 — 唯一支持、唯一扫描的源
  - 旧版数据库不再读取，也不参与缓存或聚合
- 聚合走 SQL 一次 `COUNT(*)` + `COUNT(DISTINCT turn_id)` 算 R/T，没有跨源 join；无 RPC、无 protobuf。
- mtime diff 增量扫描，结果缓存到 `~/.minimax/.token-monitor/index.json`。
- 冷启动会先恢复各本地 scanner 的上次成功快照；远程 quota 最近成功时间单独保存到配置目录的 `last-refresh.json`，数据带 stale 语义，后台刷新完成后自动更新。
- 卡片底部展示今日 5 类汇总（input / cache / output / reason / rounds / turns），hover 7 天堆叠柱图（视觉对齐 Antigravity / Codex）。
- 同样的 `/tmp` 副本 fallback 策略（`SQLiteTempCopy.read`），隔离 runtime 实时 -shm 状态。

## 加新 Provider

1. 在 `Models/ProviderStatus.swift` 的 `ProviderKind` enum 加 case
2. 在 `Models/ProviderStatus.swift` 的 `AccentColor` enum 加 case（如果有专属品牌色）
3. 在 `Fetchers/` 写 `<Provider>Fetcher.swift` 实现 `QuotaFetcher` protocol
4. 在 `LLMMonitorApp.swift` 的 `makeDescriptors()` 注册（id / displayName / icon / kind / accentColor）
5. 在 `ConfigStore.writeTemplate` 增加首次安装模板，并在 `SettingsView.providerPane` 增加该 provider 的配置面板与草稿读写
6. 为新协议/schema、错误分支和 UI 窗口组合补回归测试

刷新调度、配置监听、卡片容器和通用本地用量图表通常无需修改；provider 特有认证、设置与扫描逻辑仍需显式注册。

## 交互原则

菜单栏 app **简洁高效**。能做的事：
- 点击菜单栏图标 → 下拉展示所有 provider 状态
- 点击右上角 ↻ → 立即刷新全部
- 点击底部的 ⚙️ 设置按钮 → 调起设置面板，支持在 App 内修改 API Key、配置路径以及调整刷新时间
- 右键单张卡片 → 立即刷新该 provider / 打开配置文件
- 修改 config.json 或通过设置保存 → 自动 reload
- Hover 卡片局部信息 → 展开对应的轻量浮层明细
- 设置界面提供 `开机自启动` 开关，可一键注册 / 取消注册系统登录项；菜单底部显示状态（`自启 ✓` / `自启 ✗`）

## 当前交互

- 通用（所有 provider 卡片）
  - 进度条独立占满整行；下面一行放 `5h X%  周 Y%`（左）+ `clock reset-date (suffix)`（右），跨行起始位置对齐
  - **主行 reset time 取 binding constraint**：min(5h, wk × N) 中较小那一边。如果 5h 较小，显示 5h reset；如果 wk × N 较小（5h 还有余量但 wk 撑死了），显示 wk reset——这种场景下 wk reset 才是用户真正等的时间
  - **reset time 后挂紧凑倒计时**：`3d`、`2d5h`、`5h`、`1h23m`、`23m`、`已过期`（阶梯压缩，边界 inclusive）
  - **未配置 / 无数据的状态点显示灰点**（禁用、没抓到过、正在 fetching 第一次）：`StatusIndicator` 根据 `ProviderStatus.healthLevel: HealthLevel?` 显色，`nil` → 灰（secondary.opacity(0.5)），`.healthy` → 绿，`.warning` → 橙，`.critical` → 红。`healthLevel` 派生自 state：`state` 是 `.notConfigured` / `.ready` / `.loading` 且无 `lastSuccess` / `.failed` 且无 `lastSuccess` 时返回 `nil`，否则取 `lastSuccess.healthLevel`（见 `Models/ProviderStatus.swift`）
- `minimax Token Plan`
  - 大部分模型（`general` / `image` / `speech` / `music` / `tts`）：`5h × 10 = 周`
  - **`video` 模型走日窗口**：`日 × 7 = 周`，1 天 ≈ 1/7 周，按 model 名分（不要按 provider 固定）
  - `通用 (M3)` 标题 hover 显示本地账本中的 `Last Prompt`
- `ChatGPT Plan`
  - 标题行（含 Team 套餐标签）hover 显示最近 7 个本地自然日的 Token 柱图；每天分别展示 Input/Cached 与 Output/Reason 两条堆叠柱，并列出精确数值
  - `ChatGPT Plan` 行 hover 显示 `Last Prompt`
  - 同时有 5h 与周窗口时合并为一条（`5h × 6 = 周`）；仅有一个窗口时自动降级为单窗口展示
  - 重置卡单独一行展示数量与最早过期时间，hover 后查看逐张卡片明细
- `Antigravity`
  - 卡片标题 `Google Antigravity`，右侧 pill = 套餐名（`Google AI Pro` → `AI Pro`，跟 `ChatGPT Plan + Team` 完全对称）
  - 卡片标题 hover 展开账号详情：登录邮箱（来自 `GetUserStatus`，可复制） + 套餐名 + 数据来源说明
  - 卡片底部"今天 X in · Y out · Z cache · W reason"（来自 `GetCascadeTrajectoryGeneratorMetadata`，本机 `.token-monitor/index.json` 缓存 + 文件 mtime/WAL 指纹增量）
  - 卡片底部 hover 展开 7 天堆叠柱图（4 段：input / cache / output / reason），对齐 ChatGPT Plan 7 天图的视觉
  - 展示 `Gemini Models` 与 `Claude and GPT models` 两组额度
  - `Gemini Models` 与 `Claude and GPT models` 标题 hover 分别显示对应模型族的 `Last Prompt`
  - 每组合并展示 5h / 周额度：Gemini 按 `5h × 6 = 周` 分段，Claude and GPT 按 `5h × 3 = 周` 分段
- 三个 provider 的额度行采用同一套 hover 语义
  - 模型标题：`ChatGPT Plan` / `通用 (M3)` / `Gemini Models` / `Claude and GPT models` 显示各自的 `Last Prompt`
  - 额度条：显示对应额度时间窗口内的 prompts / rounds / token 累计
  - 剩余百分比 + 重置时间行：显示每个窗口的完整重置时间与相对倒计时
- `minimax` 本地用量 footer（行为对齐 Antigravity）
  - 卡片底部"今天 X in · Y out · Z cache · W reason"，hover 7 天堆叠柱图
  - 缓存读 + 写合一展示（避免 minimax 的 `cacheRead` 主导时柱图过细）
- 开机自启动
  - 设置面板提供 `开机自启动` 开关，菜单底部显示只读状态
  - 使用 macOS `SMAppService.mainApp` 注册当前 app 为登录项
  - 如果 app 不在 `/Applications`，会提示先移动到 `/Applications`
  - 如果系统需要手动批准，会提示到系统设置里完成批准
- Hover 浮层
  - 延迟 150ms 显示
  - 以鼠标为锚点定位，自动避开屏幕右边界和下边界
  - 使用独立浮层窗口，并以 parent-child 关系挂到菜单窗口上
  - 主行 reset time 旁边永远展示两个窗口的完整 reset + 倒计时，外加一行小字说明"主行取 X（X 是 binding constraint）"
- 菜单窗口
  - 失焦后自动关闭
  - 鼠标移出超过 30 秒自动关闭
- 字体统一：11pt 用于 row 标题（model name / 重置卡数量），10pt 用于所有其他文字（周倍率 caption、percent、reset time、suffix）

## 架构（关键抽象）

- **`FetcherDescriptor`** (`Models/FetcherDescriptor.swift`) — provider 的运行时元信息注册表：`LLMMonitorApp.makeDescriptors()` 集中注册，AppState / SettingsView 都从 descriptor 取得 id、标题、图标与接收完整 `ProviderConfig` 的 fetcher 工厂。provider 特有设置 schema 仍由 `ProviderKind`、`ConfigStore` 模板和设置 pane 显式处理。
  - **两个已知的边界**（不是 bug，是无法消除的镜像）：
    1. `ConfigStore.writeTemplate` 是 `static` 函数（init 期间、`descriptors` 不可用时调用），所以 config.json 模板里的 `providers.<id>` 段是 hardcoded string。运行时 `ConfigStore.ensureProvidersPresent(descriptors:)` 走的才是 descriptor 路径。
    2. `QuotaFetcher.providerID` 是 fetcher 自带的 `let`（用于 log tag / 自识别），是构造时由 descriptor 注入的镜像值。删了会让 fetcher 失去自描述能力，保留是必要的。
- **`ProviderKind`** — 枚举当前支持的 provider 类型（minimaxTokenPlan / codexChatGpt / antigravity / glmCodingPlan），所有 "按 kind 派发" 的代码（UI、scanner、auth probe）都从 `descriptors.first(where: { $0.kind == ... })` 拿 id，避免散落的 `if providerID == "antigravity"` 判断。
- **`QuotaFetcher` protocol** (`Fetchers/QuotaFetcher.swift`) — 所有 provider 必须实现；默认 `logTag = [providerID]`，fetcher 可重写（CodexFetcher 用 `[codex]` 短 tag）。
- **`LocalUsageDaily` protocol** (`Models/LocalUsageDaily.swift`) — 7-day chart 用的 daily 数据协议，5 个 daily struct（Antigravity / Codex / Minimax / OpenCode / GLM）通过 computed property adapter 接入，view 层用泛型（`SevenDayTokenUsageHoverView<Daily>`、`LocalUsageFooterView<Daily>`）一次写完，各卡片视觉自动对齐。
- **`OpencodeUsageMerger`** (`Models/OpencodeUsageMerger.swift`) — 将 OpenCode 的 provider slice 转换为各卡原有 daily / window summary，并执行字段级相加；跨来源 sample 的 prompt ID 会加命名空间，避免 turns 被错误去重。
- **`OpencodeDBReader` / `OpencodeUsageScanner`** (`Services/`) — 读取 `opencode.db`，按 providerID 聚合今日、最近 7 天、rounds、turns 和逐次 assistant samples。
- **`LocalUsageCoordinator`** (`Services/LocalUsageCoordinator.swift`) — 把 `LocalUsageScanner` 协议 + Combine wire-up 逻辑收成一处的容器；AppState 的 trigger 方法退化成 1 行 `coordinator.trigger()`。
- **`SQLiteConnection` / `SQLiteTempCopy`** (`Services/`) — SQLite 底层 init / open / query 跟"快路径 + /tmp 副本 fallback"读策略。**目前 3 个本地用量 scanner 共用**（`MinimaxLocalUsageScanner` / `GlmZcodeLocalUsageScanner` / `OpencodeUsageScanner`）；Antigravity 已改为纯 RPC，codex 的本地 session 统计走 JSONL 解析也不走 SQLite。`SQLiteTempCopy.withTempCopy` 内部 defer 清理保证".db 复制成功但 -wal/-shm 失败"这种半完成场景不留残留。
- **`DateParser`** (`Services/DateParser.swift`) — 统一 ISO8601 / unix 秒 / unix 毫秒 / 字符串数字 4 种 schema 的 date 解析。
- **`StringUtilities`** (`Services/StringUtilities.swift`) — `trimmedOrNil` / `firstTrimmed` 等纯函数。
- **`LocalUsageDayKey`** (`Services/LocalUsageDayKey.swift`) — `yyyy-MM-dd` day key 跟 SQLite `strftime` 对齐的格式化器，3 个本地用量 scanner + `MinimaxDBReader` 共用。
- **`LocalUsageScanRunner`** (`Services/LocalUsageScanRunner.swift`) — antigravity / minimax / OpenCode 三个 scanner 共享的 lifecycle helper（启动 / 完成 generation 守门 + cancellation filter + applyResult/applyError 闭包注入）。消除镜像 boilerplate，但保留各 scanner 自己的 `AsyncMutex` / `lastCommittedGeneration` / `performScanPure` 边界（测试 surface 不动）。
- **`HTTPTimeouts`** (`Services/HTTPTimeouts.swift`) — minimax / codex / antigravity 三个 fetcher 的 HTTP timeout 集中地。改一处全局生效。
- **`FileManagerBox`** (`Services/FileManagerBox.swift`) — `FileManager` 的 `@unchecked Sendable` 包装，底层字段保持 `private`，所有 I/O 必须走 wrapper API。各 non-actor-isolated pipeline 可安全捕获该包装；线程安全由各自的 `AsyncMutex` 串行化保证。私有原子写从创建临时文件起即使用 `0600`。
- **`AntigravityLocalUsageScanner`** (`Services/AntigravityLocalUsageScanner.swift`) — 纯 RPC 架构本地用量扫描器，统一处理 `.db` 与 `.pb` 会话文件中的 Token 与 Turn/Round 计算。
- **`SettingsView` 派生 tabs** — `SettingsTab` 是 `.general + .provider(FetcherDescriptor)`，侧栏 tabs 直接从 `descriptors` 派生，icon / 标题 / 副标题走 descriptor。新增 provider 不用改 `SettingsView` 枚举本身。

## 发布 DMG

需要 notarization 时，先用 `xcrun notarytool store-credentials` 保存凭据，再显式启用：

```bash
CODESIGN_IDENTITY="Developer ID Application: ..." \
NOTARIZE=1 NOTARY_PROFILE="llm-monitor" ./scripts/build-dmg.sh
```

脚本会签名 DMG，等待 Apple 审核结果、staple ticket 并执行 `stapler validate`；普通本地构建默认不签名 DMG，也不访问 notarization 服务。

## 目录

```
LLM-monitor/
├── Package.swift
├── README.md
├── VERSION               # 项目版本号文件 (如 1.0.1)
├── .build_number         # 自动递增的 build 编号 (如 12)
├── scripts/
│   ├── audit.sh          # shell / package / tests / Release / Swift 6 完整门禁
│   ├── build-app.sh      # 编译 release 版 .app 并自动递增 build 编号
│   ├── build-dmg.sh      # 打包 dmg 分发文件
│   ├── generate-icns.sh  # 从源图生成 AppIcon.icns
│   ├── test.sh           # 运行 swift test；仅 INCREMENT_BUILD_NUMBER=1 时递增编号
│   └── export-antigravity-quota.sh
├── spec/
│   ├── overview.md
│   ├── ui-design.md
│   └── providers/
│       ├── antigravity.md
│       ├── codex.md
│       ├── deepseek.md
│       ├── glm.md
│       ├── minimax.md
│       └── opencode.md
└── Sources/LLM-monitor/
    ├── LLMMonitorApp.swift
    ├── Models/
    │   ├── FetcherDescriptor.swift   # provider 注册元信息（id / kind / icon / accent）
    │   ├── ProviderStatus.swift      # UI 状态机 + ProviderKind / AccentColor 枚举
    │   ├── QuotaInfo.swift           # provider-neutral 额度模型
    │   ├── AnyJSON.swift             # 弱类型 JSON（Antigravity 递归解析用）
    │   ├── AntigravityLocalUsage.swift
    │   ├── MinimaxLocalUsage.swift
    │   ├── LocalTokenUsageSample.swift # provider-neutral 逐次调用与额度窗口聚合
    │   ├── LocalUsageDaily.swift     # 4 类 daily 数据共享的 7-day chart 协议
    │   ├── OpencodeLocalUsage.swift  # OpenCode provider 分片模型
    │   ├── OpencodeUsageMerger.swift # OpenCode 与各卡的字段级合并
    │   ├── GlmPeakWindow.swift       # GLM 可配置高峰窗口
    │   └── DeepseekPeakWindow.swift  # DeepSeek 高峰窗口（北京时间 + 周末平价开关）
    ├── Fetchers/
    │   ├── QuotaFetcher.swift        # protocol + 默认实现
    │   ├── QuotaError.swift          # 统一错误类型
    │   ├── MinimaxTokenPlanFetcher.swift
    │   ├── CodexFetcher.swift
    │   ├── AntigravityFetcher.swift
    │   ├── GlmCodingPlanFetcher.swift  # 智谱 GLM Coding Plan（远程 quota/limit）
    │   └── DeepseekFetcher.swift       # DeepSeek 账户余额（远程 balance）
    ├── Services/
    │   ├── AppLog.swift              # 三路日志（stdout / 文件 / os.Logger）
    │   ├── AppState.swift            # 全局状态、per-provider 调度、scanner wire-up
    │   ├── ConfigStore.swift         # config.json 读写 + 内容指纹跟踪
    │   ├── LoginItemService.swift    # SMAppService 包装
    │   ├── Formatters.swift          # token / percent / 时间格式化
    │   ├── HTTPClient.swift          # 共享 HTTP 客户端（Antigravity 除外）
    │   ├── HTTPTimeouts.swift        # HTTP timeout 集中地（minimax/codex/antigravity）
    │   ├── ProcessRunner.swift       # 可取消、有超时、并发排空 stdout/stderr 的进程执行器
    │   ├── FileManagerBox.swift      # FileManager @unchecked Sendable + private fileManager
    │   ├── LocalUsageCoordinator.swift  # scanner 协议 + wire-up
    │   ├── LocalUsageScanRunner.swift   # 两个 scanner 共享的 lifecycle helper
    │   ├── DateParser.swift          # ISO8601 / unix timestamp 解析
    │   ├── StringUtilities.swift     # 字符串小工具
    │   ├── LocalUsageDayKey.swift    # yyyy-MM-dd day key
    │   ├── SQLiteConnection.swift    # SQLite3 通用连接层
    │   ├── SQLiteTempCopy.swift      # CANTOPEN/BUSY 时 /tmp 副本 fallback
    │   ├── Color+Theme.swift         # 品牌色常量
    │   ├── MenuBarRightClickHandler.swift  # 状态栏按钮右键菜单
    │   ├── MinimaxDBReader.swift     # 读 minimax v2 local_runtime_token_usage 表
    │   ├── MinimaxLocalUsageScanner.swift  # minimax v2-only scanner
    │   ├── OpencodeDBReader.swift      # 读 opencode.db 的 message 表
    │   ├── OpencodeUsageScanner.swift  # OpenCode provider 分片 + 7 天聚合
    │   └── AntigravityLocalUsageScanner.swift  # antigravity 纯 RPC 架构 scanner
    └── Views/
        ├── MenuContentView.swift     # 主面板
        ├── MenuWindowAutoCloseBridge.swift  # 失焦自动关
        ├── ProviderCardView.swift    # provider 卡片 + StatusIndicator
        ├── QuotaViews.swift          # 各种 quota 行 + 进度条 + 等价额度算法
        ├── QuotaHoverViews.swift     # Last Prompt / 窗口 token / 重置时间 hover
        ├── HoverPanel.swift          # 浮层控制器（HoverInfoRow / HoverPanelController）
        ├── TokenChart.swift          # 7-day 柱图基础组件
        ├── AntigravityAccountView.swift  # Antigravity / ChatGPT 账号 hover 详情
        ├── DeepseekAccountView.swift    # DeepSeek 余额 hover 详情
        ├── GlmPeakIndicatorView.swift   # GLM 高峰提示行
        ├── DeepseekPeakIndicatorView.swift # DeepSeek 高峰提示行（北京时间）
        ├── PeakIndicatorView.swift      # 高峰提示行公共组件（GLM / DeepSeek 共用）
        ├── BrandLogoView.swift          # provider 品牌 logo + SF Symbol fallback
        ├── LocalUsageHoverViews.swift  # 7-day 泛型 chart + 泛型 footer
        ├── SettingsView.swift        # 设置状态与 provider 配置面板
        └── SettingsComponents.swift  # 设置窗口聚焦桥与复用组件
```

## 安全

- API Key 在 config.json 明文，但配置目录为 `0700`、文件为 `0600`
- API Key 只作为认证 header 发给对应 provider 的 HTTPS endpoint，不写入应用日志；HTTP 错误响应体也只记录状态与字节数
- 配置、日志与用量缓存都写在用户目录，不写入仓库
- ChatGPT Plan 的 prompts/token 明细来自本地 `~/.codex/sessions` 与 `~/.codex/archived_sessions` 聚合，不会写回本项目配置
- minimax / Antigravity 本地 token 用量缓存到 `~/.minimax/.token-monitor/` / `~/.gemini/antigravity/.token-monitor/`，不进项目目录
- OpenCode 本地 token 数据来自 `~/.local/share/opencode/opencode.db`，扫描缓存位于同目录下的 `.token-monitor/`，不进项目目录
