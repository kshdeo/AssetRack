import Foundation

// MARK: - Result type

struct StockSearchResult: Identifiable {
    let id = UUID()
    /// Exchange-level symbol (e.g. "VOW3.DE")
    let symbol: String
    /// Human-readable company name
    let description: String
    /// Clean display ticker (e.g. "VOW3")
    let displaySymbol: String
    /// Security type (e.g. "Common Stock", "ETP")
    let type: String
}

// MARK: - Service

struct ISINLookupService {

    static let apiKeyDefaultsKey = "finnhub_api_key"

    /// Search for securities by name or ticker.
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
            StockSearchResult(symbol: $0.symbol, description: $0.description,
                              displaySymbol: $0.displaySymbol, type: $0.type)
        }
    }

    /// Fetch the ISIN for a given symbol via Finnhub's company profile endpoint.
    func isin(for symbol: String, apiKey: String) async throws -> String? {
        guard !apiKey.isEmpty else { throw LookupError.noAPIKey }
        var components = URLComponents(string: "https://finnhub.io/api/v1/stock/profile2")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "token",  value: apiKey)
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(FinnhubProfileResponse.self, from: data)
        return decoded.isin
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

private struct FinnhubProfileResponse: Decodable {
    let isin: String?
}
