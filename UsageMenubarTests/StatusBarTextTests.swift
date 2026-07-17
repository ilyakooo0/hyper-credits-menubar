import XCTest
@testable import UsageMenubar

/// The menu bar title and the Claude numbers it is built from.
///
/// Balances are kept under 1,000 so the assertions don't depend on the grouping
/// separator of whatever locale the test happens to run in.
@MainActor
final class StatusBarTextTests: XCTestCase {

    // MARK: - Title

    func testBothServices() {
        let title = ViewModel.statusBarText(
            balance: 42, isLoading: false,
            hyperConfigured: true,
            claudeFiveHourPercent: 62, claudeSevenDayPercent: 8,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "⚡42 · 🕐62% · 📅8%")
    }

    func testHyperOnly() {
        let title = ViewModel.statusBarText(
            balance: 42, isLoading: false,
            hyperConfigured: true,
            claudeFiveHourPercent: nil, claudeSevenDayPercent: nil,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "⚡42")
    }

    func testClaudeOnly() {
        let title = ViewModel.statusBarText(
            balance: nil, isLoading: false,
            hyperConfigured: false,
            claudeFiveHourPercent: 62, claudeSevenDayPercent: 8,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "🕐62% · 📅8%")
    }

    func testLoadingWithNothingToShow() {
        let title = ViewModel.statusBarText(
            balance: nil, isLoading: true,
            hyperConfigured: false,
            claudeFiveHourPercent: nil, claudeSevenDayPercent: nil,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "…")
    }

    func testNothingToShow() {
        let title = ViewModel.statusBarText(
            balance: nil, isLoading: false,
            hyperConfigured: false,
            claudeFiveHourPercent: nil, claudeSevenDayPercent: nil,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "")
    }

    /// The placeholders only stand in for an *empty* title. Someone who runs Claude Code
    /// without a Hyper key refreshes every few minutes, and a title that fell back to `…`
    /// each time would blink their percentage away and back.
    func testLoadingKeepsAClaudePercentOnScreen() {
        let title = ViewModel.statusBarText(
            balance: nil, isLoading: true,
            hyperConfigured: false,
            claudeFiveHourPercent: 62, claudeSevenDayPercent: nil,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "🕐62%")
    }

    func testLoadingKeepsAStaleBalanceOnScreen() {
        let title = ViewModel.statusBarText(
            balance: 42, isLoading: true,
            hyperConfigured: true,
            claudeFiveHourPercent: 62, claudeSevenDayPercent: 8,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "⚡42 · 🕐62% · 📅8%")
    }

    func testZeroPercentIsShownRatherThanOmitted() {
        let title = ViewModel.statusBarText(
            balance: 42, isLoading: false,
            hyperConfigured: true,
            claudeFiveHourPercent: 0, claudeSevenDayPercent: 8,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "⚡42 · 📅8%")
    }

    func testBothClaudeWindowsZero() {
        let title = ViewModel.statusBarText(
            balance: 42, isLoading: false,
            hyperConfigured: true,
            claudeFiveHourPercent: 0, claudeSevenDayPercent: 0,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "⚡42")
    }

    func testFiveHourOnly() {
        let title = ViewModel.statusBarText(
            balance: nil, isLoading: false,
            hyperConfigured: false,
            claudeFiveHourPercent: 62, claudeSevenDayPercent: nil,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "🕐62%")
    }

    func testSevenDayOnly() {
        let title = ViewModel.statusBarText(
            balance: nil, isLoading: false,
            hyperConfigured: false,
            claudeFiveHourPercent: nil, claudeSevenDayPercent: 8,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "📅8%")
    }

    // MARK: - Hyper not configured

    func testHyperNotConfiguredHidesBoltEvenWithBalance() {
        // balance is non-nil but Hyper is not configured — should not appear.
        // This can happen briefly during the transition when a key is deleted.
        let title = ViewModel.statusBarText(
            balance: 42, isLoading: false,
            hyperConfigured: false,
            claudeFiveHourPercent: nil, claudeSevenDayPercent: nil,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "")
    }

    func testHyperNotConfiguredLoadingShowsJustDots() {
        let title = ViewModel.statusBarText(
            balance: nil, isLoading: true,
            hyperConfigured: false,
            claudeFiveHourPercent: nil, claudeSevenDayPercent: nil,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "…")
    }

    func testHyperNotConfiguredButClaudeStillShows() {
        let title = ViewModel.statusBarText(
            balance: nil, isLoading: false,
            hyperConfigured: false,
            claudeFiveHourPercent: 62, claudeSevenDayPercent: 8,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "🕐62% · 📅8%")
    }

    // MARK: - z.ai in Title

    func testZaiOnly() {
        let title = ViewModel.statusBarText(
            balance: nil, isLoading: false,
            hyperConfigured: false,
            claudeFiveHourPercent: nil, claudeSevenDayPercent: nil,
            zaiFiveHourPercent: 12, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "🤖12%")
    }

    func testZaiWithHyper() {
        let title = ViewModel.statusBarText(
            balance: 42, isLoading: false,
            hyperConfigured: true,
            claudeFiveHourPercent: nil, claudeSevenDayPercent: nil,
            zaiFiveHourPercent: 12, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "⚡42 · 🤖12%")
    }

