import Foundation
import SwiftUI
import Combine
import ServiceManagement
import UserNotifications

/// Posted when the user changes the refresh interval, so the app delegate can
/// restart its timer with the new period.
extension Notification.Name {
    static let refreshIntervalDidChange = Notification.Name("soy.iko.usage-menubar.refreshIntervalDidChange")
}

/// The direction a metric has moved over the most recent history points.
enum MetricTrend {
    case increasing
    case decreasing
    case stable
    /// Not enough history to say.
    case unknown

    /// SF Symbol for the trend, or `nil` when there is nothing worth showing.
    var symbolName: String? {
        switch self {
        case .increasing: return "arrow.up.right"
        case .decreasing: return "arrow.down.right"
        case .stable: return "arrow.right"
        case .unknown: return nil
        }
    }
}

/// A single metric observation — used for Hyper balance, Claude 5-hour %,
/// and z.ai 5-hour % alike.
struct MetricPoint: Equatable {
    let date: Date
    let value: Int
}

/// How often the balance is refreshed. Lives outside `ViewModel` so the view and
/// the app delegate can read the options without hopping onto the main actor.
enum RefreshInterval {
    /// `UserDefaults` key for the refresh period, in minutes.
    static let defaultsKey = "refreshIntervalMinutes"

    /// The intervals offered in the settings picker.
    static let options = [1, 5, 15, 30]

    /// Used when nothing valid is stored.
    static let defaultMinutes = 5

    /// Reads the stored interval, falling back to the default when unset or when
    /// the stored value isn't one we offer.
    static func stored(in defaults: UserDefaults = .standard) -> Int {
        let minutes = defaults.integer(forKey: defaultsKey)
        guard options.contains(minutes) else { return defaultMinutes }
        return minutes
    }
}

/// The view model that drives the menu bar display and the popover content.
@MainActor
final class ViewModel: ObservableObject {
    /// The last known balance. `nil` when there has never been a successful fetch.
    @Published var balance: Int?

    /// `true` while a balance request is in flight.
    @Published var isLoading = false

    /// A human-readable error message, shown when the balance can't be fetched.
    @Published var errorMessage: String?

    /// Claude Code's subscription usage. `nil` when Claude Code has never signed in on
    /// this machine, in which case the popover leaves the section out entirely rather
    /// than nagging someone who doesn't use it.
    @Published var claudeUsage: ClaudeUsage?

    /// A human-readable error message from the Claude fetch. Independent of
    /// `errorMessage`: the two services fail separately.
    @Published var claudeError: String?

    /// The Claude plan the credentials belong to — `"pro"`, `"max"`, …
    @Published var claudePlan: String?

    /// z.ai Coding Plan usage. `nil` when no z.ai API key has been entered, in which
    /// case the popover leaves the section out entirely.
    @Published var zaiUsage: ZaiUsageReport?

    /// A human-readable error message from the z.ai fetch. Independent of
    /// `errorMessage` and `claudeError`: the three services fail separately.
    @Published var zaiError: String?

    /// The z.ai API key draft bound to the text field. Two-way bound to the
    /// `SecureField`, so it changes on every keystroke — never fetch with it, use
    /// `activeZaiAPIKey`.
    @Published var zaiAPIKeyInput: String = ""

    /// Whether Hyper is configured — i.e. there is an API key in the Keychain.
    /// Drives whether the `⚡` segment appears in the menu bar at all: an
    /// unconfigured service should not take up space in the title.
    @Published private(set) var hyperConfigured = false

    /// The API key draft bound to the text field. Two-way bound to the `SecureField`,
    /// so it changes on every keystroke — never fetch with it, use `activeAPIKey`.
    @Published var apiKeyInput: String = ""

    /// Timestamp of the last successful balance fetch.
    @Published var lastUpdated: Date?

    /// Brief "✓ Saved" confirmation shown after saving the API key.
    @Published var savedConfirmation: Bool = false

    /// Brief "✓ Copied" confirmation shown after copying the balance.
    @Published var copiedConfirmation: Bool = false

    /// Brief "✓ Copied" confirmation shown after copying the Claude percentage.
    @Published var copiedClaudeConfirmation: Bool = false

