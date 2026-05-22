import Foundation

/// Codable snapshot of all accounts and their holdings.
/// Used for JSON export/import. Intentionally separate from SwiftData models.
struct AppBackup: Codable {
    let version: Int
    let exportedAt: Date
    let accounts: [AccountBackup]

    init(accounts: [AccountBackup]) {
        self.version = 1
        self.exportedAt = Date()
        self.accounts = accounts
    }

    struct AccountBackup: Codable {
        let name: String
        let type: String        // AccountType.rawValue
        let institution: String
        let currency: String
        let currentBalance: Double
        let cashBalance: Double
        let holdings: [HoldingBackup]
    }

    struct HoldingBackup: Codable {
        let tickerSymbol: String
        let quantity: Double
        let lastPrice: Double
        let priceCurrency: String
    }
}

// MARK: - Conversion helpers

extension AppBackup {
    /// Build a backup from live SwiftData Account objects.
    static func from(accounts: [Account]) -> AppBackup {
        AppBackup(accounts: accounts.map { account in
            AccountBackup(
                name: account.name,
                type: account.typeRaw,
                institution: account.institution,
                currency: account.currency,
                currentBalance: account.currentBalance,
                cashBalance: account.cashBalance,
                holdings: account.holdings.map { h in
                    HoldingBackup(
                        tickerSymbol: h.tickerSymbol,
                        quantity: h.quantity,
                        lastPrice: h.lastPrice,
                        priceCurrency: h.priceCurrency
                    )
                }
            )
        })
    }

    /// Encode to pretty-printed JSON data.
    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Decode from JSON data, returning a descriptive error on failure.
    static func decode(from data: Data) throws -> AppBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppBackup.self, from: data)
    }

    /// Write to a temp file and return its URL (suitable for share sheet).
    func writeToTempFile() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = "assetrack-backup-\(formatter.string(from: exportedAt)).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try encode().write(to: url)
        return url
    }
}
