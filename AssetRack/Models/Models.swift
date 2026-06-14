import Foundation
import SwiftData

// MARK: - Enums

enum AccountType: String, CaseIterable, Codable {
    case checking = "checking"
    case savings = "savings"
    case brokerage = "brokerage"
    case pension = "pension"
    case realEstate = "realEstate"
    case mortgage = "mortgage"
    case creditCard = "creditCard"
    case loan = "loan"

    var displayName: String {
        switch self {
        case .checking:    return "Checking"
        case .savings:     return "Savings"
        case .brokerage:   return "Brokerage"
        case .pension:     return "Pension"
        case .realEstate:  return "Real Estate"
        case .mortgage:    return "Mortgage"
        case .creditCard:  return "Credit Card"
        case .loan:        return "Loan"
        }
    }

    var category: AccountCategory {
        switch self {
        case .checking, .savings:               return .cashAndBank
        case .brokerage:                        return .investments
        case .pension:                          return .pension
        case .realEstate:                       return .realEstate
        case .mortgage, .creditCard, .loan:     return .liabilities
        }
    }

    var isLiability: Bool { category == .liabilities }

    var supportsHoldings: Bool { self == .brokerage || self == .pension }

    var systemImage: String {
        switch self {
        case .checking:    return "building.columns"
        case .savings:     return "banknote"
        case .brokerage:   return "chart.line.uptrend.xyaxis"
        case .pension:     return "briefcase"
        case .realEstate:  return "house"
        case .mortgage:    return "house.and.flag"
        case .creditCard:  return "creditcard"
        case .loan:        return "dollarsign.arrow.circlepath"
        }
    }
}

enum AccountCategory: String, CaseIterable {
    case cashAndBank   = "Cash & Bank"
    case investments   = "Investments"
    case pension       = "Pension"
    case realEstate    = "Real Estate"
    case liabilities   = "Liabilities"
}

// MARK: - Price Source

enum PriceSource: String, Codable, CaseIterable {
    case yahooFinance = "yahooFinance"
    case tradegate    = "tradegate"

    var displayName: String {
        switch self {
        case .yahooFinance: return "Yahoo Finance"
        case .tradegate:    return "Tradegate"
        }
    }
}

// MARK: - Holding

@Model
final class Holding {
    var id: UUID = UUID()
    var tickerSymbol: String = ""
    var name: String = ""
    var quantity: Double = 0.0
    var lastPrice: Double = 0.0
    var priceCurrency: String = "USD"
    var lastPriceFetchedAt: Date? = nil
    /// Identifies the data source used to fetch this holding's price.
    var priceSourceRaw: String = PriceSource.yahooFinance.rawValue
    /// ISIN used when priceSource == .tradegate (e.g. "DE0007664039").
    var isin: String = ""

    /// Previous trading day's close, as reported by the price API itself
    /// (Yahoo's `regularMarketPreviousClose`, Tradegate's `close`). Source of
    /// truth for the "daily change" badge — accurate across weekends/holidays
    /// because the API returns the *previous trading session's* close.
    var previousClose: Double = 0

    var value: Double { lastPrice * quantity }

    var priceSource: PriceSource {
        get { PriceSource(rawValue: priceSourceRaw) ?? .yahooFinance }
        set { priceSourceRaw = newValue.rawValue }
    }

    /// Percent change from `previousClose` to `lastPrice` (0.01 = 1%).
    /// Returns nil when there's no previous close or the change is exactly zero.
    var dailyChangePercent: Double? {
        guard previousClose > 0 else { return nil }
        let pct = (lastPrice - previousClose) / previousClose
        return pct == 0 ? nil : pct
    }

    init(tickerSymbol: String, quantity: Double, priceSource: PriceSource = .yahooFinance, isin: String = "") {
        self.id = UUID()
        self.tickerSymbol = tickerSymbol.uppercased().trimmingCharacters(in: .whitespaces)
        self.quantity = quantity
        self.lastPrice = 0.0
        self.name = ""
        self.priceSourceRaw = priceSource.rawValue
        self.isin = isin
    }
}

// MARK: - Account

