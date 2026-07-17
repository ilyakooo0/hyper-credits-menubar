<p align="center">
  <img src="UsageMenubar/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="128" height="128" alt="Usage Menubar app icon">
</p>

# UsageMenubar

A macOS menu bar application that displays your [Hyper (Charm)](https://hyper.charm.land) credit balance — and, if you use the Claude Code CLI, your Claude subscription limits alongside it.

## Features

- ⚡ **Menu bar display** — shows `⚡{balance}` (e.g. `⚡42`) right in your menu bar
- 🤖 **Claude Code limits** — your Pro/Max 5-hour and 7-day usage windows in the popover, with the percentage used and a countdown to the next reset. No setup: if you have signed in with the Claude Code CLI, it just appears. If you haven't, the section doesn't
- 🔄 **Auto-refresh** — fetches your balance on a configurable interval (1m / 5m / 15m / 30m), and again on wake from sleep
- 📊 **Balance sparkline** — a subtle mini-chart in the popover shows your balance trend over recent fetches
- 📋 **Click-to-copy** — click the balance number in the popover to copy it to the clipboard
- 🖱️ **Right-click menu** — right-click the menu bar icon for quick access to Refresh, Open hyper.charm.land, and Quit
- 🔔 **Low-balance notifications** — alerts you when your balance drops below 10 credits, including on the very first fetch if you are already below the threshold
- 🔒 **Keychain storage** — your API key is stored securely in macOS Keychain
- 🎨 **Color-coded balance** — green (≥100), yellow (10–99), red (<10)
- 🔐 **Secure input** — API key field is masked
- 🚀 **Launch at login** — optional, using `SMAppService`
- 🔑 **Get key link** — quick link to [hyper.charm.land](https://hyper.charm.land) right next to the API key field
- 🫥 **Agent app** — no dock icon, no main window; lives entirely in the menu bar

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
4. Launch the app — it will appear in your menu bar as ⚡

> **Note:** Releases are **ad-hoc signed** — the CI build applies `codesign -s -` to the app, which gives it a stable code identity but is *not* an Apple Developer ID signature. macOS will still warn you on first launch: right-click the app → **Open**, or allow it in **System Settings → Privacy & Security**. Removing that prompt entirely requires a paid Developer ID certificate and notarization.

### Set your API key

1. Click the ⚡ icon in your menu bar
2. Enter your Hyper API key (starts with `sk-...`) in the **API Key** field
3. Click **Save**
4. Your balance will appear immediately

You can get your API key from [hyper.charm.land](https://hyper.charm.land).

### Claude Code limits (optional, no setup)

If you use the [Claude Code CLI](https://claude.com/claude-code), the popover also shows how much of your Pro/Max plan you have used: the limit currently in effect as a headline percentage, the 5-hour and 7-day windows underneath, and how long until the next reset.

There is nothing to configure. The app reads the OAuth credentials Claude Code already stores when you run `claude` and sign in — first from its login-Keychain item, then from `~/.claude/.credentials.json` if the Keychain has nothing. If neither exists, the Claude section simply doesn't appear; it is not treated as an error, and the Hyper balance is unaffected.

Two things worth knowing:

- **macOS will ask once.** Those credentials belong to Claude Code, not to this app, so the first read prompts you to allow access to the `Claude Code-credentials` Keychain item. Choose **Always Allow** and you won't be asked again.
- **The credentials are strictly read-only.** The app reads the access token Claude Code stored and spends it as-is. It never refreshes it, and never writes those credentials back — that is the CLI's job alone. (Refreshing rotates the refresh token, so an app doing it behind the CLI's back would race it and sign you out of your own terminal.) If the token has expired, the Claude section says so and asks you to run `claude`; once the CLI has refreshed on its own, the app picks the new token up on its next fetch.

## Settings

Everything is configured from the popover — click the ⚡ icon in the menu bar.

| Setting             | Where                          | Notes                                                                                |
| ------------------- | ------------------------------ | ------------------------------------------------------------------------------------ |
| **API key**         | **API Key** field → **Save**   | Stored in the macOS Keychain. Clearing the field and saving deletes the stored key.  |
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
│   ├── ViewModel.swift                  # Observable state: balance, Claude usage, refresh, notifications
│   ├── MenuView.swift                   # SwiftUI popover view
│   ├── CreditsChecker.swift             # API client (GET /v1/credits)
│   ├── ClaudeUsageClient.swift          # Claude OAuth client (GET /api/oauth/usage) + models
│   ├── KeychainHelper.swift             # Keychain wrapper for API key
│   ├── VersionFormatter.swift           # YYYY.MM.DD.HHHH formatting
│   ├── Info.plist                       # LSUIElement=true (agent app)
│   ├── UsageMenubar.entitlements # Network client; deliberately not sandboxed
│   └── Assets.xcassets/                 # App icon, accent color
├── UsageMenubarTests/
│   ├── CreditsCheckerTests.swift        # API, retry, fractional balance, keychain tests
│   ├── ClaudeUsageClientTests.swift     # Usage decoding, read-only credential store, retry
│   └── VersionFormatterTests.swift      # Version formatting tests
├── .github/workflows/
│   └── release.yml                      # Build + release on push to master
├── README.md
├── LICENSE
└── .gitignore
```

## How it works

1. **Menu bar item**: The app creates an `NSStatusItem` with a variable-length button showing `⚡{balance}` or `⚡?`. Left-click toggles the popover; right-click opens a context menu (Refresh, Open hyper.charm.land, Quit).
2. **Popover**: Clicking the menu bar item shows an `NSPopover` containing a SwiftUI `MenuView` with the balance, sparkline, API key field, and settings.
3. **API client**: `CreditsChecker` performs `GET https://hyper.charm.land/v1/credits` with `Authorization: Bearer <key>`, retries transient failures (5xx, timeouts) with exponential backoff, and decodes `{"balance": <int>}` (tolerating fractional values by rounding).
4. **Keychain**: The API key is stored/retrieved via `KeychainHelper` using the macOS Security framework. `save()` returns a `Bool` indicating success.
5. **Timer**: A `Timer` fires at the user-selected interval (1m / 5m / 15m / 30m, default 5m) to refresh the balance; the app also refreshes on wake from sleep. Changing the interval in the popover restarts the timer immediately.
6. **State**: `ViewModel` owns the balance, loading/error state, balance history (for the sparkline), refresh task (cancellable to prevent races), and the refresh interval, and is shared between the menu bar item and the popover.
7. **Notifications**: When the balance crosses below 10 credits — or is already below 10 on the first successful fetch — `ViewModel` posts a local `UNUserNotification`. Permission is requested only once.
8. **Agent app**: `LSUIElement=true` in `Info.plist` makes the app a background agent — no dock icon, no main window.
9. **Claude usage**: `ClaudeUsageClient` reads Claude Code's OAuth credentials (its `Claude Code-credentials` Keychain item via `/usr/bin/security`, falling back to `~/.claude/.credentials.json`) and fetches `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer` and `anthropic-beta: oauth-2025-04-20`. It is strictly read-only — it never refreshes the token and never writes credentials back. The token endpoint rotates the refresh token, so an app that also refreshed would race the CLI and sign the user out of their own terminal. When the token is spent (401/403), the app says so and points at `claude`; the next fetch (every 1–5 min, credentials re-read each time) picks up whatever the CLI refreshed on its own. Missing credentials are reported as "not configured" rather than as an error, and the popover hides the section.
10. **Independent fetches**: `ViewModel.refresh()` runs the Hyper and Claude requests concurrently with `async let`. Neither can fail, stall, or be unconfigured in a way that affects the other.
11. **No sandbox**: Reading credentials that belong to another app means spawning `/usr/bin/security` and reading a file in the user's home directory, neither of which the App Sandbox permits. The app is distributed ad-hoc signed via Homebrew rather than through the App Store, where the sandbox would be mandatory.

## License

MIT — see [LICENSE](LICENSE).
