# UI Design Spec

This spec documents the UI that is currently implemented in `Sources/LLM-monitor/Views/`.

The detail lives in three files under `spec/ui/`, one per UI surface; this page is the
index and holds only what is cross-cutting.

## 文件导航

| 文件 | 覆盖的界面域 |
|---|---|
| `spec/ui/edge-dock.md` | 屏幕边缘状态窗（circle 构成、锚点几何、hover 浮层、四种 dock 形态、拖拽、2Hz 鼠标轮询预算） |
| `spec/ui/menu-and-cards.md` | 菜单栏图标、菜单窗口结构，以及两个宿主共用的 provider 卡（卡头 / 卡状态 / 额度行 / 配色 / 重置卡 / 字体） |
| `spec/ui/settings.md` | 原生设置窗口、菜单外框（header / content / 开机自启 / footer），以及设置页上的配额通知呈现 |

改通知的触发/渠道逻辑不在本组，见 `spec/notifications.md`。

## Principles

- **Display-first** — the compact menu focuses on status; configuration lives in a separate native Settings window.
- **Locally controlled changes** — Settings edits supported fields, while users can still edit `config.json` directly.
- **Fast scanning** — each provider card emphasizes reset time, remaining percent, and failure state.
- **Progressive detail** — default rows stay compact; hover reveals more detail in floating panels.
- **Provider isolation** — every provider is shown as a separate card, even when disabled or unconfigured.
- **System-native** — SwiftUI controls, SF Symbols, system colors, and system light/dark mode.

## Non-Goals

- No additional settings sheet inside the menu panel; provider toggles and API
  key fields belong to the dedicated Settings window.
- No custom visual theme beyond the menu bar icon theme selector.
- No custom font.
- No in-app provider deletion.

## UI Follow-Ups

These are useful future changes if the app grows:

> 核对基线：2026-10-04 · 代码 d6396fd
