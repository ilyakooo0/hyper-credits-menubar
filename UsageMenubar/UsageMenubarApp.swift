import SwiftUI
import Combine
import UserNotifications

/// Main app delegate that manages the menu bar item, the refresh timer,
/// the SwiftUI popover hosting `MenuView`, and sleep/wake handling.
///
/// Marked `@MainActor` because `ViewModel` is `@MainActor`-isolated and the
/// delegate accesses it directly. All `NSApplicationDelegate` methods are
/// called on the main thread regardless, so this is semantically correct.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var refreshTimer: Timer?

    /// The shared view model. Shared between the menu bar and the popover.
    let viewModel = ViewModel()

    /// Combine cancellables for observing published changes.
    private var statusTextCancellable: AnyCancellable?

    /// The site the "Open" menu item points at.
    private static let websiteURL = URL(string: "https://hyper.charm.land")!

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only prompt if the user has never answered; re-asking after a denial
        // does nothing, and after an approval it's pointless.
        requestNotificationPermissionIfNeeded()

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = nil
            button.title = "⚡?"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Create popover with SwiftUI content
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuView(viewModel: viewModel))

        // Observe published changes (balance + isLoading + Claude usage + z.ai usage) to
        // update the menu bar title. CombineLatest fires when any of them changes.
        //
        // The title is built from the values the publisher hands us, not by reading the
        // view model back: `@Published` emits in `willSet`, so the property still holds
        // its old value while this closure runs.
        //
        // Delivery is hopped through `DispatchQueue.main` rather than `RunLoop.main`,
        // whose Combine scheduler only runs in the default run loop mode — the title
        // would freeze while a menu or a scroll was tracking.
        statusTextCancellable = Publishers.CombineLatest4(
            viewModel.$balance,
            viewModel.$isLoading,
            viewModel.$claudeUsage,
            viewModel.$zaiUsage
        )
        .map { balance, isLoading, claudeUsage, zaiUsage in
            let fiveHour = claudeUsage?.fiveHour
                .map { Int($0.utilization.rounded()) }
            let sevenDay = claudeUsage?.sevenDay
                .map { Int($0.utilization.rounded()) }
                ?? claudeUsage?.sevenDayOpus
                    .map { Int($0.utilization.rounded()) }
            let zaiFiveHour = zaiUsage?.fiveHourPercent
            return ViewModel.statusBarText(
                balance: balance,
                isLoading: isLoading,
                claudeFiveHourPercent: fiveHour,
                claudeSevenDayPercent: sevenDay,
                zaiFiveHourPercent: zaiFiveHour
            )
        }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] text in
            self?.statusItem.button?.title = text
        }

        // Register for sleep/wake notifications
        registerSleepWakeNotifications()

        // Restart the timer whenever the user picks a new interval in the popover.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshIntervalDidChange(_:)),
            name: .refreshIntervalDidChange,
            object: nil
        )

        // Initial fetch
        viewModel.refresh()

        // Start periodic refresh
        startRefreshTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        statusTextCancellable?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Refresh Timer

    /// (Re)starts the periodic refresh using the interval stored in the view model.
    private func startRefreshTimer() {
        refreshTimer?.invalidate()

        let minutes = max(1, viewModel.refreshIntervalMinutes)
        let interval = TimeInterval(minutes * 60)

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.viewModel.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    @objc private func refreshIntervalDidChange(_ notification: Notification) {
        startRefreshTimer()
    }

    // MARK: - Notification Permission

    private func requestNotificationPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                // Permission result is handled silently; notifications are optional.
            }
        }
    }

    // MARK: - Sleep / Wake

    private func registerSleepWakeNotifications() {
        let workspace = NSWorkspace.shared
        let notificationCenter = workspace.notificationCenter

        notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        // Nothing to do on sleep; timer will pause naturally.
    }

    @objc private func systemDidWake(_ notification: Notification) {
        // Refresh after wake to get a fresh balance.
        viewModel.refresh()
    }

    // MARK: - Status Item Click

    /// Left-click toggles the popover; right-click (or control-click) opens the context menu.
    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.type == .rightMouseDown
            || event?.modifierFlags.contains(.control) == true

        if isRightClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: - Context Menu

    private func showContextMenu() {
        if popover.isShown {
            popover.performClose(nil)
        }

        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshFromMenu(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "Open hyper.charm.land", action: #selector(openWebsite(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit UsageMenubar", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Attaching the menu makes the next click present it (with the correct
        // highlight + placement), then we detach so left-clicks keep firing our
        // action instead of reopening the menu.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshFromMenu(_ sender: Any?) {
        viewModel.refresh()
    }

    @objc private func openWebsite(_ sender: Any?) {
        NSWorkspace.shared.open(Self.websiteURL)
    }

    @objc private func quit(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Popover

    /// Shows the popover if it isn't already visible.
    ///
    /// We don't toggle: the popover has `.transient` behavior, which closes it
    /// automatically when the user clicks outside it — including on the status
    /// item. By the time our `.leftMouseUp` action fires, a previously-shown
    /// popover has already closed, so `isShown` is `false` and a toggle would
    /// reopen it instead of dismissing it. Always showing means the first click
    /// opens and `.transient` handles the rest.
    private func togglePopover() {
        guard let button = statusItem.button else { return }
        guard !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - App Entry Point

@main
struct UsageMenubarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
