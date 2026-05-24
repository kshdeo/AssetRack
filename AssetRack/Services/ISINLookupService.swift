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

    /// Strip HTML tags and decode common HTML entities from a raw HTML snippet.
    private func stripHTMLTags(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return stripped
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseTradegatResults(from html: String) -> [StockSearchResult] {
        // ── Case 1: multi-result search page
        // Links look like:
        //   href="orderbuch.php?lang=en&isin=IE00BFMXXD54"><b>Vanguard</b> S&amp;P 500 UCITS ETF</a>
        // The name may contain inline HTML tags (e.g. <b>…</b>) so we capture lazily
        // with .+? and strip tags afterwards.
        let linkPattern = #"href="/?orderbuch\.php\?[^"]*isin=([A-Z]{2}[A-Z0-9]{10})[^"]*">(.+?)</a>"#
        if let regex = try? NSRegularExpression(pattern: linkPattern) {
            let nsHtml = html as NSString
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            var seen = Set<String>()
            var results: [StockSearchResult] = []
            for match in matches {
                guard match.numberOfRanges >= 3 else { continue }
                let isin = nsHtml.substring(with: match.range(at: 1))
                let rawName = nsHtml.substring(with: match.range(at: 2))
                let name = stripHTMLTags(rawName)
                guard !seen.contains(isin), name.count >= 3 else { continue }
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

    // MARK: - Price preview

    /// Fetch a live price for a holding before it is saved — used for symbol validation.
    /// Yahoo Finance uses the v8 chart API (no crumb required).
    /// Tradegate uses the refresh.php ISIN endpoint.
    func previewPrice(symbol: String, source: PriceSource, isin: String) async throws -> (price: Double, currency: String) {
        switch source {
        case .tradegate:
            guard !isin.isEmpty else { throw PreviewError.missingIdentifier }
            let price = try await fetchTradegatePrice(isin: isin)
            return (price, "EUR")
        case .yahooFinance:
            guard !symbol.isEmpty else { throw PreviewError.missingIdentifier }
            return try await fetchYahooPreviewPrice(symbol: symbol)
        }
    }

    private func fetchTradegatePrice(isin: String) async throws -> Double {
        let url = URL(string: "https://www.tradegatebsx.com/refresh.php?isin=\(isin)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PreviewError.symbolNotFound
        }
        let quote = try JSONDecoder().decode(TradegateQuote.self, from: data)
        guard quote.lastPrice > 0 else { throw PreviewError.symbolNotFound }
        return quote.lastPrice
    }

    private func fetchYahooPreviewPrice(symbol: String) async throws -> (price: Double, currency: String) {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1d&range=1d")!
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PreviewError.symbolNotFound
        }
        let decoded = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        guard let meta = decoded.chart.result?.first?.meta,
              let price = meta.regularMarketPrice, price > 0 else {
            throw PreviewError.symbolNotFound
        }
        let currency = meta.currency ?? "USD"
        // Normalise GBp / GBX (pence) → GBP
        if currency == "GBp" || currency == "GBX" { return (price / 100.0, "GBP") }
        return (price, currency)
    }

    // MARK: - Errors

    enum LookupError: LocalizedError {
        case noAPIKey
        var errorDescription: String? {
            "No Finnhub API key configured. Add one in Settings."
        }
    }

    enum PreviewError: LocalizedError {
        case missingIdentifier
        case symbolNotFound
        var errorDescription: String? {
            switch self {
            case .missingIdentifier: return "Enter a ticker or ISIN first"
            case .symbolNotFound:    return "Symbol not found"
            }
        }
    }
}

// MARK: - Private response models

private struct TradegateQuote: Decodable {
    let lastPrice: Double
    enum CodingKeys: String, CodingKey { case last }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let price = try? c.decode(Double.self, forKey: .last) {
            lastPrice = price
        } else {
            let str = try c.decode(String.self, forKey: .last)
            lastPrice = Double(str.replacingOccurrences(of: ",", with: ".")) ?? 0
        }
    }
}

private struct YahooChartResponse: Decodable {
    let chart: Chart
    struct Chart: Decodable {
        let result: [Result]?
        struct Result: Decodable {
            let meta: Meta
            struct Meta: Decodable {
                let regularMarketPrice: Double?
                let currency: String?
            }
        }
    }
}

private struct FinnhubSearchResponse: Decodable {
    let result: [Symbol]

    struct Symbol: Decodable {
        let symbol: String
        let description: String
        let displaySymbol: String
        let type: String
    }
}
