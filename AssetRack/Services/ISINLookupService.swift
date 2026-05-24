import Foundation

// MARK: - Result type

struct StockSearchResult: Identifiable {
    let id = UUID()
    /// Exchange-level symbol (e.g. "VOW3.DE") or ISIN for Tradegate results
    let symbol: String
    /// Human-readable company name
    let description: String
    /// Clean display ticker shown in the list row (e.g. "VOW3")
    let displaySymbol: String
    /// Security type (e.g. "Common Stock", "Tradegate")
    let type: String
    /// ISIN pre-resolved from the search response (Tradegate results only).
    /// Non-nil means the ISIN field can be filled immediately without a second network call.
    let resolvedISIN: String?
}

// MARK: - Service

struct ISINLookupService {

    static let apiKeyDefaultsKey = "finnhub_api_key"
    private static let fallbackApiKey = "d89j4e9r01qspkc76kq0d89j4e9r01qspkc76kqg"

    /// Returns the user-configured key if set, otherwise the built-in fallback.
    static func effectiveApiKey(userKey: String) -> String {
        userKey.isEmpty ? fallbackApiKey : userKey
    }

    // MARK: - Tradegate search (returns ISIN directly in results)

    /// Search Tradegate Exchange by name or ticker.
    /// ISINs are parsed directly from the search results page — no second call needed.
    func searchTradegate(query: String) async throws -> [StockSearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        let url = URL(string: "https://www.tradegatebsx.com/kurssuche.php?lang=en&suche=\(encoded)")!
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        // Try UTF-8 first, fall back to ISO-8859-1 for German characters
        let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
        return parseTradegatResults(from: html)
    }

    private func parseTradegatResults(from html: String) -> [StockSearchResult] {
        // Tradegate search result rows contain a link of the form:
        //   href="/order_book.php?isin=DE0007664039&lang=en">Volkswagen AG</a>
        // The ISIN is in the href; the company name is the link text.
        let pattern = #"href="/order_book\.php\?isin=([A-Z]{2}[A-Z0-9]{10})[^"]*">([^<]+)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsHtml = html as NSString
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        var seen = Set<String>()
        var results: [StockSearchResult] = []

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let isin = nsHtml.substring(with: match.range(at: 1))
            let name = nsHtml.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !isin.isEmpty, !name.isEmpty, !seen.contains(isin) else { continue }
            seen.insert(isin)

            results.append(StockSearchResult(
                symbol: isin,
                description: name,
                displaySymbol: isin,
                type: "Tradegate",
                resolvedISIN: isin
            ))
        }
        return results
    }

    // MARK: - Finnhub search (for Yahoo Finance symbol discovery)

    /// Search for securities by name or ticker via Finnhub.
    func search(query: String, apiKey: String) async throws -> [StockSearchResult] {
        guard !apiKey.isEmpty else { throw LookupError.noAPIKey }
        var components = URLComponents(string: "https://finnhub.io/api/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q",     value: query),
            URLQueryItem(name: "token", value: apiKey)
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(FinnhubSearchResponse.self, from: data)
        return decoded.result.map {
            StockSearchResult(
                symbol: $0.symbol,
                description: $0.description,
                displaySymbol: $0.displaySymbol,
                type: $0.type,
                resolvedISIN: nil
            )
        }
    }

    // MARK: - Errors

    enum LookupError: LocalizedError {
        case noAPIKey
        var errorDescription: String? {
            "No Finnhub API key configured. Add one in Settings."
        }
    }
}

// MARK: - Private response models

private struct FinnhubSearchResponse: Decodable {
    let result: [Symbol]

    struct Symbol: Decodable {
        let symbol: String
        let description: String
        let displaySymbol: String
        let type: String
    }
}
