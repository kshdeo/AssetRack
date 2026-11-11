import Foundation
import Observation
import SwiftUI

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

    // Category order for stacking (bottom → top); investments always on top
    static let stackOrder: [AccountCategory] = [.cashAndBank, .pension, .realEstate, .investments]

    /// Maximum days plotted on the history chart. Raw history is never
    /// deleted; longer ranges are downsampled to stay under this budget so
    /// the chart stays fast and readable regardless of how many years of
    /// snapshots accumulate.
    static let chartPointBudget = 150

    /// Visible window for the history chart. Raw data is always kept; this
    /// only controls what the chart renders.
    enum HistoryRange: String, CaseIterable, Identifiable {
        case threeMonths = "3M"
        case year = "1Y"
        case all = "All"

        var id: String { rawValue }

        var months: Int? {
            switch self {
            case .threeMonths: return 3
            case .year:        return 12
            case .all:         return nil
            }
        }
    }

    // MARK: - Cached state

    private(set) var netWorth: Money         = Money(0, "USD")
    private(set) var totalAssets: Money      = Money(0, "USD")
    private(set) var totalLiabilities: Money = Money(0, "USD")
    private(set) var stackedData: [StackedDataPoint] = []
    private(set) var historyEntries: [AccountHistoryEntry] = []
    private(set) var allocationSegments: [AllocationSegment] = []
    private(set) var topAccounts: [Account] = []

    private(set) var todaysGain: TodaysGain?
    private(set) var topMovers: [AccountMover] = []
    private(set) var weekDelta: Double?
    private(set) var monthDelta: Double?
    private(set) var yearDelta: Double?

    // MARK: - Recalculate

    /// Pure-function pipeline. Call from `.task(id:)` only — never from `body`.
    func recalculate(accounts: [Account], currency: CurrencyService, historyRange: HistoryRange = .all) {
        netWorth         = computeNetWorth(accounts: accounts, currency: currency)
        totalAssets      = computeTotalAssets(accounts: accounts, currency: currency)
        totalLiabilities = computeTotalLiabilities(accounts: accounts, currency: currency)
        // One shared carry-forward walk feeds both the chart and the period
        // deltas. The chart is range-filtered and downsampled; the deltas
        // always use the full series so w/w–y/y stay correct on short ranges.
        let dailyTotals  = computeDailyCategoryTotals(accounts: accounts, currency: currency)
        stackedData      = computeStackedHistoryData(dailyTotals: dailyTotals, range: historyRange)
        historyEntries   = computeAccountHistoryEntries(accounts: accounts, currency: currency)
        allocationSegments = computeAllocationSegments(accounts: accounts, currency: currency)
        topAccounts      = computeTopAccounts(accounts: accounts)
        todaysGain       = computeTodaysGain(accounts: accounts, currency: currency)
        topMovers        = computeTopMovers(accounts: accounts, currency: currency)
        weekDelta        = computePeriodDelta(dailyTotals: dailyTotals, by: .day, value: -7)
        monthDelta       = computePeriodDelta(dailyTotals: dailyTotals, by: .month, value: -1)
        yearDelta        = computePeriodDelta(dailyTotals: dailyTotals, by: .year, value: -1)
    }

    /// Single source of truth for the `.task(id:)` key — captures every input the
    /// dashboard derives data from. Cheap to compute; the iteration only does
    /// integer hash combines.
    static func dataKey(accounts: [Account], currency: CurrencyService, historyRange: HistoryRange = .all) -> Int {
        var hasher = Hasher()
        hasher.combine(historyRange)
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

    struct AccountMover: Identifiable {
        var id: UUID { account.id }
        let account: Account
        let changeAmount: Double  // signed, in base currency
        let changePercent: Double?
        // The holding contributing the most to today's move (holdings accounts only).
        let topHolding: HoldingImpact?
        // True when the change is good for net worth (up for assets, down for liabilities).
        var isGain: Bool { account.dailyChangeIsGain(changeAmount) }
    }

    struct HoldingImpact {
        let symbol: String
        let changeAmount: Double  // signed, in base currency
    }

    struct AllocationSegment: Identifiable {
        var id: AccountCategory { category }
        let category: AccountCategory
        let value: Double        // share of total assets (0…1)
        let color: Color
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

    /// Per-day asset totals by category for every day in history (ascending,
    /// today included with live balances). Built with a single sorted walk per
    /// account — O(days × accounts) — instead of re-filtering each account's
    /// full history for every day, which went quadratic as history grew.
    struct DayTotals {
        let date: Date
        let byCategory: [AccountCategory: Double]
        var total: Double { byCategory.values.reduce(0, +) }
    }

    private func computeDailyCategoryTotals(accounts: [Account], currency: CurrencyService) -> [DayTotals] {
        let calendar = Calendar.current
        let base = currency.baseCurrency
        let today = calendar.startOfDay(for: Date())

        let hasAnySnapshot = accounts.contains { !$0.balanceHistory.isEmpty }
        guard hasAnySnapshot else { return [] }

        var daySet = Set(accounts.flatMap {
            $0.balanceHistory.map { calendar.startOfDay(for: $0.recordedAt) }
        })
        daySet.insert(today)
        let uniqueDays = daySet.sorted()

        let assetAccounts = accounts.filter { !$0.isLiability }
        let sortedHistories = assetAccounts.map {
            $0.balanceHistory.sorted { $0.recordedAt < $1.recordedAt }
        }
        var cursors = [Int](repeating: 0, count: assetAccounts.count)
        var carried = [Double?](repeating: nil, count: assetAccounts.count)

        var result: [DayTotals] = []
        result.reserveCapacity(uniqueDays.count)

        for day in uniqueDays {
            var totals: [AccountCategory: Double] = [:]

            for (idx, account) in assetAccounts.enumerated() {
                while cursors[idx] < sortedHistories[idx].count,
                      calendar.startOfDay(for: sortedHistories[idx][cursors[idx]].recordedAt) <= day {
                    carried[idx] = sortedHistories[idx][cursors[idx]].balance
                    cursors[idx] += 1
                }

                let balance: Double
                if day == today {
                    balance = account.currentBalance
                } else if let carriedBalance = carried[idx] {
                    balance = carriedBalance
                } else {
                    continue
                }
                guard balance > 0 else { continue }

                totals[account.type.category, default: 0] +=
                    currency.convert(Money(balance, account.currency), to: base).amount
            }

            result.append(DayTotals(date: day, byCategory: totals))
        }

        return result
    }

    private func computeStackedHistoryData(dailyTotals: [DayTotals], range: HistoryRange) -> [StackedDataPoint] {
        let visible = Self.downsample(filterToRange(dailyTotals, range: range),
                                      budget: Self.chartPointBudget)

        var result: [StackedDataPoint] = []
        for day in visible {
            var cumulative = 0.0
            for category in Self.stackOrder {
                let value = day.byCategory[category] ?? 0
                guard value > 0 else { continue }
                result.append(StackedDataPoint(
                    date: day.date,
                    category: category,
                    stackedStart: cumulative,
                    stackedEnd: cumulative + value
                ))
                cumulative += value
            }
        }
        return result
    }

    private func filterToRange(_ totals: [DayTotals], range: HistoryRange) -> [DayTotals] {
        guard let months = range.months, let last = totals.last else { return totals }
        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: last.date)!
        return totals.filter { $0.date >= cutoff }
    }

    /// Thin a day series to at most `budget` points. Steps backwards from the
    /// newest day so today is always kept, and pins the earliest day so the
    /// chart spans the full range.
    static func downsample(_ totals: [DayTotals], budget: Int) -> [DayTotals] {
        guard totals.count > budget, let first = totals.first else { return totals }

        let step = Int((Double(totals.count) / Double(budget)).rounded(.up))
        var kept: [DayTotals] = []
        var idx = totals.count - 1
        while idx >= 0 {
            kept.append(totals[idx])
            idx -= step
        }
        if kept.last?.date != first.date { kept.append(first) }
        return Array(kept.reversed())
    }

    // MARK: - Per-account history entries

    private func computeAccountHistoryEntries(accounts: [Account], currency: CurrencyService) -> [AccountHistoryEntry] {
        let calendar = Calendar.current
        let base = currency.baseCurrency
        let today = calendar.startOfDay(for: Date())

        let hasAnySnapshot = accounts.contains { !$0.balanceHistory.isEmpty }
        guard hasAnySnapshot else { return [] }

        var daySet = Set(accounts.flatMap {
            $0.balanceHistory.map { calendar.startOfDay(for: $0.recordedAt) }
        })
        daySet.insert(today)
        let uniqueDays = daySet.sorted()

        // Same walking-pointer pattern as computeDailyCategoryTotals: ascend
        // through the days once, carrying each account's latest snapshot.
        let sortedHistories = accounts.map {
            $0.balanceHistory.sorted { $0.recordedAt < $1.recordedAt }
        }
        var cursors = [Int](repeating: 0, count: accounts.count)
        var carried = [BalanceSnapshot?](repeating: nil, count: accounts.count)

        var entries: [AccountHistoryEntry] = []
        entries.reserveCapacity(uniqueDays.count)

        for day in uniqueDays {
            var rows: [AccountHistoryEntry.AccountRow] = []
            var total = 0.0

            for (idx, account) in accounts.enumerated() {
                while cursors[idx] < sortedHistories[idx].count,
                      calendar.startOfDay(for: sortedHistories[idx][cursors[idx]].recordedAt) <= day {
                    carried[idx] = sortedHistories[idx][cursors[idx]]
                    cursors[idx] += 1
                }

                let balance: Double
                let exact: BalanceSnapshot?

                if day == today {
                    balance = account.currentBalance
                    exact = nil
                } else {
                    guard let latest = carried[idx] else { continue }
                    balance = latest.balance
                    exact = calendar.isDate(latest.recordedAt, inSameDayAs: day) ? latest : nil
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

            entries.append(AccountHistoryEntry(
                date: day,
                baseCurrency: base,
                totalInBase: total,
                rows: rows.sorted { $0.accountName < $1.accountName }
            ))
        }

        return Array(entries.reversed())
    }

    // MARK: - Today's gain

    /// Zero while markets are closed, never the last session's move. Nil only when
    /// there's no earlier history to compare against.
    private func computeTodaysGain(accounts: [Account], currency: CurrencyService) -> TodaysGain? {
        let (amount, baseline) = NetWorthMath.todaysChangeAndBaseline(accounts: accounts, currency: currency)
        guard let baseline else { return nil }
        return TodaysGain(amount: amount, percent: baseline != 0 ? amount / abs(baseline) : nil)
    }

    // MARK: - Period deltas

    private func computePeriodDelta(dailyTotals: [DayTotals], by component: Calendar.Component, value: Int) -> Double? {
        guard let last = dailyTotals.last else { return nil }

        let anchor = Calendar.current.date(byAdding: component, value: value, to: last.date)!
        guard let prev = Self.interpolatedTotal(at: anchor, in: dailyTotals), prev != 0 else { return nil }
        return (last.total - prev) / abs(prev)
    }

    /// Total at `date`, linearly interpolated between the recorded days on
    /// either side of it, so sparse history (e.g. points 15 and 7 months ago)
    /// still gives a fair 12-month baseline instead of snapping to the nearer
    /// point. Nil when history doesn't reach back to `date`: a "y/y" built from
    /// a shorter span would be mislabelled. `totals` must be ascending.
    static func interpolatedTotal(at date: Date, in totals: [DayTotals]) -> Double? {
        guard let beforeIndex = totals.lastIndex(where: { $0.date <= date }) else { return nil }
        let before = totals[beforeIndex]
        guard before.date < date, beforeIndex + 1 < totals.count else { return before.total }

        let after = totals[beforeIndex + 1]
        let fraction = date.timeIntervalSince(before.date) / after.date.timeIntervalSince(before.date)
        return before.total + (after.total - before.total) * fraction
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
            .map { AllocationSegment(category: $0.key, value: $0.value / total, color: $0.key.accentColor) }
            .sorted { $0.value > $1.value }
    }

    // MARK: - Top movers

    private func computeTopMovers(accounts: [Account], currency: CurrencyService, limit: Int = 3) -> [AccountMover] {
        let base = currency.baseCurrency
        return accounts
            .compactMap { account -> AccountMover? in
                // dailyChangePercent is nil for accounts not updated today
                // (stale prices, closed markets) — they drop out here.
                guard let pct = account.dailyChangePercent() else { return nil }
                let balanceInBase = currency.convert(Money(account.currentBalance, account.currency), to: base).amount
                let changeInBase = pct * balanceInBase
                return AccountMover(account: account,
                                    changeAmount: changeInBase,
                                    changePercent: pct,
                                    topHolding: topHoldingImpact(of: account, currency: currency))
            }
            .sorted { abs($0.changeAmount) > abs($1.changeAmount) }
            .prefix(limit)
            .map { $0 }
    }

    /// The holding with the largest absolute day change, in base currency.
    /// Nil for manual accounts and holdings without a reference close.
    private func topHoldingImpact(of account: Account, currency: CurrencyService) -> HoldingImpact? {
        let base = currency.baseCurrency
        return account.holdings
            .compactMap { holding -> HoldingImpact? in
                guard holding.dailyChangePercent != nil else { return nil }
                let delta = (holding.lastPrice - holding.previousClose) * holding.quantity
                guard delta != 0 else { return nil }
                let deltaInBase = currency.convert(Money(delta, holding.priceCurrency), to: base).amount
                return HoldingImpact(symbol: holding.tickerSymbol, changeAmount: deltaInBase)
            }
            .max { abs($0.changeAmount) < abs($1.changeAmount) }
    }

    // MARK: - Accounts list

    private func computeTopAccounts(accounts: [Account], limit: Int = 5) -> [Account] {
        accounts
            .sorted { abs($0.currentBalance) > abs($1.currentBalance) }
            .prefix(limit)
            .map { $0 }
    }
}
