import Foundation
import Observation

// MARK: - Stacked chart data

struct StackedDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let category: AccountCategory
    let stackedStart: Double
    let stackedEnd: Double

    var value: Double { stackedEnd - stackedStart }
}

// MARK: - ViewModel

@Observable
final class DashboardViewModel {

    // Category order for stacking (bottom → top)
    static let stackOrder: [AccountCategory] = [.cashAndBank, .investments, .pension, .realEstate]

    // MARK: - Net worth (current)

    func netWorth(from accounts: [Account], currency: CurrencyService) -> Money {
        currency.sum(accounts.map { Money($0.signedBalance, $0.currency) }, in: currency.baseCurrency)
    }

    func totalAssets(from accounts: [Account], currency: CurrencyService) -> Money {
        currency.sum(
            accounts.filter { !$0.isLiability }.map { Money($0.currentBalance, $0.currency) },
            in: currency.baseCurrency
        )
    }

    func totalLiabilities(from accounts: [Account], currency: CurrencyService) -> Money {
        currency.sum(
            accounts.filter { $0.isLiability }.map { Money($0.currentBalance, $0.currency) },
            in: currency.baseCurrency
        )
    }

    // MARK: - Stacked history (derived from BalanceSnapshot)

    /// Builds stacked area chart data from per-account BalanceSnapshot history.
    /// Uses current FX rates for currency conversion.
    func stackedHistoryData(from accounts: [Account], currency: CurrencyService) -> [StackedDataPoint] {
        let calendar = Calendar.current
        let base = currency.baseCurrency

        // Collect all unique calendar days that have at least one balance snapshot
        let allDays = accounts.flatMap {
            $0.balanceHistory.map { calendar.startOfDay(for: $0.recordedAt) }
        }
        let uniqueDays = Array(Set(allDays)).sorted()
        guard !uniqueDays.isEmpty else { return [] }

        var result: [StackedDataPoint] = []

        for day in uniqueDays {
            var categoryTotals: [AccountCategory: Double] = [:]

            for account in accounts where !account.isLiability {
                // Most recent snapshot on or before this day
                guard let balance = account.balanceHistory
                    .filter({ calendar.startOfDay(for: $0.recordedAt) <= day })
                    .max(by: { $0.recordedAt < $1.recordedAt })?
                    .balance else { continue }

                let converted = currency.convert(Money(balance, account.currency), to: base).amount
                categoryTotals[account.type.category, default: 0] += converted
            }

            // Build stacked segments bottom-up
            var cumulative = 0.0
            for category in Self.stackOrder {
                let value = categoryTotals[category] ?? 0
                guard value > 0 else { continue }
                result.append(StackedDataPoint(
                    date: day,
                    category: category,
                    stackedStart: cumulative,
                    stackedEnd: cumulative + value
                ))
                cumulative += value
            }
        }

        return result
    }

    // MARK: - Per-account history entries (for the list view)

    struct AccountHistoryEntry: Identifiable {
        let id = UUID()
        let date: Date
        let baseCurrency: String
        let totalInBase: Double
        /// One row per account that recorded a snapshot on this exact calendar day.
        let rows: [AccountRow]

        struct AccountRow: Identifiable {
            let id: UUID          // snapshot id
            let accountName: String
            let isLiability: Bool
            let currency: String
            let snapshot: BalanceSnapshot
        }
    }

    func accountHistoryEntries(from accounts: [Account], currency: CurrencyService) -> [AccountHistoryEntry] {
        let calendar = Calendar.current
        let base = currency.baseCurrency

        // Group all snapshots by calendar day, keeping the latest per account per day
        var dayMap: [Date: [(account: Account, snapshot: BalanceSnapshot)]] = [:]
        for account in accounts {
            let byDay = Dictionary(grouping: account.balanceHistory) {
                calendar.startOfDay(for: $0.recordedAt)
            }
            for (day, snaps) in byDay {
                guard let latest = snaps.max(by: { $0.recordedAt < $1.recordedAt }) else { continue }
                dayMap[day, default: []].append((account, latest))
            }
        }

        return dayMap
            .sorted { $0.key > $1.key }   // most recent first
            .map { day, pairs in
                let rows: [AccountHistoryEntry.AccountRow] = pairs
                    .sorted { $0.account.name < $1.account.name }
                    .map { account, snapshot in
                        AccountHistoryEntry.AccountRow(
                            id: snapshot.id,
                            accountName: account.name,
                            isLiability: account.isLiability,
                            currency: account.currency,
                            snapshot: snapshot
                        )
                    }
                let total = rows.reduce(0.0) { sum, row in
                    let signed = row.isLiability ? -row.snapshot.balance : row.snapshot.balance
                    return sum + currency.convert(Money(signed, row.currency), to: base).amount
                }
                return AccountHistoryEntry(date: day, baseCurrency: base, totalInBase: total, rows: rows)
            }
    }

    // MARK: - Month-over-month delta (derived from stacked data)

    func monthOverMonthDelta(from stackedData: [StackedDataPoint]) -> Double? {
        let dates = Array(Set(stackedData.map { $0.date })).sorted()
        guard let lastDate = dates.last else { return nil }

        let oneMonthAgo = Calendar.current.date(byAdding: .month, value: -1, to: lastDate)!
        guard let prevDate = dates.min(by: {
            abs($0.timeIntervalSince(oneMonthAgo)) < abs($1.timeIntervalSince(oneMonthAgo))
        }), prevDate != lastDate else { return nil }

        let prev = stackedData.filter { $0.date == prevDate }.map { $0.value }.reduce(0, +)
        let curr = stackedData.filter { $0.date == lastDate }.map { $0.value }.reduce(0, +)
        guard prev != 0 else { return nil }
        return (curr - prev) / abs(prev)
    }

    // MARK: - Allocation

    func allocationSegments(from accounts: [Account], currency: CurrencyService) -> [(category: AccountCategory, value: Double, color: String)] {
        let assets = accounts.filter { !$0.isLiability }
        let total = currency.sum(assets.map { Money($0.currentBalance, $0.currency) }, in: currency.baseCurrency).amount
        guard total > 0 else { return [] }

        var grouped: [AccountCategory: Double] = [:]
        for account in assets {
            grouped[account.type.category, default: 0] += currency.convert(
                Money(account.currentBalance, account.currency),
                to: currency.baseCurrency
            ).amount
        }

        return grouped
            .map { (category: $0.key, value: $0.value / total, color: colorName(for: $0.key)) }
            .sorted { $0.value > $1.value }
    }

    private func colorName(for category: AccountCategory) -> String {
        switch category {
        case .cashAndBank:  return "teal"
        case .investments:  return "blue"
        case .pension:      return "purple"
        case .realEstate:   return "indigo"
        case .liabilities:  return "red"
        }
    }

    // MARK: - Accounts list

    func topAccounts(from accounts: [Account], limit: Int = 5) -> [Account] {
        accounts
            .sorted { abs($0.currentBalance) > abs($1.currentBalance) }
            .prefix(limit)
            .map { $0 }
    }
}
