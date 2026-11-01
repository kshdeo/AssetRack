import Foundation
import Observation
import SwiftData

/// Owns the "Try with sample data" session used for App Store review and first
/// looks. While active, the app root runs against a throwaway in-memory
/// container, so the user's real store is never opened by a view, and nothing
/// survives a relaunch or an exit.
@Observable
@MainActor
final class DemoMode {
    /// Read by services outside the view hierarchy (`WidgetDataStore`,
    /// `CurrencyService`, `TickerService`, `ISINLookupService`,
    /// `BackgroundRefreshService`) so each one has a single demo guard rather
    /// than threading a flag through every call site. Only written on the main
    /// actor, before the root view swaps containers.
    nonisolated(unsafe) private(set) static var sessionActive = false

    private(set) var container: ModelContainer?
    private(set) var startError: String?

    var isActive: Bool { container != nil }

    func enter() {
        guard container == nil else { return }
        // Set first: services created by the swapped-in root read it in init.
        Self.sessionActive = true
        do {
            container = try ModelContainer.makeDemoContainer()
            startError = nil
        } catch {
            Self.sessionActive = false
            startError = "Could not load sample data."
        }
    }

    func exit() {
        Self.sessionActive = false
        container = nil
    }
}

/// Offline stand-in for the price, search and FX services during a demo session.
/// All values are fixed sample figures, not market data.
enum DemoMarket {
    static let baseCurrency = "USD"

    struct Security {
        let symbol: String
        let name: String
        let type: String
        let isin: String
        let price: Double
        let previousClose: Double
        let currency: String
    }

    static let securities: [Security] = [
        .init(symbol: "VOO",  name: "Vanguard S&P 500 ETF",            type: "ETF",    isin: "US9229083632", price: 540.00, previousClose: 536.20, currency: "USD"),
        .init(symbol: "AAPL", name: "Apple Inc.",                      type: "Common Stock", isin: "US0378331005", price: 228.00, previousClose: 226.10, currency: "USD"),
        .init(symbol: "MSFT", name: "Microsoft Corporation",           type: "Common Stock", isin: "US5949181045", price: 430.00, previousClose: 433.40, currency: "USD"),
        .init(symbol: "VTI",  name: "Vanguard Total Stock Market ETF", type: "ETF",    isin: "US9229087690", price: 285.00, previousClose: 283.50, currency: "USD"),
        .init(symbol: "GOOGL", name: "Alphabet Inc.",                  type: "Common Stock", isin: "US02079K3059", price: 175.00, previousClose: 176.30, currency: "USD"),
        .init(symbol: "VWCE", name: "Vanguard FTSE All-World ETF",     type: "ETF",    isin: "IE00BK5BQT80", price: 118.00, previousClose: 117.20, currency: "EUR"),
    ]

    /// Units of each currency per 1 USD.
    private static let usdRates: [String: Double] = [
        "USD": 1, "EUR": 0.92, "GBP": 0.79, "CAD": 1.37, "AUD": 1.52,
        "CHF": 0.88, "JPY": 150, "CNY": 7.2, "INR": 84, "SGD": 1.34,
        "HKD": 7.8, "NZD": 1.66, "MXN": 18.5, "BRL": 5.5, "KRW": 1_350,
        "SEK": 10.6, "NOK": 10.9, "DKK": 6.9, "AED": 3.67, "ZAR": 18,
    ]

    /// Same shape as the live FX response: units of each other currency per 1 `base`.
    static func rates(base: String) -> [String: Double] {
        guard let baseRate = usdRates[base] else { return [:] }
        return usdRates
            .filter { $0.key != base }
            .mapValues { $0 / baseRate }
    }

    static func search(query: String) -> [StockSearchResult] {
        let needle = query.lowercased()
        return securities
            .filter { $0.symbol.lowercased().contains(needle) || $0.name.lowercased().contains(needle) }
            .map {
                StockSearchResult(
                    symbol: $0.symbol,
                    description: $0.name,
                    displaySymbol: $0.symbol,
                    type: $0.type,
                    resolvedISIN: $0.isin
                )
            }
    }

    /// Quote for a holding. Symbols outside the sample list get a stable made-up
    /// price so a reviewer can add any ticker and see the balance respond.
    static func quote(symbol: String, isin: String, source: PriceSource) -> (price: Double, previousClose: Double, currency: String) {
        if let known = securities.first(where: { $0.symbol == symbol || (!isin.isEmpty && $0.isin == isin) }) {
            return (known.price, known.previousClose, known.currency)
        }
        let seed = (symbol + isin).unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let price = Double(20 + seed % 480)
        return (price, price * 0.995, source == .tradegate ? "EUR" : "USD")
    }
}
