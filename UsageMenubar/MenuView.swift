import SwiftUI

/// The SwiftUI view shown inside the popover when the menu bar item is clicked.
struct MenuView: View {
    @ObservedObject var viewModel: ViewModel

    private static let websiteURL = URL(string: "https://hyper.charm.land")!
    private static let zaiKeyURL = URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")!

    // MARK: - Type Scale

    /// One rounded family, sized so that every provider's headline number reads at the
    /// same weight. With three providers in the popover, the 26pt subhero is the right
    /// scale — a 46pt hero would make the popover too tall. Monospaced digits keep
    /// numbers from jittering as their digits change.
    private static let subheroFont = Font.system(size: 26, weight: .semibold, design: .rounded)
        .monospacedDigit()
    private static let sectionFont = Font.system(size: 12, weight: .semibold, design: .rounded)
    private static let controlFont = Font.system(size: 12, weight: .regular, design: .rounded)
    private static let captionFont = Font.system(size: 11, weight: .medium, design: .rounded)
    private static let footnoteFont = Font.system(size: 10, weight: .regular, design: .rounded)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if viewModel.hyperConfigured {
                hyper
            }
            if showsClaude {
                serviceBreak
                claude
            }
            if showsZai {
                serviceBreak
                zai
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
        .animation(.easeInOut(duration: 0.2), value: viewModel.copiedClaudeConfirmation)
        .animation(.easeInOut(duration: 0.2), value: viewModel.copiedZaiConfirmation)
        .animation(.easeInOut(duration: 0.2), value: viewModel.errorMessage)
        .animation(.easeInOut(duration: 0.25), value: viewModel.balance)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isLoading)
        .animation(.easeInOut(duration: 0.3), value: viewModel.balanceSparklineValues.count)
        .animation(.easeInOut(duration: 0.3), value: viewModel.claudeSparklineValues.count)
        .animation(.easeInOut(duration: 0.3), value: viewModel.zaiSparklineValues.count)
        .animation(.easeInOut(duration: 0.25), value: viewModel.claudeUsage)
        .animation(.easeInOut(duration: 0.2), value: viewModel.claudeError)
        .animation(.easeInOut(duration: 0.25), value: viewModel.zaiUsage)
        .animation(.easeInOut(duration: 0.2), value: viewModel.zaiError)
    }

    /// A section rule light enough to read as a pause rather than a border.
    private var hairline: some View {
        Divider().opacity(0.3)
    }

    /// The rule between services. Wider than the others on purpose: the providers are
    /// unrelated accounts, and the gap should say so before the headers do.
    private var serviceBreak: some View {
        hairline.padding(.vertical, 5)
    }

    /// A section header: an icon and a title, sized to match the "API Key" header below
    /// so the popover reads as three equal sections rather than a hero with appendages.
    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))

            Text(title)
                .font(Self.sectionFont)
        }
    }

    /// A reusable headline number row: the provider's main metric at subhero scale,
    /// with emoji, color, trend arrow, and click-to-copy. The `caption` doubles as the
    /// copy-confirmation slot so the layout doesn't shift.
    private func headlineNumber(
        text: String,
        color: Color,
        trend: MetricTrend,
        copiedConfirmation: Bool,
        captionText: String,
        copyAction: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 6) {
            Button(action: copyAction) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(text)
                        .font(Self.subheroFont)
                        .foregroundColor(color)
                        .contentTransition(.opacity)

                    if let symbol = trend.symbolName {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to copy")

            // Caption doubles as copy confirmation so the layout doesn't shift.
            Group {
                if copiedConfirmation {
                    Text("✓ Copied")
                        .foregroundColor(.green)
                } else {
                    Text(captionText)
                        .foregroundColor(.secondary)
                }
            }
            .font(Self.captionFont)
        }
    }

    /// A sparkline shown when there are at least 2 history points.
    @ViewBuilder
    private func sparkline(values: [Int], color: Color) -> some View {
        if values.count >= 2 {
            Sparkline(values: values, color: color)
                .frame(height: 26)
                .padding(.top, 4)
                .transition(.opacity)
        }
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

    // MARK: - Hyper

    /// Whether there is anything to say about Hyper. Nothing at all when Hyper isn't
    /// configured — the section doesn't appear, same as Claude and z.ai.
    private var showsHyper: Bool {
        viewModel.hyperConfigured
    }

    /// The Hyper section: header, balance as a subhero number, caption, sparkline.
    private var hyper: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Hyper Credits", systemImage: "bolt.fill")

            if viewModel.isLoading && viewModel.balance == nil {
                Text("…")
                    .font(Self.subheroFont)
                    .foregroundColor(.secondary)
            } else if let balance = viewModel.balance {
                VStack(spacing: 8) {
                    headlineNumber(
                        text: "⚡ \(viewModel.formattedBalance)",
                        color: viewModel.balanceColor,
                        trend: viewModel.balanceTrend,
                        copiedConfirmation: viewModel.copiedConfirmation,
                        captionText: "credits",
                        copyAction: { viewModel.copyBalanceToClipboard() }
                    )

                    sparkline(
                        values: viewModel.balanceSparklineValues,
                        color: viewModel.balanceColor
                    )
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

    /// Claude Code's plan limits. Same visual structure as Hyper and z.ai: a subhero
    /// headline number, bars under every window, a sparkline, and error row.
    private var claude: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                sectionHeader("Claude Code", systemImage: "sparkles")

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
            // The 5-hour window leads as the headline number.
            if let fiveHour = usage.fiveHour {
                let percent = Int(fiveHour.utilization.rounded())
                VStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        headlineNumber(
                            text: "⁕ \\(percent)%",
                            color: Self.usageColor(percent),
                            trend: viewModel.claudeTrend,
                            copiedConfirmation: viewModel.copiedClaudeConfirmation,
                            captionText: "5-hour usage",
                            copyAction: { viewModel.copyClaudePercentToClipboard() }
                        )

                        Spacer(minLength: 0)

                        if let resets = fiveHour.resetsInFormatted {
                            Text("resets in \(resets)")
                                .font(Self.footnoteFont)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Bar under the 5-hour window too, same as 7-day windows below.
                    UsageBar(percent: percent, color: Self.usageColor(percent))
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                if let sevenDay = usage.sevenDay {
                    window("7-day", sevenDay)
                }
                // Opus has its own weekly cap on Max plans, but it is only worth a row
                // once it has actually been used.
                if let opus = usage.sevenDayOpus, opus.utilization > 0 {
                    window("7-day Opus", opus)
                }
            }

            // Sparkline for the Claude 5-hour % history.
            sparkline(
                values: viewModel.claudeSparklineValues,
                color: Self.usageColor(claudeFiveHourPercent ?? 0)
            )
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

    /// The current Claude 5-hour percentage, or 0 if absent. Used for sparkline color.
    private var claudeFiveHourPercent: Int? {
        viewModel.claudeFiveHourPercent
    }

    /// The balance colors read the other way round here, because for a limit more is
    /// worse: green with room to spare, yellow closing in, red nearly spent.
    private static func usageColor(_ percent: Int) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .yellow }
        return .green
    }

    // MARK: - z.ai

    /// Whether there is anything to say about z.ai. Nothing at all when no API key has
    /// been entered — the section doesn't appear, and no error is shown for a service
    /// the user may simply not use.
    private var showsZai: Bool {
        if viewModel.zaiError != nil { return true }
        if let usage = viewModel.zaiUsage { return !usage.isEmpty }
        return false
    }

    /// z.ai Coding Plan's quota limits. Same visual structure as Hyper and Claude:
    /// a subhero headline number, bars under every window, a sparkline, and error row.
    private var zai: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                sectionHeader("z.ai Coding", systemImage: "bolt.horizontal")

                Spacer(minLength: 0)

                if let plan = viewModel.zaiPlanLabel {
                    Text(plan)
                        .font(Self.captionFont)
                        .foregroundColor(.secondary)
                }
            }

            if let usage = viewModel.zaiUsage, !usage.isEmpty {
                zaiUsageDetail(usage)
            }

            if let error = viewModel.zaiError {
                errorRow(error)
            }
        }
    }

    private func zaiUsageDetail(_ usage: ZaiUsageReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The 5-hour window leads as the headline number.
            if let fiveHour = usage.fiveHourPercent {
                VStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        headlineNumber(
                            text: "Z \\(fiveHour)%",
                            color: Self.usageColor(fiveHour),
                            trend: viewModel.zaiTrend,
                            copiedConfirmation: viewModel.copiedZaiConfirmation,
                            captionText: "5-hour usage",
                            copyAction: { viewModel.copyZaiPercentToClipboard() }
                        )

                        Spacer(minLength: 0)

                        if let resets = usage.fiveHourResetsAt {
                            Text("resets in \(Self.zaiResetsIn(from: resets))")
                                .font(Self.footnoteFont)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Bar under the 5-hour window too.
                    UsageBar(percent: fiveHour, color: Self.usageColor(fiveHour))
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                if let weekly = usage.weeklyPercent {
                    zaiWindow("Weekly", percent: weekly, resetsAt: usage.weeklyResetsAt)
                }
            }

            // Peak hours notice.
            zaiPeakHours

            // Sparkline for the z.ai 5-hour % history, with an orange tint
            // when currently in peak hours.
            if viewModel.zaiSparklineValues.count >= 2 {
                Sparkline(
                    values: viewModel.zaiSparklineValues,
                    color: Self.usageColor(zaiFiveHourPercent ?? 0)
                )
                .frame(height: 26)
                .padding(.top, 4)
                .transition(.opacity)
                .background(
                    ViewModel.zaiInPeakHours
                        ? RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.orange.opacity(0.08))
                        : nil
                )
            }
        }
    }

    /// The current z.ai 5-hour percentage, or 0 if absent. Used for sparkline color.
    private var zaiFiveHourPercent: Int? {
        viewModel.zaiFiveHourPercent
    }

    /// One window row for z.ai: label, percentage, and a hairline bar.
    private func zaiWindow(_ label: String, percent: Int, resetsAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
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

    /// z.ai peak hours: 14:00–18:00 CST (UTC+8), i.e. 06:00–10:00 UTC.
    /// Limits are most likely to bind during this window. Displayed in the
    /// user's local timezone so they know when to expect slowdowns.
    private var zaiPeakHours: some View {
        let inPeak = ViewModel.zaiInPeakHours

        return HStack(spacing: 6) {
            Circle()
                .fill(inPeak ? Color.orange : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)

            Text(inPeak ? "Peak hours now" : "Peak \(Self.zaiPeakHoursLocal)")
                .font(Self.footnoteFont)
                .foregroundColor(inPeak ? .orange : .secondary)
        }
    }

    /// z.ai peak hours converted to the user's local timezone, e.g. "09:00–13:00".
    private static var zaiPeakHoursLocal: String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm"

        var utc = DateComponents()
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.hour = 6
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: utc)!

        utc.hour = 10
        let end = calendar.date(from: utc)!

        return "\(formatter.string(from: start))–\(formatter.string(from: end))"
    }

    /// Formats the time until a z.ai window resets, e.g. "3h 20m".
    private static func zaiResetsIn(from date: Date) -> String {
        let interval = date.timeIntervalSince(Date())
        guard interval > 0 else { return "soon" }

        let seconds = Int(interval.rounded())
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    // MARK: - Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    sectionHeader("Hyper API Key", systemImage: "bolt.fill")

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

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    sectionHeader("z.ai API Key", systemImage: "bolt.horizontal")

                    Spacer(minLength: 0)

                    // The confirmation takes the link's place rather than adding a row
                    // of its own, so saving never resizes the popover.
                    if viewModel.savedConfirmation {
                        Text("✓ Saved")
                            .font(Self.captionFont)
                            .foregroundColor(.green)
                            .transition(.opacity)
                    } else {
                        Link("Get key →", destination: Self.zaiKeyURL)
                            .font(Self.captionFont)
                            .transition(.opacity)
                    }
                }

                HStack(spacing: 8) {
                    SecureField("your z.ai key", text: $viewModel.zaiAPIKeyInput)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        viewModel.saveZaiAPIKey()
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
        }
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

/// A minimal line chart of recent values: no axes, no labels, no grid. The stroke
/// takes the metric's color so the trend reads as part of the number above it, with a
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