import Foundation
import Observation

/// Handles all currency conversion and money arithmetic in the app.
/// Every addition or subtraction of amounts in different currencies must go through this service.
@Observable
final class CurrencyService {
    private(set) var rates: [String: Double] = [:]
    private(set) var lastFetched: Date?
    private(set) var isLoading = false
    private(set) var error: String?

    var baseCurrency: String {
        didSet {
            guard baseCurrency != oldValue else { return }
            UserDefaults.standard.set(baseCurrency, forKey: baseCurrencyKey)
            rates = [:]
            lastFetched = nil
            Task { @MainActor in await fetch() }
        }
    }

    private let baseCurrencyKey = "fx_base_currency"
    private let cacheKey = "fx_rates"
    private let fetchedAtKey = "fx_rates_fetched_at"

    init() {
        baseCurrency = UserDefaults.standard.string(forKey: "fx_base_currency") ?? "USD"
        loadCache()
    }

    // MARK: - Fetching

    func fetchIfNeeded() async {
        guard shouldFetch else { return }
        await fetch()
    }

    func fetch() async {
        debugPrint("[CurrencyService] Fetching rates (base: \(baseCurrency))")
        isLoading = true
        error = nil

        do {
            let url = URL(string: "https://api.frankfurter.app/latest?from=\(baseCurrency)")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(FrankfurterResponse.self, from: data)
            rates = decoded.rates
            lastFetched = Date()
            saveCache()
        } catch {
            self.error = "Could not update exchange rates."
        }

        isLoading = false
    }

    // MARK: - Arithmetic

    /// Convert an amount from one currency to another.
    func convert(_ amount: Double, from: String, to: String) -> Double {
        guard from != to else { return amount }
        let inBase = toBase(amount, currency: from)
        guard to != baseCurrency else { return inBase }
        guard let toRate = rates[to], toRate > 0 else { return inBase }
        return inBase * toRate
    }

    /// Convert a Money value to the target currency.
    func convert(_ money: Money, to currency: String) -> Money {
        Money(convert(money.amount, from: money.currency, to: currency), currency)
    }

    /// Sum an array of Money values, converting each to the target currency, and return a Money result.
    func sum(_ amounts: [Money], in target: String) -> Money {
        Money(amounts.reduce(0) { $0 + convert($1.amount, from: $1.currency, to: target) }, target)
    }

    /// Convert an amount to the user's reporting base currency.
    func toBase(_ amount: Double, currency: String) -> Double {
        guard currency != baseCurrency else { return amount }
        guard let rate = rates[currency], rate > 0 else { return amount }
        return amount / rate
    }

    // MARK: - Formatting

    /// Format a `Money` value in its own currency.
    func formatted(_ money: Money) -> String {
        money.amount.currencyFormatted(code: money.currency)
    }

    /// Format an amount in the user's base (reporting) currency.
    func formattedBase(_ amount: Double) -> String {
        amount.currencyFormatted(code: baseCurrency)
    }

    // MARK: - Private

    private var shouldFetch: Bool {
        guard let last = lastFetched else { return true }
        return Date().timeIntervalSince(last) > 86_400
    }

    private func loadCache() {
        if let saved = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: Double] {
            rates = saved
        }
        lastFetched = UserDefaults.standard.object(forKey: fetchedAtKey) as? Date
    }

    private func saveCache() {
        UserDefaults.standard.set(rates, forKey: cacheKey)
        UserDefaults.standard.set(lastFetched, forKey: fetchedAtKey)
    }
}

private struct FrankfurterResponse: Decodable {
    let base: String
    let date: String
    let rates: [String: Double]
}
