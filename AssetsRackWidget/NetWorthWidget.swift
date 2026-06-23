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
    let ageLabel: String?

    static let placeholder = WidgetEntry(
        date: Date(),
        netWorth: 128_540,
        dailyChange: 1_230,
        currency: "USD",
        updatedAt: Date(),
        ageLabel: "just now"
    )
}

// MARK: - Timeline provider

private struct NetWorthProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(makeEntries(now: Date()).first!)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let now = Date()
        let entries = makeEntries(now: now)
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
    }

    // One entry per minute for 60 minutes, each with a pre-computed age label.
    // WidgetKit switches entries automatically — no live Date() calls in the view.
    private func makeEntries(now: Date) -> [WidgetEntry] {
        let d = UserDefaults(suiteName: appGroupID)
        let netWorth    = d?.double(forKey: "widget_net_worth")    ?? 0
        let dailyChange = d?.double(forKey: "widget_daily_change") ?? 0
        let currency    = d?.string(forKey: "widget_currency")     ?? "USD"
        let updatedAt   = d?.object(forKey: "widget_updated_at")   as? Date

        return (0...60).map { minute in
            let entryDate = now.addingTimeInterval(TimeInterval(minute * 60))
            let label: String? = updatedAt.map { ageLabel(at: entryDate, updatedAt: $0) }
            return WidgetEntry(date: entryDate, netWorth: netWorth, dailyChange: dailyChange,
                               currency: currency, updatedAt: updatedAt, ageLabel: label)
        }
    }

    private func ageLabel(at date: Date, updatedAt: Date) -> String {
        let minutes = Int(date.timeIntervalSince(updatedAt) / 60)
        switch minutes {
        case ..<1:   return "just now"
        case ..<60:  return "\(minutes) min ago"
        default:     return "\(minutes / 60) hr ago"
        }
    }
}

// MARK: - App icon badge

private struct AppIconBadge: View {
    var body: some View {
        Image("WidgetAppIcon")
            .resizable()
            .frame(width: 24, height: 24)
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
        HStack(spacing: 0) {
            Image(systemName: entry.dailyChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 10, weight: .bold))
            VStack(alignment: .leading, spacing: 0) {
                Text(" \(abs(entry.dailyChange).widgetFormatted(code: entry.currency))")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let pct = entry.dailyChangePercent {
                    Text("  \(pct)")
                        .font(.system(size: 10, weight: .medium))
                        .opacity(0.75)
                }
            }
            if let label = entry.ageLabel {
                Spacer(minLength: 8)
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .foregroundStyle(changeColor)
    }
}

// MARK: - Widget content view

private struct NetWorthWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: WidgetEntry

    private var isMedium: Bool { family == .systemMedium }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Net Worth")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                AppIconBadge()
            }
            .padding(.bottom, 2)

            Text(entry.netWorth.widgetFormatted(code: entry.currency))
                .font(isMedium ? .title.weight(.medium) : .title2.weight(.medium))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.45)
                .lineLimit(1)

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 0) {
                Text("TODAY")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.bottom, 4)
                    .tracking(0.5)

                ChangeRow(entry: entry)
            }
        }
        .padding(isMedium ? 4 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
        f.locale = Locale(identifier: "en_GB") // consistent thousands/decimal separators
        f.maximumFractionDigits = 0
        f.usesGroupingSeparator = true
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
    let entry: WidgetEntry
    var body: some View { NetWorthWidgetView(entry: entry) }
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