@Model
final class Account: Identifiable {
    var id: UUID = UUID()
    var name: String = ""
    var typeRaw: String = AccountType.checking.rawValue
    var currentBalance: Double = 0.0
    var cashBalance: Double = 0.0
    var currency: String = "USD"
    var institution: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade)
    var holdings: [Holding] = []

    @Relationship(deleteRule: .cascade)
    var balanceHistory: [BalanceSnapshot] = []

    var type: AccountType {
        get { AccountType(rawValue: typeRaw) ?? .checking }
        set { typeRaw = newValue.rawValue }
    }

    var isLiability: Bool { type.isLiability }
    var hasHoldings: Bool { !holdings.isEmpty }

    var signedBalance: Double { isLiability ? -currentBalance : currentBalance }

    /// Strict daily change badge (0.01 = 1%): today's value vs yesterday's.
    /// Returns `nil` when nothing changed today — no badge for stale movements.
    ///
    /// - **Holdings accounts (brokerage):** sum of holdings' current value vs sum
    ///   of holdings' `previousClose * quantity` (the prior trading session's
    ///   close from the API), as a fraction of the account's prior total.
    /// - **Manual accounts (cash, savings, property, liabilities):** current
    ///   balance vs yesterday's carry-forward value (the most recent snapshot
    ///   recorded strictly before today). An account untouched today returns
    ///   `nil` — both sides are equal — so no badge appears.
    ///
    /// Sign is from the balance perspective; callers flip for liabilities via
    /// `dailyChangeIsGain(_:)`.
    func dailyChangePercent(using currency: CurrencyService) -> Double? {
        if type.supportsHoldings {
            var currentHoldings = 0.0
            var priorHoldings   = 0.0
            var hasReference    = false
            for h in holdings where h.previousClose > 0 {
                hasReference = true
                currentHoldings += currency.convert(Money(h.value, h.priceCurrency), to: self.currency).amount
                priorHoldings   += currency.convert(Money(h.previousClose * h.quantity, h.priceCurrency), to: self.currency).amount
            }
            guard hasReference else { return nil }
            // Express against the account's prior total (cash is static day-over-day).
            let base = priorHoldings + cashBalance
            guard base > 0 else { return nil }
            let pct = (currentHoldings - priorHoldings) / base
            return pct == 0 ? nil : pct
        } else {
            let startOfToday = Calendar.current.startOfDay(for: Date())
            guard let yesterday = balanceHistory
                    .filter({ $0.recordedAt < startOfToday })
                    .max(by: { $0.recordedAt < $1.recordedAt })?.balance,
                  yesterday != 0 else { return nil }
            let pct = (currentBalance - yesterday) / abs(yesterday)
            return pct == 0 ? nil : pct
        }
    }

    /// Interpret a change as a gain (true = green) or loss (false = red).
    /// Assets: up = gain. Liabilities: down (debt paid off) = gain.
    func dailyChangeIsGain(_ change: Double) -> Bool {
        isLiability ? change <= 0 : change >= 0
    }

    /// For brokerage accounts, balance = sum of holdings converted to account currency + cash.
    /// Pass a `convert` closure to apply FX; defaults to no conversion (same-currency assumption).
    func recomputeBalance(convert: (Double, String, String) -> Double = { amount, _, _ in amount }) {
        guard type.supportsHoldings else { return }
        // A holdings-capable account with NO holdings (e.g. a pension tracked as
        // a single value) keeps its value in `currentBalance`/`cashBalance`.
        // Never zero it out from an empty holdings list — that wipes manually
        // entered balances.
        guard !holdings.isEmpty else {
            if cashBalance > 0 { currentBalance = cashBalance }
            return
        }
        currentBalance = holdings.reduce(0) { sum, holding in
            sum + convert(holding.value, holding.priceCurrency, currency)
        } + cashBalance
    }

    /// Sync `currentBalance` to the most recent snapshot for manual (non-holdings)
    /// accounts, so the displayed "current" value never drifts from the account's
    /// own history. Without this, editing history (which only writes snapshots)
    /// leaves `currentBalance` stale — surfacing as a bogus daily-change % and a
    /// wrong dashboard total. No-op for holdings accounts (their balance is driven
    /// by live prices) and when already in sync. Returns true if it changed anything.
    @discardableResult
    func reconcileCurrentBalanceWithHistory() -> Bool {
        guard !type.supportsHoldings else { return false }
        guard let latest = balanceHistory.max(by: { $0.recordedAt < $1.recordedAt }) else { return false }
        guard abs(currentBalance - latest.balance) > 0.001 else { return false }
        currentBalance = latest.balance
        updatedAt = latest.recordedAt
        return true
    }

    /// Upsert a balance snapshot for the calendar day containing `date`. We
    /// keep **at most one snapshot per day per account** — if an entry for
    /// that day already exists, its `balance` and `recordedAt` are updated in
    /// place; otherwise a fresh snapshot is appended. Single entry point so
    /// every callsite that records a balance (manual edit, ticker refresh,
    /// historical entry) gets the same dedupe semantics.
    ///
    /// Returns the snapshot that ended up representing the day.
    @discardableResult
    func setBalanceSnapshot(balance: Double, at date: Date = Date()) -> BalanceSnapshot {
        let calendar = Calendar.current
        if let existing = balanceHistory.first(where: {
            calendar.isDate($0.recordedAt, inSameDayAs: date)
        }) {
            existing.balance = balance
            // Bump the timestamp so "latest" ordering reflects this update.
            existing.recordedAt = date
            return existing
        }
        let fresh = BalanceSnapshot(balance: balance, recordedAt: date)
        // SwiftData auto-inserts relationship children — no explicit insert (Rule #5).
        balanceHistory.append(fresh)
        return fresh
    }

    /// One-time backfill: collapse any calendar days with multiple snapshots
    /// down to the most recent one. Returns the number of rows deleted so the
    /// caller can decide whether to save. Idempotent.
    @discardableResult
    func consolidateDailyHistory(in context: ModelContext) -> Int {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: balanceHistory) {
            calendar.startOfDay(for: $0.recordedAt)
        }
        var deleted = 0
        for (_, dayGroup) in grouped where dayGroup.count > 1 {
            // Keep the most recently recorded; delete the rest.
            let sorted = dayGroup.sorted { $0.recordedAt > $1.recordedAt }
            for stale in sorted.dropFirst() {
                context.delete(stale)
                deleted += 1
            }
        }
        return deleted
    }

    init(name: String, type: AccountType, balance: Double, institution: String = "", currency: String = "USD") {
        self.id = UUID()
        self.name = name
        self.typeRaw = type.rawValue
        self.currentBalance = balance
        self.institution = institution
        self.currency = currency
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Snapshots

@Model
final class BalanceSnapshot {
    var id: UUID = UUID()
    var balance: Double = 0.0
    var recordedAt: Date = Date()

    init(balance: Double, recordedAt: Date = Date()) {
        self.id = UUID()
        self.balance = balance
        self.recordedAt = recordedAt
    }
}

@Model
final class NetWorthSnapshot {
    var id: UUID = UUID()
    var netWorth: Double = 0.0
    var totalAssets: Double = 0.0
    var totalLiabilities: Double = 0.0
    var currency: String = "USD"
    var recordedAt: Date = Date()

    init(netWorth: Double, totalAssets: Double, totalLiabilities: Double, currency: String = "USD", recordedAt: Date = Date()) {
        self.id = UUID()
        self.netWorth = netWorth
        self.totalAssets = totalAssets
        self.totalLiabilities = totalLiabilities
        self.currency = currency
        self.recordedAt = recordedAt
    }
}

// MARK: - ModelContext helpers

extension ModelContext {
    /// Record a net worth snapshot using proper multi-currency conversion.
    /// Call this whenever account balances change (save, delete, ticker refresh).
    func recordNetWorthSnapshot(currency: CurrencyService, at date: Date = Date()) {
        let accounts = (try? fetch(FetchDescriptor<Account>())) ?? []
        let base = currency.baseCurrency
        let assets = currency.sum(
            accounts.filter { !$0.isLiability }.map { Money($0.currentBalance, $0.currency) },
            in: base
        ).amount
        let liabilities = currency.sum(
            accounts.filter { $0.isLiability }.map { Money($0.currentBalance, $0.currency) },
            in: base
        ).amount
        insert(NetWorthSnapshot(
            netWorth: assets - liabilities,
            totalAssets: assets,
            totalLiabilities: liabilities,
            currency: base,
            recordedAt: date
        ))
    }

    /// Repair any manual accounts whose `currentBalance` has drifted from their
    /// latest snapshot (e.g. after editing history, which only writes snapshots).
    /// Idempotent — saves only when something actually changed. Call after any
    /// snapshot mutation and once when the dashboard loads (to fix legacy data).
    func reconcileAccountBalances() {
        let accounts = (try? fetch(FetchDescriptor<Account>())) ?? []
        var changed = false
        for account in accounts where account.reconcileCurrentBalanceWithHistory() {
            changed = true
        }
        if changed { try? save() }
    }

    /// One-time backfill across every account: collapse multi-snapshot days
    /// down to one row per day, keeping the most recent. Safe to call on
    /// every launch — does nothing once history is already clean.
    @discardableResult
    func consolidateAllDailyHistory() -> Int {
        let accounts = (try? fetch(FetchDescriptor<Account>())) ?? []
        var total = 0
        for account in accounts {
            total += account.consolidateDailyHistory(in: self)
        }
        if total > 0 { try? save() }
        return total
    }

}

// MARK: - Formatting helpers

// MARK: - Cached number formatters
//
// NumberFormatter instantiation costs ~1–2ms and `Double.currencyFormatted` is
// called dozens of times per render across the app (ForEach rows × multiple
// values per row). Caching by (code, fractionDigits) keeps tap-to-keyboard
// hangs and scroll jank away — see CLAUDE.md "Performance" notes.
private enum CurrencyFormatterCache {
    private static let lock = NSLock()
    private static var cache: [String: NumberFormatter] = [:]

    static func formatter(code: String, fractionDigits: Int) -> NumberFormatter {
        let key = "\(code)|\(fractionDigits)"
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[key] { return existing }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.minimumFractionDigits = fractionDigits
        f.maximumFractionDigits = fractionDigits
        cache[key] = f
        return f
    }
}

extension Double {
    func currencyFormatted(code: String = "USD", fractionDigits: Int = 0) -> String {
        let formatter = CurrencyFormatterCache.formatter(code: code, fractionDigits: fractionDigits)
        return formatter.string(from: NSNumber(value: self)) ?? "$0"
    }
}
