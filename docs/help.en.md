# LLM Monitor User Guide

[Back to English README](../README.en.md) · [中文帮助](help.zh-CN.md)

## Requirements

- macOS 14 Sonoma or later.
- Apple Silicon Macs (arm64) are supported.
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

## Provider setup

### Minimax Token Plan

Enable Minimax and enter a Token Plan API key. Local usage comes from `~/.minimax/v2/sqlite/runtime-state.sqlite`. To include `minimax-cn-coding-plan` usage from OpenCode, set the matching `clientBindings` entry to `true` in `config.json` (see "OpenCode merge" below).

### ChatGPT Plan / Codex

Sign in with the Codex CLI and make sure `~/.codex/auth.json` exists. The default auth path normally needs no change. Remote quota comes from the ChatGPT usage API; local usage is aggregated from `~/.codex/sessions` and `~/.codex/archived_sessions`.

### Antigravity

Start and sign in to Antigravity IDE or the `agy` CLI. LLM Monitor discovers the local `language_server` and uses loopback RPC for account, quota, and trajectory token data. If the service is shown as offline, keep Antigravity running and confirm its login state.

### GLM Coding Plan

Enter a Coding Plan key, commonly in `id.secret` format. Remote quota comes from GLM; local ZCode usage comes from `~/.zcode/cli/db/db.sqlite`. The default peak window is Monday through Friday, 14:00–18:00 in the Mac's local time, and can be changed in Settings.

ZCode tasks fall into three provider categories — Normal (Coding Plan) / Off-peak / Other Zhipu plans: only Normal tasks count toward the 5h / weekly quota windows, while all three appear in the local token bars; Settings → Clients → ZCode shows per-category bars and cost estimates. Enabling "Parse activity plan balance log" in Settings also shows zcode activity plans (e.g. the weekend trial plan) with remaining percentage and expiry on the card, parsed from ZCode's local balance polling log (`~/.zcode/v2/logs`); local files only, off by default.

### DeepSeek

Enter a DeepSeek `sk-...` API key. The card displays account balance. DeepSeek has no native local ledger, so local token charts require the OpenCode merge (`clientBindings` in `config.json`). DeepSeek Flash local cost estimates use ¥1 per million input tokens, ¥0.02 per million cached-read tokens, and ¥4 per million output tokens. Beijing-time weekday busy hours (Mon–Fri 9:00–12:00 and 14:00–18:00) are charged at 2×; weekends are off-peak all day.

### OpenCode merge

The app reads `~/.local/share/opencode/opencode.db` and separates rows by `providerID`. OpenCode is not a standalone card. Merging is controlled by the `opencode` bindings in `clientBindings[]` inside `~/Library/Application Support/LLM-monitor/config.json` (GLM defaults to enabled, other providers to disabled); the settings window has no per-provider toggle for it. Save the edited file and the app hot-reloads it without a restart.

## Everyday controls

- Click the menu bar icon to open or close the panel.
- Use the refresh button to refresh all enabled providers now.
- Control-click a provider card to refresh it or open the config file.
- Hover over titles, quota rows, and local-usage footers for account details, window details, recent prompts, and seven-day charts.
- Use Settings → General for refresh intervals, icon style, health-dot visibility, and launch at login. When enabled, a 6 pt status dot appears at the lower-right: green for healthy, orange for warning, and red for critical.
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
| Minimax scanner cache | `~/.minimax/.token-monitor/` |
| Antigravity scanner cache | `~/.gemini/antigravity/.token-monitor/` |
| ZCode scanner cache | `~/.zcode/cli/.token-monitor/` |
| OpenCode scanner cache | `~/.local/share/opencode/.token-monitor/` |
| DSH scanner cache | `~/.dsh/.token-monitor/` |

Configuration changes are reloaded automatically. If the file is invalid, the app first creates a `config.json.corrupt-*.json` backup and then restores defaults. Never post real API keys in a repository, issue, or log attachment.

API keys are sent only to their matching provider HTTPS endpoints and are not written to the app log. Local scanners aggregate usage on the Mac and do not upload the source databases. The app uses mode `0700` for its config directory and `0600` for config and log files.

## Troubleshooting

### No menu bar icon

The app is menu-bar-only and has no Dock icon. Confirm that `LLM-monitor` is running in Activity Monitor and free some menu bar space if needed. A single-instance lock prevents duplicate launches.

### “Not configured” or a gray status dot

Make sure the provider is enabled, the credential is not a template placeholder, and Settings were saved. A gray dot means the app has not received successful data yet; it does not always mean a failure.

### Remote refresh fails

Check connectivity, credentials, subscription type, and local login state. The app retries with backoff, and you can Control-click the card to retry immediately. Inspect `log.txt` for details and redact it before sharing.

### Local token usage is empty

The corresponding client must have generated session data. Confirm that the database/session path exists and that the app can read it. Antigravity also needs its local service to be running. DeepSeek requires OpenCode merging for local usage.

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
4. Original client databases are never removed. The `.token-monitor` cache directories listed above may be deleted separately and will be rebuilt when needed.
