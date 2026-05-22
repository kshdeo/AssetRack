import Foundation
import Observation
import SwiftData

@Observable
final class TickerService {
    private(set) var isLoading = false
    private(set) var lastFetched: Date?
    private(set) var errors: [String: String] = [:]

    private let fetchedAtKey = "ticker_last_fetched"
    private var crumb: String?

    init() {
        lastFetched = UserDefaults.standard.object(forKey: fetchedAtKey) as? Date
    }

    func fetchIfNeeded(context: ModelContext, currency: CurrencyService) async {
        guard shouldFetch else {
            print("[TickerService] Skipping fetch — last fetched \(lastFetched?.formatted() ?? "never"), threshold not reached")
            return
        }
        await fetch(context: context, currency: currency)
    }

    func fetch(context: ModelContext, currency: CurrencyService) async {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let allHoldings = accounts.flatMap { $0.holdings }
        guard !allHoldings.isEmpty else {
            print("[TickerService] No holdings found — skipping fetch")
            return
        }

        guard !isLoading else {
            print("[TickerService] Already loading — skipping concurrent fetch")
            return
        }
        isLoading = true
        errors = [:]
        defer { isLoading = false }

        let symbols = Array(Set(allHoldings.map { $0.tickerSymbol }))
        let joined = symbols.joined(separator: ",")
        print("[TickerService] Fetching prices for: \(joined)")

        do {
            let prices = try await fetchPrices(symbols: joined)
            print("[TickerService] Got \(prices.count) prices: \(prices.mapValues { "\($0.price) \($0.currency)" })")

            let fetchedAt = Date()
            for account in accounts where account.type.supportsHoldings {
                for holding in account.holdings {
                    if let result = prices[holding.tickerSymbol] {
                        print("[TickerService] \(holding.tickerSymbol): \(result.price) \(result.currency)")
                        holding.lastPrice = result.price
                        holding.priceCurrency = result.currency
                        holding.lastPriceFetchedAt = fetchedAt
                    } else {
                        print("[TickerService] \(holding.tickerSymbol): no price in response")
                        errors[holding.tickerSymbol] = "Price unavailable"
                    }
                }
                let oldBalance = account.currentBalance
                account.recomputeBalance(convert: currency.convert)

                if abs(account.currentBalance - oldBalance) > 0.01 {
                    let snap = BalanceSnapshot(balance: account.currentBalance)
                    // SwiftData auto-inserts snap via the @Relationship cascade;
                    // calling context.insert() explicitly would cause duplicate registration.
                    account.balanceHistory.append(snap)
                    account.updatedAt = Date()
                }
            }

            lastFetched = Date()
            UserDefaults.standard.set(lastFetched, forKey: fetchedAtKey)
            try? context.save()
            print("[TickerService] Fetch complete, context saved")
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Task was cancelled (e.g. refreshable gesture released) — not a real failure
            print("[TickerService] Fetch cancelled")
        } catch {
            print("[TickerService] Fetch failed: \(error)")
            for symbol in symbols {
                errors[symbol] = "Could not fetch price"
            }
        }
    }

    // MARK: - Private

    private var shouldFetch: Bool {
        guard let last = lastFetched else { return true }
        return Date().timeIntervalSince(last) > 3_600
    }

    private func fetchCrumb() async throws -> String {
        print("[TickerService] Fetching crumb...")
        let cookieURL = URL(string: "https://fc.yahoo.com")!
        var req = URLRequest(url: cookieURL)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (_, cookieResponse) = (try? await URLSession.shared.data(for: req)) ?? (Data(), nil)
        print("[TickerService] Cookie response status: \((cookieResponse as? HTTPURLResponse)?.statusCode ?? -1)")

        let crumbURL = URL(string: "https://query2.finance.yahoo.com/v1/test/getcrumb")!
        var crumbReq = URLRequest(url: crumbURL)
        crumbReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: crumbReq)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let crumbString = String(data: data, encoding: .utf8) ?? ""
        print("[TickerService] Crumb response status: \(status), crumb: '\(crumbString)'")

        guard status == 200, !crumbString.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        return crumbString
    }

    private func fetchPrices(symbols: String) async throws -> [String: (price: Double, currency: String)] {
        if crumb == nil { crumb = try await fetchCrumb() }
        print("[TickerService] Using crumb: '\(crumb ?? "nil")'")

        var components = URLComponents(string: "https://query1.finance.yahoo.com/v7/finance/quote")!
        components.queryItems = [
            URLQueryItem(name: "symbols", value: symbols),
            URLQueryItem(name: "crumb", value: crumb)
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("[TickerService] Quote response status: \(statusCode)")

        if statusCode == 401 {
            print("[TickerService] 401 — refreshing crumb and retrying")
            crumb = try await fetchCrumb()
            components.queryItems = [
                URLQueryItem(name: "symbols", value: symbols),
                URLQueryItem(name: "crumb", value: crumb)
            ]
            var retry = URLRequest(url: components.url!)
            retry.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retry)
            let retryStatus = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
            print("[TickerService] Retry status: \(retryStatus)")
            guard retryStatus == 200 else { throw URLError(.badServerResponse) }
            return try parseQuotes(from: retryData)
        }

        guard statusCode == 200 else {
            if let body = String(data: data, encoding: .utf8) {
                print("[TickerService] Non-200 response body: \(body)")
            }
            throw URLError(.badServerResponse)
        }

        return try parseQuotes(from: data)
    }

    private func parseQuotes(from data: Data) throws -> [String: (price: Double, currency: String)] {
        do {
            let decoded = try JSONDecoder().decode(YahooQuoteResponse.self, from: data)
            var result: [String: (price: Double, currency: String)] = [:]
            for quote in decoded.quoteResponse.result {
                if let price = quote.normalisedPrice {
                    result[quote.symbol] = (price, quote.normalisedCurrency)
                } else {
                    print("[TickerService] \(quote.symbol): no price field in response, skipping")
                }
            }
            return result
        } catch {
            print("[TickerService] JSON decode error: \(error)")
            print("[TickerService] Raw response: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "nil")")
            throw error
        }
    }
}

// MARK: - Response models

private struct YahooQuoteResponse: Decodable {
    let quoteResponse: QuoteResponse

    struct QuoteResponse: Decodable {
        let result: [Quote]
    }

    struct Quote: Decodable {
        let symbol: String
        let regularMarketPrice: Double?
        let regularMarketPreviousClose: Double?
        let currency: String?

        /// Normalised price: GBp/GBX (pence) divided by 100 to get GBP
        var normalisedPrice: Double? {
            guard let raw = regularMarketPrice ?? regularMarketPreviousClose else { return nil }
            return isPence ? raw / 100.0 : raw
        }

        /// Normalised currency code: GBp/GBX → GBP
        var normalisedCurrency: String {
            guard let c = currency else { return "USD" }
            return isPence ? "GBP" : c
        }

        private var isPence: Bool {
            currency == "GBp" || currency == "GBX"
        }
    }
}
