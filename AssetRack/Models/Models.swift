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

    var supportsHoldings: Bool { self == .brokerage }

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

    var value: Double { lastPrice * quantity }

    var priceSource: PriceSource {
        get { PriceSource(rawValue: priceSourceRaw) ?? .yahooFinance }
        set { priceSourceRaw = newValue.rawValue }
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

    /// For brokerage accounts, balance = sum of holdings converted to account currency + cash.
    /// Pass a `convert` closure to apply FX; defaults to no conversion (same-currency assumption).
    func recomputeBalance(convert: (Double, String, String) -> Double = { amount, _, _ in amount }) {
        guard type.supportsHoldings else { return }
        currentBalance = holdings.reduce(0) { sum, holding in
            sum + convert(holding.value, holding.priceCurrency, currency)
        } + cashBalance
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
