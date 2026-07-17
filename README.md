<p align="center">
  <img src="UsageMenubar/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="128" height="128" alt="Usage Menubar app icon">
</p>

# UsageMenubar

A macOS menu bar application that displays usage limits and credit balances for multiple LLM services: [Hyper (Charm)](https://hyper.charm.land), [Claude Code](https://claude.com/claude-code), and [z.ai](https://z.ai) Coding Plans. Each service is independent — configure the ones you use, ignore the ones you don't.

## Features

- ⚡ **Hyper credits** — balance from `hyper.charm.land`, with sparkline trend, click-to-copy, and low-balance notifications
- ⁕ **Claude Code limits** — Pro/Max 5-hour and 7-day usage windows, with countdown to next reset. No setup: if you've signed in with the Claude Code CLI, it just appears
- Z **z.ai Coding Plan** — 5-hour and weekly token quota percentages, with reset countdowns. Enter your API key in settings
- 🔄 **Auto-refresh** — configurable interval (1m / 5m / 15m / 30m), plus refresh on wake from sleep
- 🖱️ **Right-click menu** — quick access to Refresh and Quit
- 🔒 **Keychain storage** — API keys stored securely in macOS Keychain
- 🚀 **Launch at login** — optional, using `SMAppService`
- 🫥 **Agent app** — no dock icon, no main window; lives entirely in the menu bar

## Menu bar

Each service shows an emoji-prefixed segment when configured and above 0%:

| Service | Emoji | Example |
|---------|-------|---------|
| Hyper balance | ⚡ | `⚡42` |
| Claude 5-hour | ⁕ | `⁕62%` |
| Claude 7-day | ⁕ | `⁕8%` |
| z.ai 5-hour | Z | `Z12%` |
| z.ai weekly | Z | `Z3%` |

Unconfigured services don't appear at all — no placeholder, no icon.

## Installation

### Homebrew (recommended)

```bash
brew tap ilyakooo0/tap
brew install --cask usage-menubar
```

Or in one command:

```bash
brew install --cask ilyakooo0/tap/usage-menubar
```

### Download the pre-built release

1. Go to the [Releases page](https://github.com/ilyakooo0/usage-menubar/releases)
2. Download the latest `UsageMenubar-*.zip`
3. Unzip and move `UsageMenubar.app` to `/Applications`
4. Launch the app — it will appear in your menu bar

> **Note:** Releases are **ad-hoc signed** — the CI build applies `codesign -s -` to the app, which gives it a stable code identity but is *not* an Apple Developer ID signature. macOS will still warn you on first launch: right-click the app → **Open**, or allow it in **System Settings → Privacy & Security**. Removing that prompt entirely requires a paid Developer ID certificate and notarization.

## Setup

Click the menu bar icon to open the popover. Each service is configured independently:

### Hyper credits

1. Enter your Hyper API key (starts with `sk-...`) in the **Hyper API Key** field
2. Click **Save**
3. Your balance appears immediately

Get your key from [hyper.charm.land](https://hyper.charm.land).

### Claude Code limits (no setup)

If you use the [Claude Code CLI](https://claude.com/claude-code), the popover shows how much of your Pro/Max plan you have used: the 5-hour and 7-day windows, and how long until the next reset.

There is nothing to configure. The app reads the OAuth credentials Claude Code already stores when you run `claude` and sign in — first from its login-Keychain item, then from `~/.claude/.credentials.json` if the Keychain has nothing. If neither exists, the Claude section doesn't appear.

- **macOS will ask once.** Those credentials belong to Claude Code, not to this app, so the first read prompts you to allow access to the `Claude Code-credentials` Keychain item. Choose **Always Allow** and you won't be asked again.
- **The credentials are strictly read-only.** The app reads the access token Claude Code stored and spends it as-is. It never refreshes it, and never writes those credentials back — that is the CLI's job alone. If the token has expired, the Claude section says so and asks you to run `claude`.

### z.ai Coding Plan

1. Enter your z.ai API key in the **z.ai API Key** field
2. Click **Save**
3. Your 5-hour and weekly quota percentages appear immediately

Get your key from [z.ai/manage-apikey](https://z.ai/manage-apikey/coding-plan/personal/my-plan).

## Settings

Everything is configured from the popover — click the menu bar icon.

| Setting             | Where                          | Notes                                                                                |
| ------------------- | ------------------------------ | ------------------------------------------------------------------------------------ |
| **Hyper API key**   | **Hyper API Key** field → **Save**   | Stored in the macOS Keychain. Clearing the field and saving deletes the stored key.  |
| **z.ai API key**    | **z.ai API Key** field → **Save**    | Stored separately from the Hyper key. |
| **Launch at login** | **Launch at Login** toggle     | Registers the app with `SMAppService`.                                               |
| **Notifications**   | System permission prompt       | macOS asks on first launch (only if not already decided). Required for low-balance alerts. |
| **Refresh now**     | **Refresh** button             | Forces an immediate fetch, on top of the automatic refresh.                            |
| **Refresh interval**| **Refresh every** picker       | Choose 1m, 5m, 15m, or 30m. Defaults to 5m. Stored in `UserDefaults` and persisted across launches. |

The app also refreshes automatically when your Mac wakes from sleep.

## Build from source

### Prerequisites

- macOS 14.0+ (Sonoma)
- Xcode 15+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Steps

```bash
# Clone the repository
git clone https://github.com/ilyakooo0/usage-menubar.git
cd usage-menubar

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open UsageMenubar.xcodeproj

# Or build from the command line
xcodebuild \
  -scheme UsageMenubar \
  -configuration Release \
  -archivePath build/UsageMenubar.xcarchive \
  archive \
  CODE_SIGNING_ALLOWED=NO
```

### Run tests

```bash
xcodebuild test \
  -scheme UsageMenubar \
  -configuration Debug \
  -destination "platform=macOS"
```

## Versioning

Versions follow the format `YYYY.MM.DD.HHHH` where `HHHH` is the UTC hour and minute (24-hour).

| Commit time (UTC)        | Version           |
| ------------------------ | ----------------- |
| 2026-07-09 14:23         | `2026.07.09.1423` |
| 2026-01-01 00:00         | `2026.01.01.0000` |
| 2026-12-31 23:59         | `2026.12.31.2359` |

The version is derived automatically from the commit timestamp in the GitHub Actions release workflow.

## Project structure

```
usage-menubar/
├── project.yml                          # xcodegen project definition
├── UsageMenubar/
│   ├── UsageMenubarApp.swift            # @main App, NSStatusBar, timer, sleep/wake
│   ├── ViewModel.swift                  # Observable state: balance, Claude usage, z.ai usage, refresh
│   ├── MenuView.swift                   # SwiftUI popover view
│   ├── CreditsChecker.swift             # Hyper API client (GET /v1/credits)
│   ├── ClaudeUsageClient.swift          # Claude OAuth client (GET /api/oauth/usage) + models
│   ├── ZaiUsageClient.swift             # z.ai API client (GET /monitor/usage/quota/limit)
│   ├── KeychainHelper.swift             # Keychain wrapper (Hyper + z.ai keys)
│   ├── VersionFormatter.swift           # YYYY.MM.DD.HHHH formatting
│   ├── Info.plist                       # LSUIElement=true (agent app)
│   ├── UsageMenubar.entitlements        # Network client; deliberately not sandboxed
│   └── Assets.xcassets/                 # App icon, accent color
├── UsageMenubarTests/
│   ├── CreditsCheckerTests.swift        # Hyper API, retry, keychain, StubURLProtocol
│   ├── ClaudeUsageClientTests.swift     # Usage decoding, read-only credential store, retry
│   ├── ZaiUsageClientTests.swift        # z.ai API, retry, decoding
│   ├── StatusBarTextTests.swift         # Menu bar title formatting
│   └── VersionFormatterTests.swift      # Version formatting tests
├── .github/workflows/
│   └── release.yml                      # Build + release on push to master
├── README.md
├── LICENSE
└── .gitignore
```

## How it works

1. **Menu bar item**: The app creates an `NSStatusItem` with a variable-length button. Left-click toggles the popover; right-click opens a context menu (Refresh, Quit).
2. **Popover**: Clicking the menu bar item shows an `NSPopover` containing a SwiftUI `MenuView` with each configured service's data and the settings.
3. **Independent fetches**: `ViewModel.refresh()` runs the Hyper, Claude, and z.ai requests concurrently with `async let`. Any can fail, stall, or be unconfigured without affecting the others.
4. **Hyper API client**: `CreditsChecker` performs `GET https://hyper.charm.land/v1/credits` with `Authorization: Bearer <key>`, retries transient failures with exponential backoff, and decodes `{"balance": <int>}`.
5. **Claude usage**: `ClaudeUsageClient` reads Claude Code's OAuth credentials (its `Claude Code-credentials` Keychain item via `/usr/bin/security`, falling back to `~/.claude/.credentials.json`) and fetches `GET https://api.anthropic.com/api/oauth/usage`. It is strictly read-only — it never refreshes the token and never writes credentials back. Missing credentials are reported as "not configured" rather than as an error, and the popover hides the section.
6. **z.ai usage**: `ZaiUsageClient` fetches `GET https://api.z.ai/api/monitor/usage/quota/limit` and `GET https://api.z.ai/api/biz/subscription/list` concurrently with an API key the user enters in settings. Same retry pattern as the other clients.
7. **Keychain**: API keys are stored/retrieved via `KeychainHelper` using the macOS Security framework. Hyper and z.ai keys are stored separately.
8. **Timer**: A `Timer` fires at the user-selected interval (1m / 5m / 15m / 30m, default 5m); the app also refreshes on wake from sleep.
9. **Notifications**: When the Hyper balance crosses below 10 credits — or is already below 10 on the first successful fetch — `ViewModel` posts a local `UNUserNotification`. Permission is requested only once.
10. **Agent app**: `LSUIElement=true` in `Info.plist` makes the app a background agent — no dock icon, no main window.
11. **No sandbox**: Reading credentials that belong to another app means spawning `/usr/bin/security` and reading a file in the user's home directory, neither of which the App Sandbox permits. The app is distributed ad-hoc signed via Homebrew rather than through the App Store, where the sandbox would be mandatory.

## License

MIT — see [LICENSE](LICENSE).