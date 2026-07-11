import SwiftUI

/// The SwiftUI view shown inside the popover when the menu bar item is clicked.
struct MenuView: View {
    @ObservedObject var viewModel: ViewModel

    /// Dims the balance while the pointer is over it, hinting that it is clickable.
    @State private var isHoveringBalance = false

    private static let websiteURL = URL(string: "https://hyper.charm.land")!

    // MARK: - Type Scale

    /// One rounded family, sized so that the balance is the only large element and
    /// everything else steps down from it — nothing competes with it for attention.
    /// The Claude percentage is the one exception, and it is deliberately set well
    /// below the balance so it reads as the second thing on the page, not the first.
    /// Monospaced digits keep numbers from jittering as their digits change.
    private static let heroFont = Font.system(size: 46, weight: .semibold, design: .rounded)
        .monospacedDigit()
    private static let subheroFont = Font.system(size: 26, weight: .semibold, design: .rounded)
        .monospacedDigit()
    private static let sectionFont = Font.system(size: 12, weight: .semibold, design: .rounded)
    private static let controlFont = Font.system(size: 12, weight: .regular, design: .rounded)
    private static let captionFont = Font.system(size: 11, weight: .medium, design: .rounded)
    private static let footnoteFont = Font.system(size: 10, weight: .regular, design: .rounded)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            hero
            if showsClaude {
                hairline
                claude
            }
            hairline
            settings
            hairline
            footer
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(width: 280)
        // Set as the environment font so the controls inherit the rounded design too.
        .font(Self.controlFont)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: viewModel.savedConfirmation)
        .animation(.easeInOut(duration: 0.2), value: viewModel.copiedConfirmation)
        .animation(.easeInOut(duration: 0.2), value: viewModel.errorMessage)
        .animation(.easeInOut(duration: 0.25), value: viewModel.balance)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isLoading)
        .animation(.easeInOut(duration: 0.3), value: historyValues.count)
        .animation(.easeInOut(duration: 0.25), value: viewModel.claudeUsage)
        .animation(.easeInOut(duration: 0.2), value: viewModel.claudeError)
    }

    /// A section rule light enough to read as a pause rather than a border.
    private var hairline: some View {
        Divider().opacity(0.3)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 8) {
            if viewModel.isLoading && viewModel.balance == nil {
                PulsingBolt()
                    .transition(.opacity)
            } else {
                VStack(spacing: 6) {
                    balanceNumber
                    caption
                    sparkline
                }
                .transition(.opacity)
            }

            if let lastUpdatedText = viewModel.lastUpdatedText {
                Text(lastUpdatedText)
                    .font(Self.footnoteFont)
                    .foregroundColor(.secondary)
                    .transition(.opacity)
            }

            if let error = viewModel.errorMessage {
                errorRow(error)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The balance itself. Clicking it copies the raw number to the clipboard.
    private var balanceNumber: some View {
        Button(action: { viewModel.copyBalanceToClipboard() }) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(viewModel.formattedBalance)
                    .font(Self.heroFont)
                    .foregroundColor(viewModel.balanceColor)
                    .contentTransition(.opacity)

                if let symbol = viewModel.balanceTrend.symbolName {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .transition(.opacity)
                }
            }
            // Without this the hover area is only the glyphs themselves.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.balance == nil)
        .help("Click to copy")
        .opacity(isHoveringBalance && viewModel.balance != nil ? 0.65 : 1)
        .onHover { isHoveringBalance = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHoveringBalance)
    }

    /// Doubles as the copy confirmation so the layout doesn't shift.
    private var caption: some View {
        Group {
            if viewModel.copiedConfirmation {
                Text("✓ Copied")
                    .foregroundColor(.green)
            } else {
                Text("credits")
                    .foregroundColor(.secondary)
            }
        }
        .font(Self.captionFont)
    }

    @ViewBuilder
    private var sparkline: some View {
        if historyValues.count >= 2 {
            Sparkline(values: historyValues, color: viewModel.balanceColor)
                .frame(height: 26)
                .padding(.top, 4)
                .transition(.opacity)
        }
    }

    /// The sparkline's data. Key paths can't index tuple elements, so this stays a closure.
    private var historyValues: [Int] {
        viewModel.balanceHistory.map { $0.balance }
    }

    /// Errors read as a quiet inline notice rather than loose red text: an icon, the
    /// message, and a tinted rounded background with no border.
    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))

            Text(message)
                .font(Self.captionFont)
                // Long messages wrap instead of being truncated to one line.
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .foregroundColor(.red)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.1))
        )
        .padding(.top, 2)
    }

    // MARK: - Claude

    /// Whether there is anything to say about Claude. Nothing at all when Claude Code
    /// isn't signed in on this machine — the section doesn't appear, and no error is
    /// shown for a service the user may simply not use.
    private var showsClaude: Bool {
        if viewModel.claudeError != nil { return true }
        if let usage = viewModel.claudeUsage { return !usage.isEmpty }
        return false
    }

    /// Claude Code's plan limits. The percentage leads, as the balance does above it,
    /// with the individual windows underneath as quiet supporting detail.
    private var claude: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Claude Code")
                    .font(Self.sectionFont)

                Spacer(minLength: 0)

                if let plan = viewModel.claudePlanLabel {
                    Text(plan)
                        .font(Self.captionFont)
                        .foregroundColor(.secondary)
                }
            }

            if let usage = viewModel.claudeUsage, !usage.isEmpty {
                usageDetail(usage)
            }

            if let error = viewModel.claudeError {
                errorRow(error)
            }
        }
    }

    private func usageDetail(_ usage: ClaudeUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let headline = Self.headline(for: usage) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(headline.percent)%")
                        .font(Self.subheroFont)
                        .foregroundColor(Self.usageColor(headline.percent))
                        .contentTransition(.opacity)

                    Spacer(minLength: 0)

                    if let resets = headline.resetsIn {
                        Text("resets in \(resets)")
                            .font(Self.footnoteFont)
                            .foregroundColor(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                if let fiveHour = usage.fiveHour {
                    window("5-hour", fiveHour)
                }
                if let sevenDay = usage.sevenDay {
                    window("7-day", sevenDay)
                }
                // Opus has its own weekly cap on Max plans, but it is only worth a row
                // once it has actually been used.
                if let opus = usage.sevenDayOpus, opus.utilization > 0 {
                    window("7-day Opus", opus)
                }
            }
        }
    }

    /// One window: its name, its share of the allowance, and a hairline bar. The bar is
    /// the only chrome here, and it carries the same color as the number beside it.
    private func window(_ label: String, _ window: UsageWindow) -> some View {
        let percent = Int(window.utilization.rounded())

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(label)
                    .font(Self.captionFont)
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)

                Text("\(percent)%")
                    .font(Self.captionFont.monospacedDigit())
                    .foregroundColor(Self.usageColor(percent))
            }

            UsageBar(percent: percent, color: Self.usageColor(percent))
        }
    }

    /// The number the section leads with: whichever limit the server flags as binding,
    /// falling back to the 5-hour window when it flags none.
    private static func headline(for usage: ClaudeUsage) -> (percent: Int, resetsIn: String?)? {
        if let active = usage.activeLimit {
            return (active.percent, active.resetsInFormatted)
        }
        if let fiveHour = usage.fiveHour {
            return (Int(fiveHour.utilization.rounded()), fiveHour.resetsInFormatted)
        }
        return nil
    }

    /// The balance colors read the other way round here, because for a limit more is
    /// worse: green with room to spare, yellow closing in, red nearly spent.
    private static func usageColor(_ percent: Int) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .yellow }
        return .green
    }

    // MARK: - Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("API Key")
                        .font(Self.sectionFont)

                    Spacer(minLength: 0)

                    // The confirmation takes the link's place rather than adding a row
                    // of its own, so saving never resizes the popover.
                    if viewModel.savedConfirmation {
                        Text("✓ Saved")
                            .font(Self.captionFont)
                            .foregroundColor(.green)
                            .transition(.opacity)
                    } else {
                        Link("Get key →", destination: Self.websiteURL)
                            .font(Self.captionFont)
                            .transition(.opacity)
                    }
                }

                HStack(spacing: 8) {
                    SecureField("sk-…", text: $viewModel.apiKeyInput)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        viewModel.saveAPIKey()
                    }
                }
                .controlSize(.small)
            }

            HStack {
                Text("Refresh every")

                Spacer(minLength: 0)

                Picker("Refresh every", selection: $viewModel.refreshIntervalMinutes) {
                    ForEach(RefreshInterval.options, id: \.self) { minutes in
                        Text("\(minutes)m").tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }

            Toggle("Launch at Login", isOn: $viewModel.launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 14) {
            HStack {
                Button(action: { viewModel.refresh() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)

                Spacer(minLength: 12)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .controlSize(.small)

            Link("hyper.charm.land", destination: Self.websiteURL)
                .font(Self.footnoteFont)
                .foregroundColor(.secondary)
                .opacity(0.7)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - Loading

/// The loading state, before there has ever been a balance to show. Reuses the ⚡ from
/// the menu bar title rather than a generic spinner, so the two read as the same app.
private struct PulsingBolt: View {
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 6) {
            Text("⚡")
                .font(.system(size: 34))
                .opacity(isPulsing ? 0.35 : 1)
                .scaleEffect(isPulsing ? 0.94 : 1)
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: isPulsing
                )
                // Roughly the height of the balance it stands in for, so the hero
                // doesn't jump when the first fetch lands.
                .frame(height: 56)

            Text("Loading…")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
        }
        .onAppear { isPulsing = true }
    }
}

// MARK: - Usage Bar

/// A hairline utilization bar: a track, a fill, and nothing else. Sized to read as a
/// rule under the label rather than as a control.
private struct UsageBar: View {
    /// 0–100. Clamped, because a plan with extra usage enabled can report past 100.
    let percent: Int
    let color: Color

    private let height: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(max(Double(percent) / 100, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))

                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Sparkline

/// A minimal line chart of recent balances: no axes, no labels, no grid. The stroke
/// takes the balance's color so the trend reads as part of the number above it, with a
/// faint fade underneath for weight and a dot marking the latest point.
///
/// Points are spaced evenly by index rather than by timestamp, which keeps the shape
/// readable when fetches are irregular (wake-ups, manual refreshes).
struct Sparkline: View {
    let values: [Int]
    var color: Color = .secondary

    /// Keeps the stroke and the dot from being clipped at the edges.
    private let verticalInset: CGFloat = 3
    private let dotRadius: CGFloat = 2.5

    var body: some View {
        GeometryReader { geometry in
            let points = points(in: geometry.size)

            if points.count >= 2 {
                ZStack {
                    fill(under: points, height: geometry.size.height)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.18), color.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    line(through: points)
                        .stroke(
                            color.opacity(0.9),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                        )

                    if let last = points.last {
                        Circle()
                            .fill(color)
                            .frame(width: dotRadius * 2, height: dotRadius * 2)
                            .position(last)
                    }
                }
            }
        }
    }

    /// Normalizes the values into the available space, oldest at the left.
    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }

        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let range = Double(maxValue - minValue)

        // The dot is centered on the last point, so the line stops a radius short of
        // the trailing edge rather than letting the dot spill outside the frame.
        let usableWidth = max(size.width - dotRadius, 1)
        let usableHeight = max(size.height - verticalInset * 2, 1)
        let stepX = usableWidth / CGFloat(values.count - 1)

        return values.enumerated().map { index, value in
            // A flat series has no range to normalize against; center it.
            let normalized = range == 0 ? 0.5 : Double(value - minValue) / range
            return CGPoint(
                x: CGFloat(index) * stepX,
                y: verticalInset + (1 - CGFloat(normalized)) * usableHeight
            )
        }
    }

    private func line(through points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    /// The line closed down to the baseline, so it can be filled.
    private func fill(under points: [CGPoint], height: CGFloat) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: first.x, y: height))
            path.addLine(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.addLine(to: CGPoint(x: last.x, y: height))
            path.closeSubpath()
        }
    }
}
