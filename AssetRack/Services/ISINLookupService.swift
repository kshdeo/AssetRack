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
        // ── Case 1: multi-result search page
        // Links look like: href="orderbuch.php?lang=en&amp;isin=DE0007664039">Volkswagen AG</a>
        // Note: it's "orderbuch.php" (German), parameters may appear in any order,
        // and the ISIN separator is "&amp;" in HTML.
        let linkPattern = #"href="/?orderbuch\.php\?[^"]*isin=([A-Z]{2}[A-Z0-9]{10})[^"]*">([^<]{3,})</a>"#
        if let regex = try? NSRegularExpression(pattern: linkPattern) {
            let nsHtml = html as NSString
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            var seen = Set<String>()
            var results: [StockSearchResult] = []
            for match in matches {
                guard match.numberOfRanges >= 3 else { continue }
                let isin = nsHtml.substring(with: match.range(at: 1))
                let name = nsHtml.substring(with: match.range(at: 2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !seen.contains(isin), !name.isEmpty else { continue }
                seen.insert(isin)
                results.append(StockSearchResult(
                    symbol: isin,
                    description: name,
                    displaySymbol: isin,   // ticker column not available in list view
                    type: "Tradegate",
                    resolvedISIN: isin
                ))
            }
            if !results.isEmpty { return results }
        }

        // ── Case 2: single-result redirect to order book page
        // Tradegate redirects directly to the order book when there's exactly one match.
        // Extract ISIN, name, and ticker code from the structured page data.
        return singleResultFromOrderBook(html)
    }

    private func singleResultFromOrderBook(_ html: String) -> [StockSearchResult] {
        // ISIN from JS variable: var isin = "US4581401001";
        let isinPattern = #"var isin = "([A-Z]{2}[A-Z0-9]{10})""#
        guard let isinRegex = try? NSRegularExpression(pattern: isinPattern),
              let isinMatch = isinRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              isinMatch.numberOfRanges >= 2 else { return [] }
        let isin = (html as NSString).substring(with: isinMatch.range(at: 1))

        // Name from the classless <h2> tag (the stock name has no class;
        // sidebar headings use class="wie_bild" or "kurslisten").
        let namePattern = #"<h2>([^<]+)</h2>"#
        let name: String
        if let nameRegex = try? NSRegularExpression(pattern: namePattern),
           let nameMatch = nameRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           nameMatch.numberOfRanges >= 2 {
            name = (html as NSString).substring(with: nameMatch.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            name = isin
        }

        // Ticker code from the WKN/Code/ISIN info table.
        // Structure: <td>WKN</td> <td>CODE</td> <td>ISIN</td>
        // The two copyToClipboard cells before the ISIN cell give us WKN then Code.
        let tickerPattern = #"ondblclick="copyToClipboard\(this\)">[A-Z0-9]+</td>\s*<td ondblclick="copyToClipboard\(this\)">([A-Z0-9]+)</td>"#
        let ticker: String
        if let tickerRegex = try? NSRegularExpression(pattern: tickerPattern),
           let tickerMatch = tickerRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           tickerMatch.numberOfRanges >= 2 {
            ticker = (html as NSString).substring(with: tickerMatch.range(at: 1))
        } else {
            ticker = isin
        }

        return [StockSearchResult(
            symbol: isin,
            description: name,
            displaySymbol: ticker,
            type: "Tradegate",
            resolvedISIN: isin
        )]
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
