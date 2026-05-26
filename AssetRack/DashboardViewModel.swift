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

/// Holds all derived dashboard state. Views read these cached properties;
/// `recalculate(...)` runs the pure-function pipeline and is wired via
/// `.task(id: DashboardViewModel.dataKey(...))` so the heavy work only fires
/// when an input actually changes — see CLAUDE.md rule #7.
@Observable
final class DashboardViewModel {

    // Category order for stacking (bottom → top)
    static let stackOrder: [AccountCategory] = [.cashAndBank, .investments, .pension, .realEstate]

    // MARK: - Cached state

    private(set) var netWorth: Money         = Money(0, "USD")
    private(set) var totalAssets: Money      = Money(0, "USD")
    private(set) var totalLiabilities: Money = Money(0, "USD")
    private(set) var stackedData: [StackedDataPoint] = []
    private(set) var historyEntries: [AccountHistoryEntry] = []
    private(set) var allocationSegments: [AllocationSegment] = []
    private(set) var topAccounts: [Account] = []

    private(set) var todaysGain: TodaysGain?
    private(set) var weekDelta: Double?
    private(set) var monthDelta: Double?
    private(set) var yearDelta: Double?

    // MARK: - Recalculate

    /// Pure-function pipeline. Call from `.task(id:)` only — never from `body`.
    func recalculate(accounts: [Account], currency: CurrencyService) {
        netWorth         = computeNetWorth(accounts: accounts, currency: currency)
        totalAssets      = computeTotalAssets(accounts: accounts, currency: currency)
        totalLiabilities = computeTotalLiabilities(accounts: accounts, currency: currency)
        stackedData      = computeStackedHistoryData(accounts: accounts, currency: currency)
        historyEntries   = computeAccountHistoryEntries(accounts: accounts, currency: currency)
        allocationSegments = computeAllocationSegments(accounts: accounts, currency: currency)
        topAccounts      = computeTopAccounts(accounts: accounts)
        todaysGain       = computeTodaysGain(historyEntries: historyEntries)
        weekDelta        = computePeriodDelta(stackedData: stackedData, by: .day, value: -7)
        monthDelta       = computePeriodDelta(stackedData: stackedData, by: .month, value: -1)
        yearDelta        = computePeriodDelta(stackedData: stackedData, by: .year, value: -1)
    }

    /// Single source of truth for the `.task(id:)` key — captures every input the
    /// dashboard derives data from. Cheap to compute; the iteration only does
    /// integer hash combines.
    static func dataKey(accounts: [Account], currency: CurrencyService) -> Int {
        var hasher = Hasher()
        for account in accounts {
            hasher.combine(account.id)
            hasher.combine(account.currentBalance)
            hasher.combine(account.currency)
            hasher.combine(account.typeRaw)
            hasher.combine(account.balanceHistory.count)
            for snap in account.balanceHistory {
                hasher.combine(snap.id)
                hasher.combine(snap.balance)
                hasher.combine(snap.recordedAt)
            }
        }
        hasher.combine(currency.baseCurrency)
        hasher.combine(currency.lastFetched)
        return hasher.finalize()
    }

    // MARK: - Supporting types

    struct TodaysGain {
        let amount: Double
        let percent: Double?
    }

    struct AllocationSegment: Identifiable {
        var id: AccountCategory { category }
        let category: AccountCategory
        let value: Double        // share of total assets (0…1)
        let color: String
    }

    struct AccountHistoryEntry: Identifiable {
        let id = UUID()
        let date: Date
        let baseCurrency: String
        let totalInBase: Double
        let rows: [AccountRow]

        struct AccountRow: Identifiable {
            let id: UUID
            let accountName: String
            let isLiability: Bool
            let currency: String
            let balance: Double
            let snapshot: BalanceSnapshot?
            var isCarriedForward: Bool { snapshot == nil }
        }
    }

    // MARK: - Net worth (current)

