import Foundation
import SwiftUI
import Combine
import ServiceManagement

/// The view model that drives the menu bar display and the popover content.
final class ViewModel: ObservableObject {
    /// The last known balance. `nil` when loading, error, or no API key.
    @Published var balance: Int?

    /// `true` while a network request is in flight.
    @Published var isLoading = false

    /// A human-readable error message, shown when the balance can't be fetched.
    @Published var errorMessage: String?

    /// The API key entered by the user (loaded from Keychain on init).
    @Published var apiKeyInput: String = ""

    /// Whether launch-at-login is enabled.
    @Published var launchAtLogin: Bool {
        didSet {
            updateLaunchAtLogin(launchAtLogin)
        }
    }

    /// Timestamp of the last successful balance fetch, for relative "x ago" display.
    @Published var lastUpdated: Date?

    /// Whether an API key is currently stored in the Keychain.
    @Published var hasAPIKey: Bool

    private let checker = CreditsChecker()

    init() {
        let storedKey = KeychainHelper.load()
        apiKeyInput = storedKey ?? ""
        hasAPIKey = (storedKey ?? "").isEmpty == false
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Balance

    /// `true` when there is no stored API key and no balance yet (onboarding state).
    var needsOnboarding: Bool {
        !hasAPIKey && balance == nil && errorMessage == nil
    }

    /// The text to show in the menu bar: `⚡{balance}` or `⚡?`.
    var statusBarItemText: String {
        if let balance = balance {
            return "⚡\(balance)"
        }
        return "⚡?"
    }

    /// The color for the balance display based on thresholds.
    var balanceColor: Color {
        guard let balance = balance else { return .secondary }
        if balance >= 100 { return .green }
        if balance >= 10 { return .yellow }
        return .red
    }

    /// A human-readable relative time for the last update, e.g. "2m ago".
    var relativeUpdateText: String? {
        guard let lastUpdated else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastUpdated, relativeTo: Date())
    }

    /// Refreshes the balance from the API. No-op if no API key is set.
    func refresh() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            balance = nil
            errorMessage = nil
            lastUpdated = nil
            return
        }

        Task { @MainActor in
            isLoading = true
            errorMessage = nil
            do {
                let result = try await checker.fetchBalance(apiKey: key)
                balance = result
                lastUpdated = Date()
            } catch {
                balance = nil
                errorMessage = error.localizedDescription
                lastUpdated = nil
            }
            isLoading = false
        }
    }

    // MARK: - API Key

    /// Saves the current `apiKeyInput` to the Keychain and triggers a refresh.
    func saveAPIKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            KeychainHelper.delete()
            hasAPIKey = false
            balance = nil
            errorMessage = nil
            lastUpdated = nil
        } else {
            KeychainHelper.save(key)
            hasAPIKey = true
            refresh()
        }
    }

    // MARK: - Launch at Login

    func updateLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - MenuView

/// The SwiftUI view shown inside the popover when the menu bar item is clicked.
///
/// Minimal, airy design: one big balance number as the hero, generous spacing,
/// restrained color (balance color is the only accent), no cards or material
/// backgrounds. Inspired by Apple's Battery widget and trading apps.
struct MenuView: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        VStack(spacing: 0) {
            heroSection
            statusRow
            refreshButton

            spacer

            apiKeySection

            spacer

            footerRow
            versionText
        }
        .padding(20)
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: viewModel.balance)
        .animation(.easeInOut(duration: 0.2), value: viewModel.errorMessage)
        .animation(.easeInOut(duration: 0.2), value: viewModel.hasAPIKey)
    }

    /// A light vertical spacer between sections — spacing, not borders.
    private var spacer: some View {
        Spacer().frame(height: 16)
    }

    // MARK: - Hero

    /// The balance number is the hero — big, bold, beautiful. Everything else
    /// is secondary.
    private var heroSection: some View {
        VStack(spacing: 6) {
            Group {
                if viewModel.isLoading && viewModel.balance == nil {
                    ProgressView()
                        .controlSize(.small)
                } else if let balance = viewModel.balance {
                    Text("\(balance)")
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(viewModel.balanceColor)
                        .contentTransition(.opacity)
                } else if viewModel.needsOnboarding {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 40, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            .frame(height: 56)

            Text("credits")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(1.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: - Status

    /// Subtle "Updated 2m ago" or "Not connected" — plain text, no icons.
    private var statusRow: some View {
        Group {
            if let relative = viewModel.relativeUpdateText {
                Text("Updated \(relative)")
            } else {
                Text("Not connected")
            }
        }
        .font(.system(size: 11, weight: .regular, design: .rounded))
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    }

    // MARK: - Refresh

    /// Minimal text button — no icon rotation, just a text change.
    private var refreshButton: some View {
        Button(action: { viewModel.refresh() }) {
            Text(viewModel.isLoading ? "Refreshing…" : "Refresh")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoading)
        .padding(.top, 6)
    }

    // MARK: - API Key

    /// Clean SecureField + Save button. No DisclosureGroup, no lock icons.
    private var apiKeySection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SecureField("Hyper API Key", text: $viewModel.apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit { viewModel.saveAPIKey() }

                Button(action: { viewModel.saveAPIKey() }) {
                    Text("Save")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if viewModel.hasAPIKey {
                Text("✓ Saved")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.green)
            } else if let url = URL(string: "https://hyper.charm.land") {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("Get your key at hyper.charm.land")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Footer

    /// Launch at Login toggle on the left, Quit on the right. Very subtle.
    private var footerRow: some View {
        HStack {
            Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12, weight: .regular, design: .rounded))

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
    }

    // MARK: - Version

    /// Tiny version label at the very bottom.
    private var versionText: some View {
        Text("v\(appVersion)")
            .font(.system(size: 10, weight: .regular, design: .rounded))
            .foregroundStyle(.tertiary)
            .padding(.top, 10)
    }

    /// Reads the marketing version from the main bundle.
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
