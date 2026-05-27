import SwiftUI

/// Small change indicator: directional arrow + percentage.
///
/// Used wherever a value's percent change needs to be conveyed — dashboard
/// period deltas (w/w · m/m · y/y), per-account daily change in account rows,
/// per-holding daily change in the holdings list.
///
/// Styling rule: the arrow carries the green/red signal; the text sits in
/// `.secondary` so the badge stays calm and doesn't compete with primary
/// numbers nearby. The compact (no-label) variant uses `caption2`; the
/// labelled variant bumps up to `footnote` for dashboard prominence.
///
/// - Parameters:
///   - percent: fractional change (0.01 = 1%). Sign drives the arrow direction.
///   - label: optional period suffix (e.g. "w/w"). When provided, the badge
///            renders one size up — appropriate for the dashboard trend strip.
///   - isGain: optional override for the colour rule. Defaults to `percent >= 0`.
///             Pass the flipped sign for liabilities so debt paydown reads green.
struct ChangeBadge: View {
    let percent: Double
    var label: String? = nil
    var isGain: Bool? = nil

    var body: some View {
        let positive = percent >= 0
        let gainFlag = isGain ?? positive
        let isLarge  = label != nil

        HStack(spacing: isLarge ? 4 : 3) {
            Image(systemName: positive ? "arrow.up" : "arrow.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(gainFlag ? Color.green : Color.red)
            Text(percentText(isLarge: isLarge))
                .font(isLarge ? .footnote : .caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func percentText(isLarge: Bool) -> String {
        let precision = isLarge ? 1 : 2
        let formatted = abs(percent).formatted(.percent.precision(.fractionLength(precision)))
        return label.map { "\(formatted) \($0)" } ?? formatted
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        Text("Dashboard trend strip").font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 16) {
            ChangeBadge(percent:  0.012, label: "w/w")
            ChangeBadge(percent:  0.034, label: "m/m")
            ChangeBadge(percent: -0.012, label: "y/y")
        }

        Divider()

        Text("Row badges (compact)").font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 16) {
            ChangeBadge(percent:  0.0050)
            ChangeBadge(percent: -0.0123)
            ChangeBadge(percent:  0.0020, isGain: false)   // mortgage going up
        }
    }
    .padding()
}
