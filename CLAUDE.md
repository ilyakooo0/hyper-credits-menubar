# UsageMenubar

## Architecture
macOS menu bar app (SwiftUI, macOS 14+) showing Hyper (Charm) credit balance, plus
Claude Code's Pro/Max usage limits when the CLI is signed in on the machine, plus
z.ai Coding Plan usage limits when an API key is entered in settings.
- `UsageMenubarApp.swift` — @main App, NSStatusBar, timer, sleep/wake, popover
- `ViewModel.swift` — Observable state: balance, Claude usage, z.ai usage, refresh, notifications, history
- `MenuView.swift` — SwiftUI popover view (balance, sparkline, Claude limits, z.ai limits, settings)
- `CreditsChecker.swift` — API client for `GET https://hyper.charm.land/v1/credits`
- `ClaudeUsageClient.swift` — read-only Claude OAuth client + models for `GET https://api.anthropic.com/api/oauth/usage`
- `ZaiUsageClient.swift` — API client for z.ai coding plan usage (`GET https://api.z.ai/api/monitor/usage/quota/limit` + `GET https://api.z.ai/api/biz/subscription/list`)
- `KeychainHelper.swift` — Keychain wrapper (KeychainStore + KeychainHelper + ZaiKeychainHelper)
- `VersionFormatter.swift` — Version string formatting

The status bar title shows `⚡{balance}` (Hyper), `🕐{percent}%` (Claude 5-hour),
`📅{percent}%` (Claude 7-day), and `🤖{percent}%` (z.ai 5-hour) — each omitted when
absent or at 0%. The three fetches are independent — `ViewModel.refresh()` runs them
with `async let`, and any can fail or be unconfigured without touching the others.

## Claude credentials (strictly read-only)
`ClaudeUsageClient` reads the credentials **Claude Code owns**: its `Claude Code-credentials`
Keychain item (via `/usr/bin/security`), falling back to `~/.claude/.credentials.json`.
- **Never write them. Never refresh the token.** `ClaudeCredentialStoring` has no `save`,
  and that is load-bearing, not an oversight. The app reads the current access token and
  spends it as-is.
- Why: the token endpoint **rotates the refresh token**, and the CLI refreshes on its own
  schedule. An app that also refreshed would race it — whoever went second would present a
  refresh token the server had already retired, signing the user out of their own terminal.
  This app *did* do that, and it was the top bug. Do not reintroduce it, however tempting a
  "just refresh it for the user" convenience looks.
- A spent or revoked token (401/403) is therefore terminal, not retried: it surfaces as
  `.invalidCredentials`, whose message tells the user to run `claude`. The CLI mints a new
  token; the next fetch (every 1–5 min, credentials re-read each time) picks it up for free.
- Consequently `ClaudeOAuthCredentials` models neither `refreshToken` nor `expiresAt` —
  nothing here has any business knowing them.
- Retries still apply to *transport* failures (timeouts, 5xx, 429). That's not auth.
- Missing credentials are **not an error** — the popover just omits the section.
- **The app cannot be sandboxed**: spawning `security` and reading `~/.claude` require it
  to be off. Distribution is ad-hoc signed via Homebrew, not the App Store.

## Build
- Uses [xcodegen](https://github.com/yonaskolb/XcodeGen) — `project.yml` is source of truth
- `xcodegen generate` creates the .xcodeproj (not committed)
- Build: `xcodebuild -scheme UsageMenubar -configuration Debug build`
- Test: `xcodebuild test -scheme UsageMenubar -configuration Debug -destination "platform=macOS"`
- Swift 5.9, macOS 14.0 deployment target

## Conventions
- Clean minimal UI — big hero number, generous spacing, restrained color, no chrome
- No card-heavy/multi-material/gradient-rich designs
- Rounded font family at one scale (hero/subhero/section/control/caption/footnote)
- Monospaced digits for numbers that change
- Tests use StubURLProtocol for network mocking, FakeKeychain for keychain mocking,
  FakeClaudeCredentialStore for Claude credentials — never touch the real ones in a test
- The app is an agent app (LSUIElement=true) — no dock icon, no main window

## VCS
- jj colocated with git
- Push directly to master — no PRs for this repo
