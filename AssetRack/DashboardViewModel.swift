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
        let today = calendar.startOfDay(for: Date())

        // Collect all unique calendar days from snapshots, always including today
        var daySet = Set(accounts.flatMap {
            $0.balanceHistory.map { calendar.startOfDay(for: $0.recordedAt) }
        })
        daySet.insert(today)
        let uniqueDays = daySet.sorted()

        // Need at least one snapshot somewhere to draw history
        let hasAnySnapshot = accounts.contains { !$0.balanceHistory.isEmpty }
        guard hasAnySnapshot else { return [] }

        var result: [StackedDataPoint] = []

        for day in uniqueDays {
            var categoryTotals: [AccountCategory: Double] = [:]

            for account in accounts where !account.isLiability {
                // For today use the live balance; for past days carry-forward from snapshots
                let balance: Double
                if day == today {
                    balance = account.currentBalance
                } else {
                    guard let snap = account.balanceHistory
                        .filter({ calendar.startOfDay(for: $0.recordedAt) <= day })
                        .max(by: { $0.recordedAt < $1.recordedAt }) else { continue }
                    balance = snap.balance
                }
                guard balance > 0 else { continue }

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
        /// All accounts with a known balance on or before this date.
        let rows: [AccountRow]

        struct AccountRow: Identifiable {
            /// Account id — stable even for carried-forward rows.
            let id: UUID
            let accountName: String
            let isLiability: Bool
            let currency: String
            let balance: Double
            /// Non-nil only when there is a snapshot recorded on this exact calendar day.
            /// Nil means the value is carried forward from a previous day (read-only).
            let snapshot: BalanceSnapshot?
            var isCarriedForward: Bool { snapshot == nil }
        }
    }

    func accountHistoryEntries(from accounts: [Account], currency: CurrencyService) -> [AccountHistoryEntry] {
        let calendar = Calendar.current
        let base = currency.baseCurrency
        let today = calendar.startOfDay(for: Date())

        // Unique days from snapshots, always including today
        var daySet = Set(accounts.flatMap {
            $0.balanceHistory.map { calendar.startOfDay(for: $0.recordedAt) }
        })
        daySet.insert(today)
        let uniqueDays = daySet.sorted().reversed()

        let hasAnySnapshot = accounts.contains { !$0.balanceHistory.isEmpty }
        guard hasAnySnapshot else { return [] }

        return uniqueDays.map { day in
            var rows: [AccountHistoryEntry.AccountRow] = []
            var total = 0.0

            for account in accounts {
                let balance: Double
                let exact: BalanceSnapshot?

                if day == today {
                    // Always use live balance for today's entry
                    balance = account.currentBalance
                    exact = nil   // today's synthetic entry is not directly editable
                } else {
                    // Carry-forward: most recent snapshot on or before this day
                    guard let latest = account.balanceHistory
                        .filter({ calendar.startOfDay(for: $0.recordedAt) <= day })
                        .max(by: { $0.recordedAt < $1.recordedAt }) else { continue }
                    balance = latest.balance
                    // Exact snapshot for this day (editable)
                    exact = account.balanceHistory
                        .filter({ calendar.startOfDay(for: $0.recordedAt) == day })
                        .max(by: { $0.recordedAt < $1.recordedAt })
                }

                let signed = account.isLiability ? -balance : balance
                total += currency.convert(Money(signed, account.currency), to: base).amount

                rows.append(AccountHistoryEntry.AccountRow(
                    id: account.id,
                    accountName: account.name,
                    isLiability: account.isLiability,
                    currency: account.currency,
                    balance: balance,
                    snapshot: exact
                ))
            }

            return AccountHistoryEntry(
                date: day,
                baseCurrency: base,
                totalInBase: total,
                rows: rows.sorted { $0.accountName < $1.accountName }
            )
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
