import SwiftUI
import Combine
import AppKit

/// Main app delegate that manages the menu bar item, the refresh timer,
/// and the SwiftUI popover hosting `MenuView`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var refreshTimer: Timer?

    /// The shared view model. Shared between the menu bar and the popover.
    let viewModel = ViewModel()

    /// Combine cancellables for observing balance / loading / colour changes.
    private var statusTextCancellable: AnyCancellable?
    private var statusColorCancellable: AnyCancellable?
    private var loadingCancellable: AnyCancellable?
    /// Drives the subtle "pulse" of the menu bar icon while loading.
    private var pulseTimer: Timer?
    private var pulseStep: Int = 0

    private let refreshInterval: TimeInterval = 5 * 60 // 5 minutes

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = statusBarIcon(color: .secondary, opacity: 1.0)
            button.image?.isTemplate = false
            button.title = "?"
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Create popover with SwiftUI content
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuView(viewModel: viewModel))

        // Observe balance changes to update the menu bar title.
        // Shows "⚡…" while loading (no balance yet), otherwise the number.
        statusTextCancellable = viewModel.$isLoading
            .combineLatest(viewModel.$balance)
            .map { [weak viewModel] isLoading, balance in
                if isLoading && balance == nil { return "…" }
                return viewModel?.statusBarItemText ?? "⚡?"
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                // statusBarItemText is "⚡NN"; we split off the leading ⚡ and
                // keep only the number/`?` as the title, rendering the bolt as
                // a tinted SF Symbol image.
                let stripped = text.hasPrefix("⚡") ? String(text.dropFirst()) : text
                self?.statusItem.button?.title = stripped
            }

        // Observe balance to tint the status bar icon by balance colour.
        statusColorCancellable = viewModel.$balance
            .map { [weak viewModel] _ in viewModel?.balanceColor ?? .secondary }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] color in
                guard let self else { return }
                self.statusItem.button?.image = self.statusBarIcon(color: color, opacity: 1.0)
                self.statusItem.button?.image?.isTemplate = false
            }

        // Observe loading state to start/stop the icon pulse.
        loadingCancellable = viewModel.$isLoading
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isLoading in
                if isLoading {
                    self?.startPulse()
                } else {
                    self?.stopPulse()
                }
            }

        // Initial fetch
        viewModel.refresh()

        // Start periodic refresh
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.viewModel.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        statusTextCancellable?.cancel()
        statusColorCancellable?.cancel()
        loadingCancellable?.cancel()
        stopPulse()
    }

    // MARK: - Status bar icon

    /// Renders `bolt.fill` as an NSImage tinted with the balance colour.
    /// The number is kept as the button `title`; this image is the icon only.
    private func statusBarIcon(color: Color, opacity: Double) -> NSImage? {
        guard let baseImage = NSImage(
            systemSymbolName: "bolt.fill",
            accessibilityDescription: "Hyper credits"
        ) else { return nil }

        // Lock a consistent point-size so the tint rasterisation is crisp.
        let targetSize = NSSize(width: 16, height: 16)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let symbol = baseImage.withSymbolConfiguration(config) ?? baseImage

        // Tint by filling with colour and compositing the symbol with sourceIn.
        let tinted = NSImage(size: targetSize, flipped: false) { [nsColor = NSColor(color).withAlphaComponent(opacity)] rect in
            nsColor.setFill()
            rect.fill()
            symbol.draw(in: rect, from: .zero, operation: .sourceIn, fraction: 1.0)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    // MARK: - Loading pulse

    /// Subtle pulse: 0.3s interval, opacity oscillates gently between 0.6–1.0.
    private func startPulse() {
        pulseStep = 0
        pulseTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pulseStep += 1
            let wave = sin(Double(self.pulseStep) * 0.5)
            // 0.6 – 1.0 opacity range (subtle, not flashy)
            let opacity = 0.8 + 0.2 * wave
            self.statusItem.button?.image = self.statusBarIcon(
                color: self.viewModel.balanceColor,
                opacity: opacity
            )
            self.statusItem.button?.image?.isTemplate = false
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        statusItem.button?.image = statusBarIcon(color: viewModel.balanceColor, opacity: 1.0)
        statusItem.button?.image?.isTemplate = false
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func closePopover() {
        popover.performClose(nil)
    }
}

// MARK: - App Entry Point

@main
struct HyperCreditsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
