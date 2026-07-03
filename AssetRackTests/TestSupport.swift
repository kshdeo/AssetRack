import Foundation
import SwiftData
import Testing
@testable import AssetRack

// Base currency GBP; rates are "how many X per 1 GBP" (same convention as
// CurrencyServiceTests): 1 GBP = 1.27 USD = 1.17 EUR.
let sharedTestRates: [String: Double] = ["USD": 1.27, "EUR": 1.17]

func makeCurrency() -> CurrencyService {
    CurrencyService(baseCurrency: "GBP", rates: sharedTestRates)
}

/// Fresh in-memory SwiftData stack. Keep the container alive for the duration
/// of the test — suites store both so the context stays valid.
func makeContext() -> (container: ModelContainer, context: ModelContext) {
    let config = ModelConfiguration(schema: ModelContainer.schema, isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: ModelContainer.schema, configurations: [config])
    return (container, ModelContext(container))
}

func daysAgo(_ days: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: -days, to: Date())!
}

// MARK: - Factories

func makeHolding(symbol: String = "VOO",
                 quantity: Double,
                 lastPrice: Double,
                 previousClose: Double = 0,
                 priceCurrency: String = "GBP",
                 fetchedAt: Date? = nil) -> Holding {
    let h = Holding(tickerSymbol: symbol, quantity: quantity)
    h.lastPrice = lastPrice
    h.previousClose = previousClose
    h.priceCurrency = priceCurrency
    h.lastPriceFetchedAt = fetchedAt
    return h
}

/// Insert an account with optional history and holdings. Children are appended
/// after the parent is inserted — SwiftData auto-inserts them (CLAUDE.md rule #5).
@discardableResult
func makeAccount(in context: ModelContext,
                 name: String = "Account",
                 type: AccountType = .checking,
                 balance: Double,
                 currency: String = "GBP",
                 cash: Double = 0,
                 history: [(balance: Double, date: Date)] = [],
                 holdings: [Holding] = []) -> Account {
    let account = Account(name: name, type: type, balance: balance, currency: currency)
    context.insert(account)
    account.cashBalance = cash
    for holding in holdings {
        account.holdings.append(holding)
    }
    for entry in history {
        account.balanceHistory.append(BalanceSnapshot(balance: entry.balance, recordedAt: entry.date))
    }
    return account
}

// MARK: - Assertions

/// Compare doubles with tolerance; records a failure at the call site.
func expectClose(_ actual: Double?,
                 _ expected: Double,
                 tolerance: Double = 1e-6,
                 sourceLocation: SourceLocation = #_sourceLocation) {
    guard let actual else {
        Issue.record("expected \(expected), got nil", sourceLocation: sourceLocation)
        return
    }
    #expect(abs(actual - expected) < tolerance,
            "expected \(expected), got \(actual)",
            sourceLocation: sourceLocation)
}
