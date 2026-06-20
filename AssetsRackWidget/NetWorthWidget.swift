import WidgetKit
import SwiftUI

// MARK: - Shared data

private let appGroupID = "group.blackforestapps.assetsRack"

private struct WidgetEntry: TimelineEntry {
    let date: Date
    let netWorth: Double
    let dailyChange: Double
    let currency: String
    let updatedAt: Date?

    static let placeholder = WidgetEntry(
        date: Date(),
        netWorth: 128_540,
        dailyChange: 1_230,
        currency: "USD",
        updatedAt: Date()
    )
}

// MARK: - Timeline provider

private struct NetWorthProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let current = entry()
        let nextRefresh = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [current], policy: .after(nextRefresh)))
    }

    private func entry() -> WidgetEntry {
        let d = UserDefaults(suiteName: appGroupID)
        return WidgetEntry(
            date: Date(),
            netWorth:    d?.double(forKey: "widget_net_worth")    ?? 0,
            dailyChange: d?.double(forKey: "widget_daily_change") ?? 0,
            currency:    d?.string(forKey: "widget_currency")     ?? "USD",
            updatedAt:   d?.object(forKey: "widget_updated_at") as? Date
        )
    }
}

// MARK: - Background gradient

// Concrete return type (LinearGradient) satisfies both View (.background)
// and ShapeStyle (.containerBackground) without type-erasing to some View.
private func widgetGradient() -> LinearGradient {
    LinearGradient(
        colors: [Color(red: 0.09, green: 0.12, blue: 0.22),
                 Color(red: 0.06, green: 0.08, blue: 0.16)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Views

private struct SmallWidgetView: View {
    let entry: WidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Net Worth")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))

            Text(entry.netWorth.widgetFormatted(code: entry.currency))
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Image(systemName: entry.dailyChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2.weight(.semibold))
                Text(abs(entry.dailyChange).widgetFormatted(code: entry.currency))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(entry.dailyChange >= 0 ? Color.green : Color.red)

            if let pct = entry.dailyChangePercent {
                Text(pct)
                    .font(.caption2)
                    .foregroundStyle(entry.dailyChange >= 0 ? Color.green.opacity(0.8) : Color.red.opacity(0.8))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(widgetGradient())
    }
}

private struct MediumWidgetView: View {
    let entry: WidgetEntry

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Net Worth")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))

                Text(entry.netWorth.widgetFormatted(code: entry.currency))
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                if let updated = entry.updatedAt {
                    Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: entry.dailyChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.bold))
                    Text(entry.dailyChange >= 0 ? "+" : "")
                    + Text(abs(entry.dailyChange).widgetFormatted(code: entry.currency))
                }
                .font(.subheadline.weight(.semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(entry.dailyChange >= 0 ? Color.green : Color.red)

                if let pct = entry.dailyChangePercent {
                    Text(pct)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(entry.dailyChange >= 0 ? Color.green.opacity(0.8) : Color.red.opacity(0.8))
                }

                Text("Today")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(widgetGradient())
    }
}

// MARK: - Helpers

private extension WidgetEntry {
    var dailyChangePercent: String? {
        let base = netWorth - dailyChange
        guard abs(base) > 0.01 else { return nil }
        let pct = (dailyChange / abs(base)) * 100
        return "\(pct >= 0 ? "+" : "")\(String(format: "%.2f", pct))%"
    }
}

private extension Double {
    func widgetFormatted(code: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: self)) ?? "\(code) \(Int(self))"
    }
}

// MARK: - Widget definition

struct NetWorthWidget: Widget {
    let kind = "NetWorthWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NetWorthProvider()) { entry in
            NetWorthWidgetEntryView(entry: entry)
                .containerBackground(widgetGradient(), for: .widget)
        }
        .configurationDisplayName("Net Worth")
        .description("Your current net worth and today's change.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct NetWorthWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: WidgetEntry

    var body: some View {
        switch family {
        case .systemMedium:
            MediumWidgetView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Widget bundle entry point

@main
struct AssetRackWidgetBundle: WidgetBundle {
    var body: some Widget {
        NetWorthWidget()
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    NetWorthWidget()
} timeline: {
    WidgetEntry.placeholder
}

#Preview("Medium", as: .systemMedium) {
    NetWorthWidget()
} timeline: {
    WidgetEntry.placeholder
}
