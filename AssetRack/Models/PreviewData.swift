import Foundation
import SwiftData

extension ModelContainer {
    static let schema = Schema([Account.self, Holding.self, BalanceSnapshot.self, NetWorthSnapshot.self, ProjectionSettings.self])

    @MainActor
    static var previewContainer: ModelContainer = {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        seedSampleData(into: container.mainContext)
        return container
    }()

    /// Fresh, isolated store for a demo session. In-memory, and explicitly out
    /// of CloudKit so sample data can never sync to the user's iCloud.
    @MainActor
    static func makeDemoContainer() throws -> ModelContainer {
        let config = ModelConfiguration("Demo", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        seedSampleData(into: container.mainContext)
        try container.mainContext.save()
        return container
    }

    /// Made-up accounts with two years of history, ending today so daily badges
    /// and period deltas all have something to show. Deterministic: the demo
    /// looks the same every time, and institution names are fictional.
    @MainActor
    static func seedSampleData(into ctx: ModelContext) {
        let currency = CurrencyService(demoBaseCurrency: DemoMarket.baseCurrency)
        let calendar = Calendar.current
        let now = Date()

        // Monthly going back two years, tightening to daily over the last week.
        let dayOffsets = Array(stride(from: 720, to: 28, by: -30)) + [28, 21, 14, 7, 6, 5, 4, 3, 2, 1, 0]

        // `drift` is the balance's annual change; `wobble` adds movement around
        // that trend. Both vanish at day 0, so today's value is exactly `balance`.
        func value(of balance: Double, drift: Double, wobble: Double, daysAgo: Int) -> Double {
            let days = Double(daysAgo)
            return (balance * (1 - drift * days / 365 + wobble * sin(days / 3))).rounded()
        }

        let simpleAccounts: [(name: String, type: AccountType, balance: Double, institution: String, currency: String, drift: Double, wobble: Double)] = [
            ("Everyday Checking", .checking,   8_450,   "Northwind Bank",      "USD", 0.05,  0.06),
            ("High-Yield Savings", .savings,   42_300,  "Northwind Bank",      "USD", 0.18,  0.005),
            ("Euro Savings",      .savings,    12_500,  "Alpine Bank",         "EUR", 0.10,  0.004),
            ("Primary Residence", .realEstate, 640_000, "",                    "USD", 0.04,  0.001),
            ("Retirement Plan",   .pension,    186_000, "Summit Retirement",   "USD", 0.14,  0.01),
            ("Home Mortgage",     .mortgage,   418_000, "Northwind Bank",      "USD", -0.03, 0),
            ("Rewards Card",      .creditCard, 2_180,   "Northwind Bank",      "USD", 0,     0.25),
            ("Car Loan",          .loan,       11_600,  "Summit Credit Union", "USD", -0.22, 0),
        ]

        var series: [(account: Account, value: (Int) -> Double)] = []
        for entry in simpleAccounts {
            let account = Account(name: entry.name, type: entry.type, balance: entry.balance,
                                  institution: entry.institution, currency: entry.currency)
            ctx.insert(account)
            series.append((account, { value(of: entry.balance, drift: entry.drift, wobble: entry.wobble, daysAgo: $0) }))
        }

        // Brokerage account with holdings + cash
        let brokerage = Account(name: "Long-Term Portfolio", type: .brokerage, balance: 0, institution: "Harbor Brokerage")
        ctx.insert(brokerage)

        let holdings: [(symbol: String, quantity: Double, source: PriceSource)] = [
            ("VOO",  40,  .yahooFinance),
            ("AAPL", 60,  .yahooFinance),
            ("MSFT", 25,  .yahooFinance),
            ("VWCE", 120, .tradegate),
        ]
        for entry in holdings {
            let isin = DemoMarket.securities.first { $0.symbol == entry.symbol }?.isin ?? ""
            let quote = DemoMarket.quote(symbol: entry.symbol, isin: isin, source: entry.source)
            let holding = Holding(tickerSymbol: entry.symbol, quantity: entry.quantity, priceSource: entry.source, isin: isin)
            holding.lastPrice = quote.price
            holding.previousClose = quote.previousClose
            holding.priceCurrency = quote.currency
            holding.lastPriceFetchedAt = now
            brokerage.holdings.append(holding)
        }
        brokerage.cashBalance = 3_200
        brokerage.costBasis = 52_000
        brokerage.recomputeBalance(convert: currency.convert)
        let brokerageBalance = brokerage.currentBalance
        series.append((brokerage, { value(of: brokerageBalance, drift: 0.2, wobble: 0.03, daysAgo: $0) }))

        // Per-account history, plus the net-worth trail for the same dates.
        // Written directly because `recordNetWorthSnapshot` reads live balances
        // (and pushes to the widget), which can't describe a past date.
        for daysAgo in dayOffsets {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            var assets: [Money] = []
            var liabilities: [Money] = []
            for (account, value) in series {
                let balance = value(daysAgo)
                account.setBalanceSnapshot(balance: balance, at: date)
                if account.isLiability {
                    liabilities.append(Money(balance, account.currency))
                } else {
                    assets.append(Money(balance, account.currency))
                }
            }
            let totalAssets = currency.sum(assets, in: currency.baseCurrency).amount
            let totalLiabilities = currency.sum(liabilities, in: currency.baseCurrency).amount
            ctx.insert(NetWorthSnapshot(
                netWorth: totalAssets - totalLiabilities,
                totalAssets: totalAssets,
                totalLiabilities: totalLiabilities,
                currency: currency.baseCurrency,
                recordedAt: date
            ))
        }

        let start = calendar.date(byAdding: .day, value: -(dayOffsets.first ?? 0), to: now)!
        for (account, _) in series { account.createdAt = start }

        let projection = ctx.projectionSettings()
        projection.monthlyIncome = 8_500
        projection.monthlyExpenses = 5_900
    }
}
