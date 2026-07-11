# UsageMenubar

## Architecture
macOS menu bar app (SwiftUI, macOS 14+) showing Hyper (Charm) credit balance, plus
Claude Code's Pro/Max usage limits when the CLI is signed in on the machine.
- `UsageMenubarApp.swift` — @main App, NSStatusBar, timer, sleep/wake, popover
- `ViewModel.swift` — Observable state: balance, Claude usage, refresh, notifications, history
- `MenuView.swift` — SwiftUI popover view (balance, sparkline, Claude limits, settings)
- `CreditsChecker.swift` — API client for `GET https://hyper.charm.land/v1/credits`
- `ClaudeUsageClient.swift` — Claude OAuth client + models for `GET https://api.anthropic.com/api/oauth/usage`
- `KeychainHelper.swift` — Keychain wrapper (KeychainStore + KeychainHelper)
- `VersionFormatter.swift` — Version string formatting

The status bar title stays `⚡{balance}` (Hyper only); Claude usage lives in the popover.
The two fetches are independent — `ViewModel.refresh()` runs them with `async let`, and
either can fail or be unconfigured without touching the other.

## Claude credentials (read-only, with one exception)
`ClaudeUsageClient` reads the credentials **Claude Code owns**: its `Claude Code-credentials`
Keychain item (via `/usr/bin/security`), falling back to `~/.claude/.credentials.json`.
- Never modify them, except the token refresh, which writes back a rotated token to
  whichever source it was read from, preserving fields we don't model (patched raw JSON).
- The refresh endpoint **rotates the refresh token** — refreshing twice with the same one
  signs the user out of their own CLI. Hence the client is an `actor` and dedups
  concurrent refreshes onto one in-flight, cancellation-immune `Task`.
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
