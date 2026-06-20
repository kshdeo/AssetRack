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

// MARK: - App icon badge

private struct AppIconBadge: View {
    var body: some View {
        Image("WidgetAppIcon")
            .resizable()
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Change row

private struct ChangeRow: View {
    let entry: WidgetEntry

    private var changeColor: Color {
        entry.dailyChange >= 0
            ? Color(red: 0.2, green: 0.85, blue: 0.45)
            : Color(red: 1.0, green: 0.35, blue: 0.35)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.dailyChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 10, weight: .bold))
            Text(abs(entry.dailyChange).widgetFormatted(code: entry.currency))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let pct = entry.dailyChangePercent {
                Text(pct)
                    .font(.caption.weight(.medium))
                    .opacity(0.85)
            }
            if let label = entry.updatedLabel {
                Spacer(minLength: 0)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .foregroundStyle(changeColor)
    }
}

// MARK: - Views

private struct SmallWidgetView: View {
    let entry: WidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text("Net Worth")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                AppIconBadge()
            }

            Spacer(minLength: 6)

            Text(entry.netWorth.widgetFormatted(code: entry.currency))
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.45)
                .lineLimit(1)

            Spacer(minLength: 10)

            Text("TODAY'S CHANGE")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(0.5)

            Spacer(minLength: 4)

            ChangeRow(entry: entry)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct MediumWidgetView: View {
    let entry: WidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text("Net Worth")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                AppIconBadge()
            }

            Spacer(minLength: 8)

            Text(entry.netWorth.widgetFormatted(code: entry.currency))
                .font(.title.weight(.bold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            Spacer(minLength: 12)

            Text("TODAY'S CHANGE")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(0.5)

            Spacer(minLength: 4)

            ChangeRow(entry: entry)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Helpers

private extension WidgetEntry {
    var updatedLabel: String? {
        guard let updated = updatedAt else { return nil }
        let minutes = Int(Date().timeIntervalSince(updated) / 60)
        switch minutes {
        case 0:       return "just now"
        case 1..<60:  return "\(minutes)m ago"
        default:      return "\(minutes / 60)h ago"
        }
    }

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
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [Color(red: 0.09, green: 0.12, blue: 0.22),
                                 Color(red: 0.06, green: 0.08, blue: 0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
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
