# LLM Monitor User Guide

[Back to English README](../README.en.md) · [中文帮助](help.zh-CN.md)

## Requirements

- macOS 14 Sonoma or later.
- Apple Silicon Macs (arm64) are supported.
- Enough menu bar space for the app icon.
- Network access is required for remote quota checks. Local token scanners do not upload client databases.

## Install and first launch

1. Download the DMG and `SHA256SUMS.txt` from [GitHub Releases](https://github.com/bigboyq/LLM-monitor/releases/latest).
2. Open the DMG and drag `LLM-monitor.app` to `/Applications`.
3. This snapshot is not Apple-notarized. If the first launch is blocked, Control-click the app in Finder, choose **Open**, and confirm.
4. Click the menu bar icon and open Settings. The first launch creates a local configuration file but does not enable any provider.
5. Enable the providers you use, enter the requested credential or local auth path, save, and refresh.

Verify the download in Terminal:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

The app never checks for or installs updates by itself. Watch or subscribe to the [GitHub Releases page](https://github.com/bigboyq/LLM-monitor/releases) to learn about new versions, then download and install them as described above.

## Provider setup

### Minimax Token Plan

Enable Minimax and enter a Token Plan API key. Local usage comes from `~/.minimax/v2/sqlite/runtime-state.sqlite`; supported MiniMax usage from ZCode, DSH, and OpenCode is automatically attributed to this card without a configuration switch.

### ChatGPT Plan / Codex

Sign in with the Codex CLI and make sure `~/.codex/auth.json` exists. The default auth path normally needs no change. Remote quota comes from the ChatGPT usage API; local usage is aggregated from `~/.codex/sessions` and `~/.codex/archived_sessions`.

### Antigravity

Sign in once with Antigravity or the `agy` CLI: LLM Monitor reads the login credential from the macOS keychain (item `gemini` / `antigravity`) and queries the Google quota APIs directly, so Antigravity does not need to keep running. The first credential read triggers one Keychain authorization prompt — choose "Always Allow" and it will not ask again. The token is renewed by the Antigravity client itself (default refresh interval 5 minutes); when the card says the token has expired, open Antigravity to refresh the credential. Local 7-day token usage is read directly from the local session SQLite databases (`~/.gemini/antigravity/conversations/`), which likewise does not require Antigravity to be running.

### GLM Coding Plan

You must enter a Coding Plan API key (commonly `id.secret`) to fetch standard quota; OAuth is not used as a fallback. The optional “Enable ZCode JWT extension” switch is off by default. When enabled, the app reads the ZCode credential path (default `~/.zcode/v2`) and, when a JWT is available, fetches activity-plan balances and reset cards. Campaign lookups also require campaign notifications to be enabled. With the extension off, ZCode credentials are not read and cached ZCode package data is hidden. Local ZCode usage comes from `~/.zcode/cli/db/db.sqlite`. The default peak window is Monday to Friday, 14:00–18:00 Beijing time (Asia/Shanghai), excluding statutory public holidays, with credit consumption at 2× the off-peak rate. Both GLM and DeepSeek support `peakWindow` overrides for `slots`, `weekdaysOnly`, and `multiplier` in Provider JSON; Settings shows the current schedule and multiplier without editing controls. GLM nominal value estimates remain independent of credit multipliers. See the [configuration spec](../spec/config.md#config-schema) for an example.

ZCode tasks fall into four provider categories — Coding Plan / Start Plan (trial plan) / Off-peak / Other Zhipu plans: only Coding Plan tasks count toward the 5h / weekly quota windows, while all four appear in the local token bars. Settings → Clients → ZCode lists them as separate rows in that order (categories with no usage are omitted), each with its own bars and cost estimate, followed by DeepSeek / MiniMax slices from the same ledger automatically attributed by provider. Supported local-ledger sources are attributed automatically; unknown providers are not guessed. When the JWT extension is enabled and a ZCode JWT is available, the app reads activity-plan balances, reset cards, and claimable campaigns through ZCode's APIs. Plan balances follow GLM's regular refresh interval; reset cards and campaigns follow the secondary-information frequency, with campaign notifications also required for campaign polling.

### DeepSeek

Enter a DeepSeek `sk-...` API key. The card displays account balance. DeepSeek has no native local ledger: local token charts automatically include supported DeepSeek usage from ZCode, DSH, and OpenCode. DeepSeek Flash local cost estimates use ¥1 per million input tokens, ¥0.02 per million cached-read tokens, and ¥4 per million output tokens. Default Beijing-time weekday busy hours (Mon–Fri 9:00–12:00 and 14:00–18:00) are charged at 2×, excluding statutory public holidays; weekends are off-peak all day. Local and Fleet cost estimates, countdowns, and Settings use the current `peakWindow` override when configured.

### OpenCode merge

The app reads `~/.local/share/opencode/opencode.db` and separates rows by `providerID`. OpenCode is not a standalone card. Supported provider IDs are automatically attributed to their matching cards; no setting or `config.json` switch is needed. This is separate from each provider's own enable/disable setting. Unrecognized provider IDs are not guessed into a card.

### ZCode slices

ZCode is a shared multi-provider ledger just like OpenCode: Zhipu-family rows feed the GLM card, while rows whose `provider_id` starts with `minimax` / `deepseek` are partitioned into slices and automatically attributed to the MiniMax / DeepSeek cards respectively. Supported provider IDs are handled automatically, with no user-facing attribution switches; unrecognized IDs are not guessed into a card.

## Multi-device Sync (Hub and Nodes)

Enable sync under Settings → Multi-device on each Mac. The topology has one hub and one or more nodes: the hub aggregates incoming data, while nodes report periodically. Nodes do not relay data to downstream nodes.

- **Set up the hub**: Enable sync, leave Hub address empty, choose a listening port, and keep LLM Monitor running. The settings pane shows a copyable LAN address and connected nodes.
- **Set up a node**: Enable sync, enter the full hub address, such as `http://192.168.1.20:8787`, and give this Mac a recognizable name. The hub name must resolve and be reachable from each node. For plain HTTP, use a LAN IP address or a `.local` hostname; macOS ATS may block ordinary fully qualified domain names. The reporting interval can be customized; 0 follows the regular refresh interval.
- **View data**: The main menu and provider cards can show global, local, or individual-node data. When a node is offline, its data is marked stale and shows the last successful sync.
- **Network and security**: Each Mac must be able to reach the hub's listening port over the LAN. The current protocol uses HTTP without TLS or application-level authentication, so use it only on a trusted local network.

An empty Hub address makes this Mac the hub; entering an address makes it a node. Changing roles recreates the matching listener or reporting connection.

## Holiday data source

Both GLM and DeepSeek decide peak hours in Beijing time (Asia/Shanghai), by default counting a weekday as Monday to Friday **minus** statutory public holidays. This table is why Spring Festival and National Day no longer count as peak time, and why a make-up holiday that falls on a weekday is excluded too. With `peakWindow.weekdaysOnly` set to `false`, the configured schedule applies every day, including weekends and holidays.

- **Fetches over the network by default.** On launch the app pulls the JSON published by the chinese-days project (`https://cdn.jsdelivr.net/npm/chinese-days/dist/chinese-days.json`) and caches it at `~/Library/Application Support/LLM-monitor/holidays-cache.json` (mode 0600). A fresh cache is reused for 7 days before another request.
- **Bundled snapshot only.** Clear the "节假日数据源" field under Settings → General to an empty string. The app then uses only the `ChinaHolidays.json` snapshot shipped with the bundle — no network, no cache read.
- **Refresh on demand.** "立即更新" (Refresh now) fetches the current draft source and immediately applies and caches a successful result; an empty draft applies the bundled snapshot. Save the settings to persist the source. Once a different source is saved, an old request cannot overwrite it. The status line shows the current source (cache or bundle) and fetch date. A failed fetch keeps the existing data.
- **Years not covered.** Holiday data is published year by year. When neither the cache nor the bundled snapshot covers a year, that year falls back to a plain Mon–Fri rule, so a public holiday on a weekday is temporarily treated as a peak candidate. Update the data source for exact coverage.

## Everyday controls

- Settings → Usage groups each harness by provider and shared quota pool. A pool's 5-hour and weekly windows form one group. Antigravity, Agy, and OpenCode usage attributed to Antigravity use Gemini Models, Gemini 4 Argon, and Claude and GPT models groups; ZCode retains Coding Plan, Start Plan, and other provider groups. Samples with no recognized pool and daily totals not covered by retained samples remain separately unattributed, preserving total tokens.
- Independent account, tier, and organization lookups also use the secondary-information frequency: this includes the Antigravity remote tier lookup (`loadCodeAssist`) and the ChatGPT API credits organization lookup when the costs response has no organization name. Background refreshes retain existing names while updating quota and amounts. GLM's tier is included in its quota response; Codex email and plan come from its local authentication file, so neither needs an extra lookup.
- Settings → General → “默认刷新频率” sets the default quota and balance interval for providers without an override. “次要信息频率” selects a multiplier from 1 to 30 (default 20) for ChatGPT reset cards, GLM reset cards, and claimable campaigns. Each provider's settings show its estimated period, calculated from its effective interval × multiplier: 3 minutes × 2 means about 6 minutes; 1× updates secondary information on every refresh. GLM activity-plan balances and ChatGPT API credits continue to follow the regular interval. Local token scans and peak-period countdowns are independent of this multiplier.
- Click the menu bar icon to open or close the panel.
- Use the refresh button to refresh all enabled providers now.
- The provider-header eye pins that provider’s aggregated main plan (or Control-click/right-click for individual sources); clicking the selected provider eye again restores the global nonzero-minimum effective quota. Eyes beside individual model/group quota bars as well as API-key and activity-entitlement headings pin that exact quota source—main-plan headings show text only with no duplicate heading eye on any provider (multi-model plans pin individual models directly even if excluded from main-plan aggregation, and single-bar plans bind the bar directly to `.plan`)—and clicking an already-selected solid source eye again unpins back to global aggregation. Settings → General offers the same provider/source selection. Missing data stays unknown without switching sources.
- Control-click a provider card to refresh it or open the config file.
- Hover over titles, quota rows, and local-usage footers for account details, window details, recent prompts, and seven-day charts.
- Use Settings → General for refresh intervals, icon style, health-dot visibility, and launch at login. Standard SF Symbol styles use a lower-right health dot (green, orange, or red). Two self-contained dashboard styles are available: the App Icon (`quotaLogo`) is the classic dual-ring water gauge — an outer weekly ring and an inner 5-hour ring filling counter-clockwise (solid up to the minimum remaining, ticked dashes to the average) with a center water cup mapping the 5-hour minimum and alarm color (missing windows render as full rings, matching the legacy behavior); Icon Duo (`iconDuo`) follows the actual quota shape: dual-window plans show 5-hour and weekly arcs, a centered effective 5-hour number constrained by weekly quota, and bottom model-health dots; single-window sources show one ring and a centered number without bottom dots. The sleep lamp sits in the top notch with a clear gap of 0.75 lamp diameters on each side. Numbers are centered by their visible glyph outlines and omit the percent sign: 0–99 display normally, 100% appears as `00`, and unknown as `—`. Card percentages keep their existing format.
- Settings → General → “主菜单 Provider 顺序” (main-menu provider order): reorder main-menu provider cards with the up/down buttons on each row; the default order is by provider name. This affects only the main menu — the Clients tab and provider lists in Settings stay alphabetical.
- Footer "节能" (Energy) button: 1-click in-memory toggle to prevent system sleep (the corner status dot reflects tri-color sleep health); open Settings → Energy for complete diagnostics.
- Disabled providers are hidden and do not make network requests.
- Cost estimates cover only models with a published price. If a usage window also contains unknown models, the menu and seven-day table show “partially priced.”

## Sleep Health and Energy Management

The app provides an "节能" (Energy) quick-action button in the menu footer (with a tri-color status indicator dot) and a dedicated "Energy" tab under Settings:
- **Quick Keep-Awake Toggle**: Click the "节能" button in the menu footer to toggle "Prevent Sleep" mode on the spot. The red indicator dot confirms that the keep-awake assertion is active. This is an in-memory assertion that automatically resets when the app quits or restarts.
- **Tri-Color Sleep Health**:
  - 🟢 **Healthy**: Normal sleep operation; no third-party blockers and automatic sleep is enabled;
  - 🟡 **Warning**: Sleep blocked (external processes holding sleep assertions, or `ac_sleep=0` on AC power);
  - 🔴 **Active**: Manual keep-awake mode is active.
- **When the status refreshes**: Sleep health is re-evaluated instantly when the main panel opens, when the "Settings → Energy" tab appears, on system wake, and at scheduler health boundaries (e.g. peak-window switches); the footer dot and the header sleep-blocker notice always reflect the latest state with no manual refresh needed.
- **Diagnostics & Power Settings**: Navigate to "Settings → Energy" to see the full list of external blocking processes (with PID and elapsed duration) and read-only system power parameters (`sleep`, `womp`, `tcpkeepalive`, `powernap`, `displaysleep`) with GUI and CLI remediation guides.

## Notifications & Bark push

Windowed providers (ChatGPT/Codex, GLM, Minimax, Antigravity) support four quota events, each with an independent channel (off / system only / system + Bark):

| Event | Fires when |
|---|---|
| 5-hour quota restored | remaining share rises by more than 5 pp, or climbs back above 98% |
| 5-hour quota exhausted | remaining share drops to about 0% (edge-triggered once, no repeats) |
| weekly quota restored / exhausted | same rules applied to the weekly window |

- Each windowed provider's settings pane has a "通知配置" (notification) section; default channels match the historical behavior (restored → system notification, exhausted → off; the restored thresholds themselves are new, see the table above).
- System notifications are delivered by macOS and also appear as banners in the foreground; permission is requested at launch only when the status is "not determined". If you previously denied it, re-enable under "System Settings → Notifications → LLM Monitor".
- Bark push is configured under Settings → General → "Bark 推送": server URL (official `api.day.app` by default; self-hosted https URLs keep their base path), device key (copied from the Bark app), optional sound, group, and message TTL (seconds; a positive value makes the phone auto-delete the message once expired, while empty/0 never expires). Use "发送测试推送" to verify after saving.
- Bark pushes carry a stable per provider+model overwrite ID: a new push for the same model replaces the old one on your phone instead of piling up.
- With "人在电脑前时跳过推送" enabled, Bark is skipped while the display is awake and the session is unlocked (you can see system notifications anyway); display sleep or a locked screen both deliver.
- Detection baselines are persisted: exhaustion/recovery events that happen while the app is not running are reported once on the first refresh after relaunch.

## Privacy and local files

| Data | Path |
|---|---|
| Configuration | `~/Library/Application Support/LLM-monitor/config.json` |
| Logs | `~/Library/Application Support/LLM-monitor/log.txt` |
| Last successful remote state | `~/Library/Application Support/LLM-monitor/last-refresh.json` |
| Notification trigger baselines | `~/Library/Application Support/LLM-monitor/notification-state.json` |
| Local scanner cache root | `~/Library/Application Support/LLM-monitor/token-monitor/{provider}.json` |

Configuration changes are reloaded automatically. If the file is invalid, the app first creates a `config.json.corrupt-*.json` backup and then restores defaults. Never post real API keys in a repository, issue, or log attachment.

API keys are sent only to their matching provider HTTPS endpoints and are not written to the app log. Local scanners aggregate usage on the Mac and do not upload the source databases. The app uses mode `0700` for its config directory and `0600` for config and log files.

## Troubleshooting

### No menu bar icon

The app is menu-bar-only and has no Dock icon. Confirm that `LLM-monitor` is running in Activity Monitor and free some menu bar space if needed. A single-instance lock prevents duplicate launches.

### “Not configured” or a gray status dot

Make sure the provider is enabled, the credential is not a template placeholder, and Settings were saved. A gray dot means the app has not received successful data yet; it does not always mean a failure.

### Remote refresh fails

Check connectivity, credentials, subscription type, and local login state. The app retries automatically at the regular refresh interval, and you can Control-click the card to retry immediately. Inspect `log.txt` for details and redact it before sharing.

### Local token usage is empty

The corresponding client must have generated session data. Confirm that the database/session path exists and that the app can read it. DeepSeek local usage requires matching provider calls in ZCode or OpenCode.

### Launch at login cannot be enabled

Move the app to `/Applications`. If macOS requires approval, open **System Settings → General → Login Items**.

### Bark pushes never arrive

Check, in order: Bark is enabled with a complete server URL and device key; "发送测试推送" succeeds (https and local http debug addresses only); the event's channel is set to "Bark + 系统通知"; and if "人在电脑前时跳过推送" is on, pushes are intentionally skipped while the display is awake and the session is unlocked. Overwrite IDs require Bark server v2.2.5+ and Bark app v1.5.2+. Delivery failures are logged in `log.txt` with status codes (no credentials).

### macOS blocks the app

This Release is an ad-hoc-signed snapshot. Verify its SHA-256, then Control-click the app in Finder and choose **Open**. Do not bypass Gatekeeper for copies from untrusted sources.

## Uninstall

1. Disable launch at login in Settings and quit the app.
2. Remove `/Applications/LLM-monitor.app`.
3. To remove settings and logs, delete `~/Library/Application Support/LLM-monitor/`.
4. Original client databases are never removed. The `token-monitor` cache files may be deleted separately and will be rebuilt when needed.
