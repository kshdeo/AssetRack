import Foundation
import SwiftData
import Testing
@testable import AssetRack

// Deliberately doesn't toggle `DemoMode.sessionActive`: it's process-wide and
// suites run in parallel, so these cover the demo paths that take an explicit
// flag or service instead.

@Suite("Demo sample data")
@MainActor
struct DemoSampleDataTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try ModelContainer.makeDemoContainer()
        context = container.mainContext
    }

    @Test func seedsEveryAccountType() throws {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        #expect(Set(accounts.map(\.type)) == Set(AccountType.allCases))
    }

    @Test func historyIsOnePerDayAndEndsAtCurrentBalance() throws {
        for account in try context.fetch(FetchDescriptor<Account>()) {
            let days = account.balanceHistory.map { Calendar.current.startOfDay(for: $0.recordedAt) }
            #expect(Set(days).count == days.count)
            let latest = account.balanceHistory.max { $0.recordedAt < $1.recordedAt }
            expectClose(latest?.balance, account.currentBalance, tolerance: 1)
        }
    }

    @Test func dashboardHasNonZeroTodaysChange() throws {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let currency = CurrencyService(demoBaseCurrency: DemoMarket.baseCurrency)
        #expect(NetWorthMath.todaysChange(accounts: accounts, currency: currency) != 0)
    }

    @Test func seedsNetWorthHistoryAndProjection() throws {
        #expect(try context.fetch(FetchDescriptor<NetWorthSnapshot>()).count > 12)
        #expect(context.projectionSettings().netMonthlySavings > 0)
    }

    @Test func eachContainerIsIsolated() throws {
        let account = try #require(try context.fetch(FetchDescriptor<Account>()).first)
        context.delete(account)
        try context.save()

        let other = try ModelContainer.makeDemoContainer()
        let original = try other.mainContext.fetch(FetchDescriptor<Account>()).count
        #expect(try context.fetch(FetchDescriptor<Account>()).count == original - 1)
    }
}

@Suite("Demo services")
struct DemoServiceTests {
    @Test func ratesAreConsistentAcrossBases() throws {
        let usd = DemoMarket.rates(base: "USD")
        let gbp = DemoMarket.rates(base: "GBP")
        let usdPerGBP = try #require(gbp["USD"])
        let gbpPerUSD = try #require(usd["GBP"])
        expectClose(usdPerGBP * gbpPerUSD, 1)
    }

    @Test func ratesCoverEveryCurrency() {
        for currency in Currency.allCases {
            #expect(DemoMarket.rates(base: currency.rawValue).count == Currency.allCases.count - 1)
        }
    }

    @Test func changingBaseCurrencyDoesNotTouchSavedSettings() {
        let saved = UserDefaults.standard.string(forKey: "fx_base_currency")
        let service = CurrencyService(demoBaseCurrency: "USD")
        service.baseCurrency = "EUR"
        #expect(UserDefaults.standard.string(forKey: "fx_base_currency") == saved)
        expectClose(service.convert(100, from: "EUR", to: "EUR"), 100)
        #expect(service.rates["USD"] != nil)
    }

    @Test func quotesAreStableForUnknownSymbols() {
        let first = DemoMarket.quote(symbol: "ZZZZ", isin: "", source: .yahooFinance)
        let second = DemoMarket.quote(symbol: "ZZZZ", isin: "", source: .yahooFinance)
        #expect(first.price == second.price)
        #expect(first.price > 0)
    }

    @Test func searchMatchesNameAndSymbol() {
        #expect(DemoMarket.search(query: "aapl").first?.symbol == "AAPL")
        #expect(DemoMarket.search(query: "microsoft").first?.symbol == "MSFT")
        #expect(DemoMarket.search(query: "no such company").isEmpty)
    }

    @Test @MainActor func tickerFetchUsesSamplePricesWithoutPersisting() async {
        let key = "ticker_last_fetched"
        let saved = UserDefaults.standard.object(forKey: key) as? Date
        let (container, context) = makeContext()
        defer { _ = container }
        let holding = makeHolding(symbol: "AAPL", quantity: 2, lastPrice: 1, priceCurrency: "USD")
        let account = makeAccount(in: context, type: .brokerage, balance: 2, currency: "USD", holdings: [holding])

        let ticker = TickerService(isDemo: true)
        await ticker.fetch(context: context, currency: CurrencyService(demoBaseCurrency: "USD"))

        let expected = DemoMarket.quote(symbol: "AAPL", isin: "", source: .yahooFinance).price
        expectClose(holding.lastPrice, expected)
        expectClose(account.currentBalance, expected * 2)
        #expect(ticker.lastFetched != nil)
        #expect(UserDefaults.standard.object(forKey: key) as? Date == saved)
    }
}
