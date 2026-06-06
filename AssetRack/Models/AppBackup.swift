import Foundation

/// Codable snapshot of the app's full SwiftData state — accounts, holdings,
/// per-account balance history, net-worth history, and projection assumptions.
/// Intentionally separate from the `@Model` classes so the on-disk format is
/// stable across schema changes.
///
/// **Versioning.** The top-level `version` field is bumped whenever the format
/// gains required fields. New fields are added as `Optional` so older backups
/// still decode cleanly:
///   * v1 — accounts + holdings + currentBalance only
///   * v2 — adds `balanceHistory`, `netWorthSnapshots`, `projectionSettings`,
///          plus the previously-missing holding fields
///          (`previousClose`, `priceSourceRaw`, `isin`, `name`,
///           `lastPriceFetchedAt`).
struct AppBackup: Codable {
    let version: Int
    let exportedAt: Date
    let accounts: [AccountBackup]

    // MARK: v2 additions (optional — absent in v1 files)

    let netWorthSnapshots: [NetWorthSnapshotBackup]?
    let projectionSettings: ProjectionSettingsBackup?

    init(
        accounts: [AccountBackup],
        netWorthSnapshots: [NetWorthSnapshotBackup]? = nil,
        projectionSettings: ProjectionSettingsBackup? = nil
    ) {
        self.version = 2
        self.exportedAt = Date()
        self.accounts = accounts
        self.netWorthSnapshots = netWorthSnapshots
        self.projectionSettings = projectionSettings
    }

    // MARK: Account

    struct AccountBackup: Codable {
        let name: String
        let type: String        // AccountType.rawValue
        let institution: String
        let currency: String
        let currentBalance: Double
        let cashBalance: Double
        let holdings: [HoldingBackup]

        // v2 additions
        let balanceHistory: [BalanceSnapshotBackup]?
        let createdAt: Date?
        let updatedAt: Date?
    }

    // MARK: Holding

    struct HoldingBackup: Codable {
        let tickerSymbol: String
        let quantity: Double
        let lastPrice: Double
        let priceCurrency: String

        // v2 additions
        let name: String?
        let isin: String?
        let priceSourceRaw: String?
        let previousClose: Double?
        let lastPriceFetchedAt: Date?
    }

    // MARK: Snapshots

    struct BalanceSnapshotBackup: Codable {
        let balance: Double
        let recordedAt: Date
    }

    struct NetWorthSnapshotBackup: Codable {
        let netWorth: Double
        let totalAssets: Double
        let totalLiabilities: Double
        let currency: String
        let recordedAt: Date
    }

    // MARK: Projection settings

    struct ProjectionSettingsBackup: Codable {
        let cashRate: Double
        let investmentsRate: Double
        let pensionRate: Double
        let realEstateRate: Double
        let liabilityPaydownYears: Int
        let monthlyIncome: Double
        let monthlyExpenses: Double
        let horizonYears: Int
    }
}

// MARK: - Build a backup from live SwiftData state

extension AppBackup {
    /// Build a backup from live SwiftData state. Callers fetch each entity
    /// type and pass them in — the backup struct doesn't touch `ModelContext`
    /// so it stays testable and Sendable-friendly.
    static func from(
        accounts: [Account],
        netWorthSnapshots: [NetWorthSnapshot] = [],
        projectionSettings: ProjectionSettings? = nil
    ) -> AppBackup {
        AppBackup(
            accounts: accounts.map { account in
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
                            priceCurrency: h.priceCurrency,
                            name: h.name,
                            isin: h.isin,
                            priceSourceRaw: h.priceSourceRaw,
                            previousClose: h.previousClose,
                            lastPriceFetchedAt: h.lastPriceFetchedAt
                        )
                    },
                    balanceHistory: account.balanceHistory.map { snap in
                        BalanceSnapshotBackup(
                            balance: snap.balance,
                            recordedAt: snap.recordedAt
                        )
                    },
                    createdAt: account.createdAt,
                    updatedAt: account.updatedAt
                )
            },
            netWorthSnapshots: netWorthSnapshots.map { s in
                NetWorthSnapshotBackup(
                    netWorth: s.netWorth,
                    totalAssets: s.totalAssets,
                    totalLiabilities: s.totalLiabilities,
                    currency: s.currency,
                    recordedAt: s.recordedAt
                )
            },
            projectionSettings: projectionSettings.map { p in
                ProjectionSettingsBackup(
                    cashRate: p.cashRate,
                    investmentsRate: p.investmentsRate,
                    pensionRate: p.pensionRate,
                    realEstateRate: p.realEstateRate,
                    liabilityPaydownYears: p.liabilityPaydownYears,
                    monthlyIncome: p.monthlyIncome,
                    monthlyExpenses: p.monthlyExpenses,
                    horizonYears: p.horizonYears
                )
            }
        )
    }

    // MARK: Encoding / decoding

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
