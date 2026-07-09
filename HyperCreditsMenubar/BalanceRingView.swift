import SwiftUI

/// A very thin, very subtle circular progress ring that visualises the credit
/// balance relative to a reference maximum. Not currently used in the main
/// popover — the balance number is the hero, not a ring — but kept as a
/// clean, minimal implementation that could be layered behind the number
/// if a visual indicator is desired.
///
/// The track is nearly invisible (0.08 opacity) and the arc is a flat color
/// (no gradient, no shadow) to stay understated.
struct BalanceRingView: View {
    let balance: Int?
    let color: Color
    /// The balance value that maps to a full ring.
    var referenceMax: Int = 500

    /// Progress in the range 0...1.
    private var progress: Double {
        guard let balance, balance > 0 else { return 0 }
        return min(Double(balance) / Double(referenceMax), 1.0)
    }

    var body: some View {
        ZStack {
            // Track — barely visible
            Circle()
                .stroke(color.opacity(0.08), lineWidth: 3)

            // Progress arc — flat color, no gradient, no shadow
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90)) // start from top
        }
        .animation(.easeInOut(duration: 0.4), value: progress)
    }
}
