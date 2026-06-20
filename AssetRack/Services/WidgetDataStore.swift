import Foundation
import WidgetKit

/// Writes net worth data to the shared App Group UserDefaults so the
/// home-screen widget can read it without accessing the SwiftData store.
/// Call `update` after any balance or price change — it also signals
/// WidgetKit to reload the widget timeline.
struct WidgetDataStore {
    static let appGroupID = "group.com.blackforestapps.assetsRack"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func update(netWorth: Double, dailyChange: Double, currency: String) {
        guard let d = defaults else { return }
        d.set(netWorth,     forKey: "widget_net_worth")
        d.set(dailyChange,  forKey: "widget_daily_change")
        d.set(currency,     forKey: "widget_currency")
        d.set(Date(),       forKey: "widget_updated_at")
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func read() -> Entry {
        let d = defaults
        return Entry(
            netWorth:    d?.double(forKey: "widget_net_worth")  ?? 0,
            dailyChange: d?.double(forKey: "widget_daily_change") ?? 0,
            currency:    d?.string(forKey: "widget_currency")   ?? "USD",
            updatedAt:   d?.object(forKey: "widget_updated_at") as? Date
        )
    }

    struct Entry {
        let netWorth: Double
        let dailyChange: Double
        let currency: String
        let updatedAt: Date?

        var hasData: Bool { updatedAt != nil }
    }
}
