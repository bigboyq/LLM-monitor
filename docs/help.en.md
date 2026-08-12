# LLM Monitor User Guide

[Back to English README](../README.en.md) · [中文帮助](help.zh-CN.md)

## Requirements

- macOS 14 Sonoma or later.
- Apple Silicon and Intel Macs are supported.
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

Enable Minimax and enter a Token Plan API key. Local usage comes from `~/.minimax/v2/sqlite/runtime-state.sqlite`. Enable the OpenCode merge option to include `minimax-cn-coding-plan` usage.

### ChatGPT Plan / Codex

Sign in with the Codex CLI and make sure `~/.codex/auth.json` exists. The default auth path normally needs no change. Remote quota comes from the ChatGPT usage API; local usage is aggregated from `~/.codex/sessions` and `~/.codex/archived_sessions`.

### Antigravity

Start and sign in to Antigravity IDE or the `agy` CLI. LLM Monitor discovers the local `language_server` and uses loopback RPC for account, quota, and trajectory token data. If the service is shown as offline, keep Antigravity running and confirm its login state.

### GLM Coding Plan

Enter a Coding Plan key, commonly in `id.secret` format. Remote quota comes from GLM; local ZCode usage comes from `~/.zcode/cli/db/db.sqlite`. The default peak window is Monday through Friday, 14:00–18:00 in the Mac's local time, and can be changed in Settings.

### DeepSeek

Enter a DeepSeek `sk-...` API key. The card displays account balance. DeepSeek has no native local ledger, so local token charts require the OpenCode merge option. Peak-period status uses Beijing time and treats weekends as off-peak by default.

### OpenCode merge

The app reads `~/.local/share/opencode/opencode.db` and separates rows by `providerID`. OpenCode is not a standalone card. Enable or disable its merge independently on each provider settings page. GLM defaults to enabled; other providers default to disabled.

## Everyday controls

- Click the menu bar icon to open or close the panel.
- Use the refresh button to refresh all enabled providers now.
- Control-click a provider card to refresh it or open the config file.
- Hover over titles, quota rows, and local-usage footers for account details, window details, recent prompts, and seven-day charts.
- Use Settings → General for refresh intervals, icon style, health-dot visibility, and launch at login. When enabled, a 4 pt status dot appears at the lower-right: green for healthy, orange for warning, and red for critical.
- Disabled providers are hidden and do not make network requests.

## Privacy and local files

| Data | Path |
|---|---|
| Configuration | `~/Library/Application Support/LLM-monitor/config.json` |
| Logs | `~/Library/Application Support/LLM-monitor/log.txt` |
| Last successful remote state | `~/Library/Application Support/LLM-monitor/last-refresh.json` |
| Minimax scanner cache | `~/.minimax/.token-monitor/` |
| Antigravity scanner cache | `~/.gemini/antigravity/.token-monitor/` |
| ZCode scanner cache | `~/.zcode/cli/.token-monitor/` |
| OpenCode scanner cache | `~/.local/share/opencode/.token-monitor/` |

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

### macOS blocks the app

This Release is an ad-hoc-signed snapshot. Verify its SHA-256, then Control-click the app in Finder and choose **Open**. Do not bypass Gatekeeper for copies from untrusted sources.

## Uninstall

1. Disable launch at login in Settings and quit the app.
2. Remove `/Applications/LLM-monitor.app`.
3. To remove settings and logs, delete `~/Library/Application Support/LLM-monitor/`.
4. Original client databases are never removed. The `.token-monitor` cache directories listed above may be deleted separately and will be rebuilt when needed.