    func testZaiWithClaude() {
        let title = ViewModel.statusBarText(
            balance: nil, isLoading: false,
            hyperConfigured: false,
            claudeFiveHourPercent: 62, claudeSevenDayPercent: 8,
            zaiFiveHourPercent: 12, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "🕐62% · 📅8% · 🤖12%")
    }

    func testAllThreeServices() {
        let title = ViewModel.statusBarText(
            balance: 42, isLoading: false,
            hyperConfigured: true,
            claudeFiveHourPercent: 62, claudeSevenDayPercent: 8,
            zaiFiveHourPercent: 12, zaiWeeklyPercent: 3
        )
        XCTAssertEqual(title, "⚡42 · 🕐62% · 📅8% · 🤖12% · 📆3%")
    }

    func testZaiZeroIsOmitted() {
        let title = ViewModel.statusBarText(
            balance: 42, isLoading: false,
            hyperConfigured: true,
            claudeFiveHourPercent: nil, claudeSevenDayPercent: nil,
            zaiFiveHourPercent: 0, zaiWeeklyPercent: 0
        )
        XCTAssertEqual(title, "⚡42")
    }

    func testLoadingKeepsZaiPercentOnScreen() {
        let title = ViewModel.statusBarText(
            balance: nil, isLoading: true,
            hyperConfigured: false,
            claudeFiveHourPercent: nil, claudeSevenDayPercent: nil,
            zaiFiveHourPercent: 12, zaiWeeklyPercent: nil
        )
        XCTAssertEqual(title, "🤖12%")
    }

    // MARK: - z.ai Weekly

    func testZaiWeeklyOnly() {
        let title = ViewModel.statusBarText(
            balance: nil, isLoading: false,
            hyperConfigured: false,
            claudeFiveHourPercent: nil, claudeSevenDayPercent: nil,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: 3
        )
        XCTAssertEqual(title, "📆3%")
    }

    func testZaiWeeklyWithFiveHour() {
        let title = ViewModel.statusBarText(
            balance: nil, isLoading: false,
            hyperConfigured: false,
            claudeFiveHourPercent: nil, claudeSevenDayPercent: nil,
            zaiFiveHourPercent: 12, zaiWeeklyPercent: 3
        )
        XCTAssertEqual(title, "🤖12% · 📆3%")
    }

    func testZaiWeeklyZeroIsOmitted() {
        let title = ViewModel.statusBarText(
            balance: nil, isLoading: false,
            hyperConfigured: false,
            claudeFiveHourPercent: nil, claudeSevenDayPercent: nil,
            zaiFiveHourPercent: 12, zaiWeeklyPercent: 0
        )
        XCTAssertEqual(title, "🤖12%")
    }

    func testLoadingKeepsZaiWeeklyOnScreen() {
        let title = ViewModel.statusBarText(
            balance: nil, isLoading: true,
            hyperConfigured: false,
            claudeFiveHourPercent: nil, claudeSevenDayPercent: nil,
            zaiFiveHourPercent: nil, zaiWeeklyPercent: 3
        )
        XCTAssertEqual(title, "📆3%")
    }

    // MARK: - Claude Window Percentages

    func testFiveHourPercentRounds() {
        let usage = ClaudeUsage(
            fiveHour: UsageWindow(utilization: 61.6),
            sevenDay: nil, sevenDayOpus: nil, limits: nil
        )
        let vm = ViewModel()
        vm.claudeUsage = usage
        XCTAssertEqual(vm.claudeFiveHourPercent, 62)
        XCTAssertNil(vm.claudeSevenDayPercent)
    }

    func testSevenDayPercentRounds() {
        let usage = ClaudeUsage(
            fiveHour: nil,
            sevenDay: UsageWindow(utilization: 4.4),
            sevenDayOpus: nil, limits: nil
        )
        let vm = ViewModel()
        vm.claudeUsage = usage
        XCTAssertNil(vm.claudeFiveHourPercent)
        XCTAssertEqual(vm.claudeSevenDayPercent, 4)
    }

    func testSevenDayFallsBackToOpus() {
        let usage = ClaudeUsage(
            fiveHour: nil,
            sevenDay: nil,
            sevenDayOpus: UsageWindow(utilization: 33.5),
            limits: nil
        )
        let vm = ViewModel()
        vm.claudeUsage = usage
        XCTAssertEqual(vm.claudeSevenDayPercent, 34)
    }

    func testSevenDayDoesNotFallBackToZeroOpus() {
        let usage = ClaudeUsage(
            fiveHour: nil,
            sevenDay: nil,
            sevenDayOpus: UsageWindow(utilization: 0),
            limits: nil
        )
        let vm = ViewModel()
        vm.claudeUsage = usage
        XCTAssertNil(vm.claudeSevenDayPercent)
    }

    func testNilUsageYieldsNilPercents() {
        let vm = ViewModel()
        XCTAssertNil(vm.claudeFiveHourPercent)
        XCTAssertNil(vm.claudeSevenDayPercent)
    }
}