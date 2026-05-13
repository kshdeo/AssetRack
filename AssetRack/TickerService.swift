import Foundation
import Observation
import SwiftData

@Observable
final class TickerService {
    private(set) var isLoading = false
    private(set) var lastFetched: Date?
    private(set) var errors: [String: String] = [:]  // symbol → error message

    private let fetchedAtKey = "ticker_last_fetched"

    init() {
        lastFetched = UserDefaults.standard.object(forKey: fetchedAtKey) as? Date
    }

    func fetchIfNeeded(context: ModelContext) async {
        guard shouldFetch else { return }
        await fetch(context: context)
    }

    func fetch(context: ModelContext) async {
        let allAccounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let tracked = allAccounts.filter { $0.isTickerTracked }
        guard !tracked.isEmpty else { return }

        isLoading = true
        errors = [:]

        let symbols = tracked.map { $0.tickerSymbol.uppercased() }
        let joined = symbols.joined(separator: ",")

        do {
            let prices = try await fetchPrices(symbols: joined)

            for account in tracked {
                let symbol = account.tickerSymbol.uppercased()
                if let price = prices[symbol] {
                    account.lastPrice = price
                    account.currentBalance = price * account.quantity
                    account.updatedAt = Date()

                    let snap = BalanceSnapshot(balance: account.currentBalance)
                    context.insert(snap)
                    account.balanceHistory.append(snap)
                } else {
                    errors[symbol] = "Price unavailable"
                }
            }

            lastFetched = Date()
            UserDefaults.standard.set(lastFetched, forKey: fetchedAtKey)
        } catch {
            for symbol in symbols {
                errors[symbol] = "Could not fetch price"
            }
        }

        isLoading = false
    }

    // MARK: - Private

    private var shouldFetch: Bool {
        guard let last = lastFetched else { return true }
        return Date().timeIntervalSince(last) > 3_600
    }

    private var crumb: String?

    private func fetchCrumb() async throws -> String {
        // Step 1: hit fc.yahoo.com to plant the required cookie
        let cookieURL = URL(string: "https://fc.yahoo.com")!
        var req = URLRequest(url: cookieURL)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        _ = try? await URLSession.shared.data(for: req)

        // Step 2: exchange the cookie for a crumb
        let crumbURL = URL(string: "https://query2.finance.yahoo.com/v1/test/getcrumb")!
        var crumbReq = URLRequest(url: crumbURL)
        crumbReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: crumbReq)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let crumb = String(data: data, encoding: .utf8), !crumb.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        return crumb
    }

    private func fetchPrices(symbols: String) async throws -> [String: Double] {
        if crumb == nil {
            crumb = try await fetchCrumb()
        }

        var components = URLComponents(string: "https://query1.finance.yahoo.com/v7/finance/quote")!
        components.queryItems = [
            URLQueryItem(name: "symbols", value: symbols),
            URLQueryItem(name: "crumb", value: crumb)
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        // Crumb expired — clear it and retry once
        if statusCode == 401 {
            crumb = try await fetchCrumb()
            components.queryItems = [
                URLQueryItem(name: "symbols", value: symbols),
                URLQueryItem(name: "crumb", value: crumb)
            ]
            var retryRequest = URLRequest(url: components.url!)
            retryRequest.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
            guard (retryResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return try parseQuotes(from: retryData)
        }

        guard statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parseQuotes(from: data)
    }

    private func parseQuotes(from data: Data) throws -> [String: Double] {
        let decoded = try JSONDecoder().decode(YahooQuoteResponse.self, from: data)
        var result: [String: Double] = [:]
        for quote in decoded.quoteResponse.result {
            result[quote.symbol] = quote.regularMarketPrice
        }
        return result
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
        let regularMarketPrice: Double
    }
}
