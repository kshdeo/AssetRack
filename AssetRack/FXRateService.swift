import Foundation
import Observation

@Observable
final class FXRateService {
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
            Task { await fetch() }
        }
    }

    private let baseCurrencyKey = "fx_base_currency"
    private let cacheKey = "fx_rates"
    private let fetchedAtKey = "fx_rates_fetched_at"

    init() {
        baseCurrency = UserDefaults.standard.string(forKey: "fx_base_currency") ?? "USD"
        loadCache()
    }

    func fetchIfNeeded() async {
        guard shouldFetch else { return }
        await fetch()
    }

    func fetch() async {
        debugPrint("Fetch fx rates (base: \(baseCurrency))")
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

    func toBase(_ amount: Double, currency: String) -> Double {
        guard currency != baseCurrency else { return amount }
        guard let rate = rates[currency], rate > 0 else { return amount }
        return amount / rate
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