    /// Brief "✓ Copied" confirmation shown after copying the z.ai percentage.
    @Published var copiedZaiConfirmation: Bool = false

    /// Successful balance observations from the last 24 hours, oldest first.
    @Published private(set) var history: [MetricPoint] = []

    /// Successful Claude 5-hour % observations from the last 24 hours, oldest first.
    @Published private(set) var claudeHistory: [MetricPoint] = []

    /// Successful z.ai 5-hour % observations from the last 24 hours, oldest first.
    @Published private(set) var zaiHistory: [MetricPoint] = []

    /// How often the balance is refreshed, in minutes. Persisted to `UserDefaults`;
    /// changing it posts `.refreshIntervalDidChange` so the app delegate can
    /// restart its timer.
    @Published var refreshIntervalMinutes: Int {
        didSet {
            guard refreshIntervalMinutes != oldValue else { return }
            defaults.set(refreshIntervalMinutes, forKey: RefreshInterval.defaultsKey)
            NotificationCenter.default.post(name: .refreshIntervalDidChange, object: nil)
        }
    }

    /// Whether launch-at-login is enabled.
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isInitializingLaunchAtLogin else { return }
            updateLaunchAtLogin(launchAtLogin)
        }
    }

    /// Flag to suppress the didSet during initial setup.
    private var isInitializingLaunchAtLogin = true

    /// The key requests actually go out with: what is in the Keychain, not what is
    /// currently in the text field. Keeping these separate stops a timer or wake
    /// refresh from firing with a half-typed key — or, if the field has been cleared
    /// to paste a new one, from taking the empty-key path and wiping the balance,
    /// last-updated time and history out from under the user.
    private var activeAPIKey: String

    /// The z.ai key requests actually go out with: what is in the Keychain, not what
    /// is currently in the text field. Same rationale as `activeAPIKey`.
    private var activeZaiAPIKey: String

    private let checker: CreditsChecking
    private let claudeChecker: ClaudeUsageChecking
    private let zaiChecker: ZaiUsageChecking
    private let defaults: UserDefaults

    /// The currently in-flight refresh task, if any. Used to cancel
    /// overlapping refreshes (timer + user click + wake).
    private var refreshTask: Task<Void, Never>?

    /// Resets `copiedConfirmation`; held so rapid clicks re-arm the delay
    /// instead of the first click's reset firing early.
    private var copiedResetTask: Task<Void, Never>?

    /// Resets `savedConfirmation`; same rationale as `copiedResetTask`.
    private var savedResetTask: Task<Void, Never>?

    /// Resets `copiedClaudeConfirmation`; same rationale as `copiedResetTask`.
    private var copiedClaudeResetTask: Task<Void, Never>?

    /// Resets `copiedZaiConfirmation`; same rationale as `copiedResetTask`.
    private var copiedZaiResetTask: Task<Void, Never>?

    // MARK: - History Configuration

    /// 24 hours at the shortest (1 minute) interval would overflow this, so the
    /// count cap and the age cutoff both apply; whichever bites first wins.
    private static let maxHistoryEntries = 300
    private static let historyWindow: TimeInterval = 24 * 60 * 60

    /// The threshold above which a usage percentage triggers a notification.
    private static let highUsageThreshold = 90

    init(
        checker: CreditsChecking = CreditsChecker(),
        claudeChecker: ClaudeUsageChecking = ClaudeUsageClient(),
        zaiChecker: ZaiUsageChecking = ZaiUsageClient(),
        defaults: UserDefaults = .standard
    ) {
        self.checker = checker
        self.claudeChecker = claudeChecker
        self.zaiChecker = zaiChecker
        self.defaults = defaults
        let storedKey = KeychainHelper.load() ?? ""
        apiKeyInput = storedKey
        activeAPIKey = storedKey
        hyperConfigured = !storedKey.isEmpty
        let storedZaiKey = ZaiKeychainHelper.load() ?? ""
        zaiAPIKeyInput = storedZaiKey
        activeZaiAPIKey = storedZaiKey
        // Assigning in init doesn't fire didSet, so this load doesn't re-post
        // the change notification or write back to defaults.
        refreshIntervalMinutes = RefreshInterval.stored(in: defaults)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        isInitializingLaunchAtLogin = false
    }

    // MARK: - Balance

    /// Cached number formatter for balance display.
    private static let balanceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    /// Cached relative time formatter for "Updated Xm ago" text.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    /// Formats an integer with thousands grouping separator.
    private static func formatBalance(_ value: Int) -> String {
        balanceFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// The text to show in the menu bar. Each configured provider contributes a
    /// segment prefixed with a provider emoji; segments are separated by ` · `
    /// (middle dot). Within a segment, windows are listed as bare percentages
    /// separated by spaces. An unconfigured service produces no segment.
    /// When z.ai is in peak hours, a 🔶 marker is appended to the z.ai segment.
    ///
    /// Example: `⚡42 · 🅲62% 8% · 🅉12% 3%🔶`
    ///
    /// Takes its values as parameters rather than reading the properties: `@Published`
    /// publishes in `willSet`, so a Combine subscriber that called back into the view
    /// model would see the *pre-change* value and render a title one update behind.
    static func statusBarText(
        balance: Int?,
        isLoading: Bool,
        hyperConfigured: Bool,
        claudeFiveHourPercent: Int?,
        claudeSevenDayPercent: Int?,
        zaiFiveHourPercent: Int?,
        zaiWeeklyPercent: Int?,
        zaiInPeakHours: Bool
    ) -> String {
        var segments: [String] = []

        // Hyper
        if hyperConfigured, let balance = balance {
            segments.append("⚡\(formatBalance(balance))")
        }

        // Claude — provider emoji + bare percentages
        var claudeWindows: [String] = []
        if let fiveHour = claudeFiveHourPercent {
            claudeWindows.append("\(fiveHour)%")
        }
        if let sevenDay = claudeSevenDayPercent {
            claudeWindows.append("\(sevenDay)%")
        }
        if !claudeWindows.isEmpty {
            segments.append("🅲" + claudeWindows.joined(separator: " "))
        }

        // z.ai — provider emoji + bare percentages
        var zaiWindows: [String] = []
        if let zaiFiveHour = zaiFiveHourPercent {
            zaiWindows.append("\(zaiFiveHour)%")
        }
        if let zaiWeekly = zaiWeeklyPercent {
            zaiWindows.append("\(zaiWeekly)%")
        }
        if !zaiWindows.isEmpty {
            var segment = "🅉" + zaiWindows.joined(separator: " ")
            if zaiInPeakHours {
                segment += "🔶"
            }
            segments.append(segment)
        }

        if segments.isEmpty {
            // No service is configured or has anything to show. While loading,
            // show an ellipsis; otherwise the title is empty.
            return isLoading ? "…" : ""
        }
        return segments.joined(separator: " · ")
    }

    /// The text to show in the menu bar for the current state.
    var statusBarItemText: String {
        Self.statusBarText(
            balance: balance,
            isLoading: isLoading,
            hyperConfigured: hyperConfigured,
            claudeFiveHourPercent: claudeFiveHourPercent,
            claudeSevenDayPercent: claudeSevenDayPercent,
            zaiFiveHourPercent: zaiFiveHourPercent,
            zaiWeeklyPercent: zaiWeeklyPercent,
            zaiInPeakHours: Self.zaiInPeakHours
        )
    }

    /// Whether z.ai is currently in peak hours (06:00–10:00 UTC).
    static var zaiInPeakHours: Bool {
        let hour = Calendar(identifier: .gregorian).component(.hour, from: Date())
        return hour >= 6 && hour < 10
    }

    /// The formatted balance string for display in the popover.
    var formattedBalance: String {
        guard let balance = balance else { return "?" }
        return Self.formatBalance(balance)
    }

    /// The color for the balance display based on thresholds.
    var balanceColor: Color {
        guard let balance = balance else { return .secondary }
        if balance >= 100 { return .green }
        if balance >= 10 { return .yellow }
        return .red
    }

    /// Relative time string for the last successful update, or nil if never updated.
    var lastUpdatedText: String? {
        guard let lastUpdated = lastUpdated else { return nil }
        return "Updated \(Self.relativeFormatter.localizedString(for: lastUpdated, relativeTo: Date()))"
    }

    // MARK: - History (Hyper)

    /// The last 24 hours of successful balance fetches, oldest first.
    var balanceHistory: [(date: Date, balance: Int)] {
        history.map { (date: $0.date, balance: $0.value) }
    }

    /// The direction of travel across the most recent handful of observations.
    /// `.unknown` until there are at least two points to compare.
    var balanceTrend: MetricTrend {
        metricTrend(history)
    }

    /// The sparkline's data for the Hyper balance.
    var balanceSparklineValues: [Int] {
        history.map { $0.value }
    }

    // MARK: - History (Claude)

    /// The last 24 hours of successful Claude 5-hour % fetches, oldest first.
    var claudeSparklineValues: [Int] {
        claudeHistory.map { $0.value }
    }

    /// The direction of travel for the Claude 5-hour %.
    var claudeTrend: MetricTrend {
        metricTrend(claudeHistory)
    }

    // MARK: - History (z.ai)

    /// The last 24 hours of successful z.ai 5-hour % fetches, oldest first.
    var zaiSparklineValues: [Int] {
        zaiHistory.map { $0.value }
    }

    /// The direction of travel for the z.ai 5-hour %.
    var zaiTrend: MetricTrend {
        metricTrend(zaiHistory)
    }

    // MARK: - History Helpers

    /// Computes the trend from a generic history array.
    private func metricTrend(_ points: [MetricPoint]) -> MetricTrend {
        guard points.count >= 2 else { return .unknown }
        let recent = points.suffix(5)
        guard let first = recent.first, let last = recent.last else { return .unknown }
        if last.value > first.value { return .increasing }
        if last.value < first.value { return .decreasing }
        return .stable
    }

    /// Appends an observation and drops anything older than 24 hours or beyond the cap.
    private func recordMetric(_ value: Int, into array: inout [MetricPoint], at date: Date) {
        array.append(MetricPoint(date: date, value: value))

        let cutoff = date.addingTimeInterval(-Self.historyWindow)
        array.removeAll { $0.date < cutoff }

        if array.count > Self.maxHistoryEntries {
            array.removeFirst(array.count - Self.maxHistoryEntries)
        }
    }

    // MARK: - Refresh

    /// Refreshes the Hyper balance, the Claude usage, and the z.ai usage, all at once.
    ///
    /// The three are independent: any can fail, or not be configured at all, without
    /// touching the others. Cancels any previously in-flight refresh to prevent races.
    func refresh() {
        refreshTask?.cancel()

        // Deliberately the saved key rather than `apiKeyInput`: see `activeAPIKey`.
        let key = activeAPIKey
        let zaiKey = activeZaiAPIKey
        if key.isEmpty {
            // Nothing to fetch, and nothing worth keeping: the balance, its history and
            // any error all belonged to a key that is no longer there. Claude and z.ai
            // are left alone — they don't depend on the Hyper key.
            balance = nil
            errorMessage = nil
            lastUpdated = nil
            history.removeAll()
        }

        refreshTask = Task { @MainActor in
            // Check cancellation before setting isLoading — a previous
            // refresh() may have cancelled us and already set isLoading = false.
            guard !Task.isCancelled else { return }
            // Loading state covers all fetches: the popover's loading view depends
            // on it, and Claude/z.ai usage is fetched even when there's no Hyper key.
            isLoading = true
            // Don't clear the errors here — keep showing the last one
            // until we have a successful result.

            // All three requests go out at once; none waits on the others.
            async let balanceOutcome = fetchBalance(key: key)
            async let claudeOutcome = fetchClaudeUsage()
            async let zaiOutcome = fetchZaiUsage(key: zaiKey)

            let balanceResult = await balanceOutcome
            let claudeResult = await claudeOutcome
            let zaiResult = await zaiOutcome
            guard !Task.isCancelled else { return }

            applyBalance(balanceResult)
            applyClaude(claudeResult)
            applyZai(zaiResult)
            isLoading = false
        }
    }

    /// The balance fetch, or `nil` when there is no key to fetch with.
    private func fetchBalance(key: String) async -> Result<Int, Error>? {
        guard !key.isEmpty else { return nil }
        do {
            return .success(try await checker.fetchBalance(apiKey: key))
        } catch {
            return .failure(error)
        }
    }

    private func applyBalance(_ result: Result<Int, Error>?) {
        guard let result else { return }

        switch result {
        case .success(let newBalance):
            // Capture the previous balance before overwriting it: the low-balance
            // notification fires on the crossing, not on the value.
            let previousBalance = balance
            balance = newBalance
            errorMessage = nil
            let now = Date()
            lastUpdated = now
            recordMetric(newBalance, into: &history, at: now)

            // Low-balance notification: on threshold crossing (≥10 → <10)
            // OR on first successful fetch if already below threshold.
            if let previous = previousBalance, previous >= 10, newBalance < 10 {
                sendLowBalanceNotification(balance: newBalance)
            } else if previousBalance == nil && newBalance < 10 {
                sendLowBalanceNotification(balance: newBalance)
            }

        case .failure(let error):
            // Keep the stale balance value — don't wipe it on error.
            // Only set balance = nil if there was never a successful fetch
            // (it's already nil in that case, so nothing to do).
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Claude Usage

    /// What a Claude fetch produced. Missing credentials is deliberately not a failure:
    /// plenty of people don't use Claude Code, and an error telling them so would be
    /// noise rather than news.
    private enum ClaudeOutcome {
        case notConfigured
        case usage(ClaudeUsageReport)
        case failure(String)
    }

    private func fetchClaudeUsage() async -> ClaudeOutcome {
        do {
            return .usage(try await claudeChecker.fetchUsage())
        } catch ClaudeUsageError.noCredentials {
            return .notConfigured
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func applyClaude(_ outcome: ClaudeOutcome) {
        switch outcome {
        case .notConfigured:
            claudeUsage = nil
            claudePlan = nil
            claudeError = nil
            claudeHistory.removeAll()

        case .usage(let report):
            // Capture the previous 5-hour % for threshold-crossing notification.
            let previousPercent = claudeFiveHourPercent
            claudeUsage = report.usage
            claudePlan = report.subscriptionType
            claudeError = nil

            // Record history and fire high-usage notification based on the 5-hour %.
            if let percent = claudeFiveHourPercent {
                let now = Date()
                recordMetric(percent, into: &claudeHistory, at: now)

                // High-usage notification: on threshold crossing (<90 → ≥90)
                // OR on first successful fetch if already above threshold.
                if let previous = previousPercent, previous < Self.highUsageThreshold,
                   percent >= Self.highUsageThreshold {
                    sendHighUsageNotification(provider: "Claude Code", percent: percent)
                } else if previousPercent == nil, percent >= Self.highUsageThreshold {
                    sendHighUsageNotification(provider: "Claude Code", percent: percent)
                }
            }

        case .failure(let message):
            // As with the balance: keep the last good numbers on screen and say what
            // went wrong, rather than blanking the section on a transient failure.
            claudeError = message
        }
    }

    /// The 5-hour window percentage for the menu bar title, or `nil` when absent.
    var claudeFiveHourPercent: Int? {
        guard let fiveHour = claudeUsage?.fiveHour else { return nil }
        return Int(fiveHour.utilization.rounded())
    }

    /// The 7-day window percentage for the menu bar title, or `nil` when absent.
    /// Falls back to the 7-day Opus window when the regular 7-day is absent but Opus
    /// has been used — on Max plans the Opus cap is the one that binds first.
    var claudeSevenDayPercent: Int? {
        if let sevenDay = claudeUsage?.sevenDay {
            return Int(sevenDay.utilization.rounded())
        }
        if let opus = claudeUsage?.sevenDayOpus, opus.utilization > 0 {
            return Int(opus.utilization.rounded())
        }
        return nil
    }

    /// Display label for the Claude plan, e.g. "Pro" or "Max".
    var claudePlanLabel: String? {
        guard let plan = claudePlan?.trimmingCharacters(in: .whitespacesAndNewlines),
              !plan.isEmpty else { return nil }

        switch plan.lowercased() {
        case "free": return "Free"
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return plan.capitalized
        }
    }

    // MARK: - z.ai Usage

    /// What a z.ai fetch produced. Missing API key is deliberately not a failure:
    /// plenty of people don't use z.ai, and an error telling them so would be noise.
    private enum ZaiOutcome {
        case notConfigured
        case usage(ZaiUsageReport)
        case failure(String)
    }

    private func fetchZaiUsage(key: String) async -> ZaiOutcome {
        guard !key.isEmpty else { return .notConfigured }
        do {
            return .usage(try await zaiChecker.fetchUsage(apiKey: key))
        } catch ZaiUsageError.noAPIKey {
            return .notConfigured
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func applyZai(_ outcome: ZaiOutcome) {
        switch outcome {
        case .notConfigured:
            zaiUsage = nil
            zaiError = nil
            zaiHistory.removeAll()

        case .usage(let report):
            // Capture the previous 5-hour % for threshold-crossing notification.
            let previousPercent = zaiFiveHourPercent
            zaiUsage = report
            zaiError = nil

            // Record history and fire high-usage notification based on the 5-hour %.
            if let percent = zaiFiveHourPercent {
                let now = Date()
                recordMetric(percent, into: &zaiHistory, at: now)

                // High-usage notification: on threshold crossing (<90 → ≥90)
                // OR on first successful fetch if already above threshold.
                if let previous = previousPercent, previous < Self.highUsageThreshold,
                   percent >= Self.highUsageThreshold {
                    sendHighUsageNotification(provider: "z.ai Coding", percent: percent)
                } else if previousPercent == nil, percent >= Self.highUsageThreshold {
                    sendHighUsageNotification(provider: "z.ai Coding", percent: percent)
                }
            }

        case .failure(let message):
            // As with the balance and Claude: keep the last good numbers on screen
            // and say what went wrong, rather than blanking the section on a
            // transient failure.
            zaiError = message
        }
    }

    /// The 5-hour window percentage for the menu bar title, or `nil` when absent.
    var zaiFiveHourPercent: Int? {
        zaiUsage?.fiveHourPercent
    }

    /// The weekly window percentage for the popover, or `nil` when absent.
    var zaiWeeklyPercent: Int? {
        zaiUsage?.weeklyPercent
    }

    /// Display label for the z.ai plan, e.g. "Lite", "Pro", or "Max".
    /// Falls back to the raw `planLevel` string if it doesn't match a known tier.
    var zaiPlanLabel: String? {
        guard let level = zaiUsage?.planLevel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !level.isEmpty else { return nil }

        // The subscription endpoint returns a product name like "GLM Coding Max";
        // extract the tier from it. The quota endpoint returns just the tier.
        let lowered = level.lowercased()
        if lowered.contains("max") { return "Max" }
        if lowered.contains("pro") { return "Pro" }
        if lowered.contains("lite") { return "Lite" }
        return level.capitalized
    }

    // MARK: - Clipboard

    /// Copies the current balance to the clipboard as plain digits (no grouping
    /// separator), and shows a brief "✓ Copied" confirmation.
    func copyBalanceToClipboard() {
        guard let balance = balance else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(balance), forType: .string)

        copiedConfirmation = true
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            copiedConfirmation = false
        }
    }

    /// Copies the current Claude 5-hour percentage to the clipboard.
    func copyClaudePercentToClipboard() {
        guard let percent = claudeFiveHourPercent else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\(percent)%", forType: .string)

        copiedClaudeConfirmation = true
        copiedClaudeResetTask?.cancel()
        copiedClaudeResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            copiedClaudeConfirmation = false
        }
    }

    /// Copies the current z.ai 5-hour percentage to the clipboard.
    func copyZaiPercentToClipboard() {
        guard let percent = zaiFiveHourPercent else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\(percent)%", forType: .string)

        copiedZaiConfirmation = true
        copiedZaiResetTask?.cancel()
        copiedZaiResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            copiedZaiConfirmation = false
        }
    }

    // MARK: - Notifications

    private func sendLowBalanceNotification(balance: Int) {
        // Build the body here, on the main actor. `getNotificationSettings` calls back on
        // a background queue, and the shared `balanceFormatter` is main-actor state — the
        // status bar title formats against the very same instance.
        let body = "Low Hyper credits: \(Self.formatBalance(balance)) remaining"

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Low Usage Menubar"
            content.body = body
            content.sound = .default

            // A fixed identifier makes a later alert replace the delivered one in place,
            // which updates the text without ever notifying the user again.
            let request = UNNotificationRequest(
                identifier: "low-balance-alert-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    /// Sends a notification when a usage percentage crosses the high-usage threshold.
    private func sendHighUsageNotification(provider: String, percent: Int) {
        let body = "\(provider) 5-hour usage at \(percent)% — approaching limit"

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "High Usage Menubar"
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "high-usage-alert-\(provider)-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    // MARK: - API Key

    /// Saves the current `apiKeyInput` to the Keychain and triggers a refresh.
    /// Shows "✓ Saved" on success, or an error message if the keychain rejected the key.
    func saveAPIKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let deleted = KeychainHelper.delete()
            guard deleted else {
                errorMessage = "Could not delete API key from Keychain. It may be locked."
                return
            }
            apiKeyInput = ""
            activeAPIKey = ""
            hyperConfigured = false
            // refresh() with an empty key clears balance, error, history, and
            // cancels any in-flight task from the previous key.
            refresh()
        } else {
            let saved = KeychainHelper.save(key)
            guard saved else {
                errorMessage = "Could not save API key to Keychain. It may be locked."
                return
            }
            // A different key is a different account, so everything derived from the old
            // one has to go — not just the history behind the sparkline and trend. A
            // carried-over balance would be displayed as the new account's until the
            // fetch lands, and it would stand in as `previousBalance` for the low-balance
            // threshold check, which would then compare two unrelated accounts.
            if key != activeAPIKey {
                balance = nil
                lastUpdated = nil
                errorMessage = nil
                history.removeAll()
            }
            // Show the trimmed key that was actually stored.
            apiKeyInput = key
            activeAPIKey = key
            hyperConfigured = true
            refresh()
        }

        // Show "✓ Saved" confirmation, auto-reset after 2 seconds.
        // Cancel any previous reset so rapid Save clicks don't hide the
        // confirmation prematurely.
        savedConfirmation = true
        savedResetTask?.cancel()
        savedResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            savedConfirmation = false
        }
    }

    // MARK: - z.ai API Key

    /// Saves the current `zaiAPIKeyInput` to the Keychain and triggers a refresh.
    /// Shows "✓ Saved" on success, or an error message if the keychain rejected the key.
    func saveZaiAPIKey() {
        let key = zaiAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let deleted = ZaiKeychainHelper.delete()
            guard deleted else {
                zaiError = "Could not delete z.ai API key from Keychain. It may be locked."
                return
            }
            zaiAPIKeyInput = ""
            activeZaiAPIKey = ""
            // refresh() with an empty key clears zai usage and error, and
            // cancels any in-flight task from the previous key.
            refresh()
        } else {
            let saved = ZaiKeychainHelper.save(key)
            guard saved else {
                zaiError = "Could not save z.ai API key to Keychain. It may be locked."
                return
            }
            // A different key is a different account, so everything derived from the
            // old one has to go.
            if key != activeZaiAPIKey {
                zaiUsage = nil
                zaiError = nil
                zaiHistory.removeAll()
            }
            // Show the trimmed key that was actually stored.
            zaiAPIKeyInput = key
            activeZaiAPIKey = key
            refresh()
        }

        // Reuse the same "✓ Saved" confirmation — the user sees one per save action,
        // regardless of which key it was for.
        savedConfirmation = true
        savedResetTask?.cancel()
        savedResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            savedConfirmation = false
        }
    }

    // MARK: - Launch at Login

    func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Could not \(enabled ? "enable" : "disable") launch at login: "
                + error.localizedDescription
            // Snap the switch back to what the system actually did, suppressing the
            // didSet so this doesn't recurse into another register/unregister attempt.
            isInitializingLaunchAtLogin = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            isInitializingLaunchAtLogin = false
        }
    }
}