    private func computeNetWorth(accounts: [Account], currency: CurrencyService) -> Money {
        currency.sum(accounts.map { Money($0.signedBalance, $0.currency) }, in: currency.baseCurrency)
    }

    private func computeTotalAssets(accounts: [Account], currency: CurrencyService) -> Money {
        currency.sum(
            accounts.filter { !$0.isLiability }.map { Money($0.currentBalance, $0.currency) },
            in: currency.baseCurrency
        )
    }

    private func computeTotalLiabilities(accounts: [Account], currency: CurrencyService) -> Money {
        currency.sum(
            accounts.filter { $0.isLiability }.map { Money($0.currentBalance, $0.currency) },
            in: currency.baseCurrency
        )
    }

    // MARK: - Stacked history

    private func computeStackedHistoryData(accounts: [Account], currency: CurrencyService) -> [StackedDataPoint] {
        let calendar = Calendar.current
        let base = currency.baseCurrency
        let today = calendar.startOfDay(for: Date())

        var daySet = Set(accounts.flatMap {
            $0.balanceHistory.map { calendar.startOfDay(for: $0.recordedAt) }
        })
        daySet.insert(today)
        let uniqueDays = daySet.sorted()

        let hasAnySnapshot = accounts.contains { !$0.balanceHistory.isEmpty }
        guard hasAnySnapshot else { return [] }

        var result: [StackedDataPoint] = []

        for day in uniqueDays {
            var categoryTotals: [AccountCategory: Double] = [:]

            for account in accounts where !account.isLiability {
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

    // MARK: - Per-account history entries

    private func computeAccountHistoryEntries(accounts: [Account], currency: CurrencyService) -> [AccountHistoryEntry] {
        let calendar = Calendar.current
        let base = currency.baseCurrency
        let today = calendar.startOfDay(for: Date())

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
                    balance = account.currentBalance
                    exact = nil
                } else {
                    guard let latest = account.balanceHistory
                        .filter({ calendar.startOfDay(for: $0.recordedAt) <= day })
                        .max(by: { $0.recordedAt < $1.recordedAt }) else { continue }
                    balance = latest.balance
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

    // MARK: - Today's gain

    private func computeTodaysGain(historyEntries: [AccountHistoryEntry]) -> TodaysGain? {
        guard historyEntries.count >= 2 else { return nil }
        // Entries come back in descending order — [0] is today's live row, [1]
        // is the most recent prior snapshot.
        let today    = historyEntries[0].totalInBase
        let previous = historyEntries[1].totalInBase
        let amount   = today - previous
        let percent  = previous != 0 ? amount / abs(previous) : nil
        return TodaysGain(amount: amount, percent: percent)
    }

    // MARK: - Period deltas

    private func computePeriodDelta(stackedData: [StackedDataPoint], by component: Calendar.Component, value: Int) -> Double? {
        let dates = Array(Set(stackedData.map { $0.date })).sorted()
        guard let lastDate = dates.last else { return nil }

        let anchor = Calendar.current.date(byAdding: component, value: value, to: lastDate)!
        guard let prevDate = dates.min(by: {
            abs($0.timeIntervalSince(anchor)) < abs($1.timeIntervalSince(anchor))
        }), prevDate != lastDate else { return nil }

        let prev = stackedData.filter { $0.date == prevDate }.map { $0.value }.reduce(0, +)
        let curr = stackedData.filter { $0.date == lastDate }.map { $0.value }.reduce(0, +)
        guard prev != 0 else { return nil }
        return (curr - prev) / abs(prev)
    }

    // MARK: - Allocation

    private func computeAllocationSegments(accounts: [Account], currency: CurrencyService) -> [AllocationSegment] {
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
            .map { AllocationSegment(category: $0.key, value: $0.value / total, color: colorName(for: $0.key)) }
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

    private func computeTopAccounts(accounts: [Account], limit: Int = 5) -> [Account] {
        accounts
            .sorted { abs($0.currentBalance) > abs($1.currentBalance) }
            .prefix(limit)
            .map { $0 }
    }
}
