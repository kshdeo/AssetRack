import Foundation
import SwiftData
import Testing
@testable import AssetRack

// MARK: - AccountType

@Suite("AccountType")
struct AccountTypeTests {
    @Test func categoryMapping() {
        #expect(AccountType.checking.category   == .cashAndBank)
        #expect(AccountType.savings.category    == .cashAndBank)
        #expect(AccountType.brokerage.category  == .investments)
        #expect(AccountType.pension.category    == .pension)
        #expect(AccountType.realEstate.category == .realEstate)
        #expect(AccountType.mortgage.category   == .liabilities)
        #expect(AccountType.creditCard.category == .liabilities)
        #expect(AccountType.loan.category       == .liabilities)
    }

    @Test func liabilityFlags() {
        let liabilities: Set<AccountType> = [.mortgage, .creditCard, .loan]
        for type in AccountType.allCases {
            #expect(type.isLiability == liabilities.contains(type))
        }
    }

    @Test func holdingsSupport() {
        let supported: Set<AccountType> = [.brokerage, .pension]
        for type in AccountType.allCases {
            #expect(type.supportsHoldings == supported.contains(type))
        }
    }
}

// MARK: - Holding

@Suite("Holding")
struct HoldingTests {
    @Test func valueIsPriceTimesQuantity() {
        let h = makeHolding(quantity: 10, lastPrice: 48.5)
        expectClose(h.value, 485)
    }

    @Test func initNormalizesTicker() {
        let h = Holding(tickerSymbol: "  voo ", quantity: 1)
        #expect(h.tickerSymbol == "VOO")
    }

    @Test func unknownPriceSourceFallsBackToYahoo() {
        let h = makeHolding(quantity: 1, lastPrice: 1)
        h.priceSourceRaw = "bogus"
        #expect(h.priceSource == .yahooFinance)
    }

    @Test func dailyChangeNilWithoutPreviousClose() {
        let h = makeHolding(quantity: 1, lastPrice: 100, previousClose: 0)
        #expect(h.dailyChangePercent == nil)
    }

    @Test func dailyChangeNilWhenUnchanged() {
        let h = makeHolding(quantity: 1, lastPrice: 100, previousClose: 100)
        #expect(h.dailyChangePercent == nil)
    }

    @Test func dailyChangePositiveAndNegative() {
        expectClose(makeHolding(quantity: 1, lastPrice: 110, previousClose: 100).dailyChangePercent, 0.1)
        expectClose(makeHolding(quantity: 1, lastPrice: 90, previousClose: 100).dailyChangePercent, -0.1)
    }
}

// MARK: - Account basics

@Suite("Account basics")
struct AccountBasicsTests {
    @Test func signedBalanceForAsset() {
        let account = Account(name: "A", type: .checking, balance: 100)
        expectClose(account.signedBalance, 100)
    }

    @Test func signedBalanceForLiability() {
        let account = Account(name: "M", type: .mortgage, balance: 100)
        expectClose(account.signedBalance, -100)
    }

    @Test func unknownTypeRawFallsBackToChecking() {
        let account = Account(name: "A", type: .savings, balance: 0)
        account.typeRaw = "bogus"
        #expect(account.type == .checking)
    }

    @Test func gainInterpretationForAsset() {
        let asset = Account(name: "A", type: .checking, balance: 0)
        #expect(asset.dailyChangeIsGain(5))
        #expect(!asset.dailyChangeIsGain(-5))
        #expect(asset.dailyChangeIsGain(0))
    }

    @Test func netProfitLossRequiresACostBasis() {
        let account = Account(name: "B", type: .brokerage, balance: 1_200)
        #expect(account.netProfitLoss == nil) // costBasis unset (0)
        account.costBasis = 1_000
        expectClose(account.netProfitLoss, 200)
        account.costBasis = 1_500
        expectClose(account.netProfitLoss, -300)
    }

    @Test func gainInterpretationForLiability() {
        let mortgage = Account(name: "M", type: .mortgage, balance: 0)
        #expect(mortgage.dailyChangeIsGain(-5))  // debt paid off = gain
        #expect(!mortgage.dailyChangeIsGain(5))
        #expect(mortgage.dailyChangeIsGain(0))
    }
}

// MARK: - setBalanceSnapshot

@Suite("setBalanceSnapshot")
struct SetBalanceSnapshotTests {
    let container: ModelContainer
    let context: ModelContext
    init() { (container, context) = makeContext() }

    @Test func appendsFreshSnapshot() {
        let account = makeAccount(in: context, balance: 100)
        account.setBalanceSnapshot(balance: 100)
        #expect(account.balanceHistory.count == 1)
        expectClose(account.balanceHistory[0].balance, 100)
    }

    @Test func upsertsSameDayInPlace() {
        let account = makeAccount(in: context, balance: 100)
        let first = account.setBalanceSnapshot(balance: 100)
        let second = account.setBalanceSnapshot(balance: 250)
        #expect(account.balanceHistory.count == 1)
        #expect(first === second)
        expectClose(first.balance, 250)
    }

    @Test func upsertBumpsRecordedAt() {
        let account = makeAccount(in: context, balance: 100)
        let morning = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)
        let noon = morning.addingTimeInterval(4 * 3600)
        account.setBalanceSnapshot(balance: 100, at: morning)
        let updated = account.setBalanceSnapshot(balance: 200, at: noon)
        #expect(updated.recordedAt == noon)
    }

    @Test func differentDaysGetSeparateRows() {
        let account = makeAccount(in: context, balance: 100)
        account.setBalanceSnapshot(balance: 90, at: daysAgo(1))
        account.setBalanceSnapshot(balance: 100, at: Date())
        #expect(account.balanceHistory.count == 2)
    }
}

// MARK: - reconcileCurrentBalanceWithHistory

@Suite("reconcileCurrentBalanceWithHistory")
struct ReconcileBalanceTests {
    let container: ModelContainer
    let context: ModelContext
    init() { (container, context) = makeContext() }

    @Test func syncsToLatestSnapshot() {
        let account = makeAccount(in: context, balance: 400,
                                  history: [(500, daysAgo(1)), (450, daysAgo(3))])
        #expect(account.reconcileCurrentBalanceWithHistory())
        expectClose(account.currentBalance, 500)
    }

    @Test func noOpForHoldingsAccounts() {
        let account = makeAccount(in: context, type: .brokerage, balance: 400,
                                  history: [(500, daysAgo(1))])
        #expect(!account.reconcileCurrentBalanceWithHistory())
        expectClose(account.currentBalance, 400)
    }

    @Test func noOpWithoutHistory() {
        let account = makeAccount(in: context, balance: 400)
        #expect(!account.reconcileCurrentBalanceWithHistory())
    }

    @Test func noOpWhenAlreadyInSync() {
        let account = makeAccount(in: context, balance: 500,
                                  history: [(500, daysAgo(1))])
        #expect(!account.reconcileCurrentBalanceWithHistory())
    }
}

// MARK: - recomputeBalance

@Suite("recomputeBalance")
struct RecomputeBalanceTests {
    let container: ModelContainer
    let context: ModelContext
    init() { (container, context) = makeContext() }

    @Test func sumsHoldingsPlusCash() {
        let account = makeAccount(in: context, type: .brokerage, balance: 0, cash: 200,
                                  holdings: [makeHolding(quantity: 10, lastPrice: 50),
                                             makeHolding(symbol: "AAPL", quantity: 2, lastPrice: 150)])
        account.recomputeBalance()
        expectClose(account.currentBalance, 500 + 300 + 200)
    }

    @Test func emptyHoldingsPreservesManualBalanceViaCash() {
        // A pension tracked as a single value: never zero out from an empty list.
        let account = makeAccount(in: context, type: .pension, balance: 900, cash: 1_000)
        account.recomputeBalance()
        expectClose(account.currentBalance, 1_000)
    }

    @Test func emptyHoldingsAndZeroCashLeavesBalanceUntouched() {
        let account = makeAccount(in: context, type: .pension, balance: 900)
        account.recomputeBalance()
        expectClose(account.currentBalance, 900)
    }

    @Test func noOpForManualAccounts() {
        let account = makeAccount(in: context, type: .checking, balance: 750,
                                  holdings: [makeHolding(quantity: 1, lastPrice: 999)])
        account.recomputeBalance()
        expectClose(account.currentBalance, 750)
    }

    @Test func appliesConvertClosure() {
        // Holding priced in USD, account in GBP: 1270 USD -> 1000 GBP.
        let account = makeAccount(in: context, type: .brokerage, balance: 0,
                                  holdings: [makeHolding(quantity: 1, lastPrice: 1_270,
                                                         priceCurrency: "USD")])
        account.recomputeBalance { amount, from, to in
            from == to ? amount : amount / 1.27
        }
        expectClose(account.currentBalance, 1_000)
    }
}

// MARK: - dailyChangePercent

@Suite("dailyChangePercent")
struct DailyChangePercentTests {
    let container: ModelContainer
    let context: ModelContext
    init() { (container, context) = makeContext() }

    @Test func comparesAgainstYesterday() {
        let account = makeAccount(in: context, balance: 1_100,
                                  history: [(1_000, daysAgo(1))])
        expectClose(account.dailyChangePercent(), 0.1)
    }

    @Test func mostRecentPreTodaySnapshotWins() {
        let account = makeAccount(in: context, balance: 1_100,
                                  history: [(900, daysAgo(3)), (1_000, daysAgo(1))])
        expectClose(account.dailyChangePercent(), 0.1)
    }

    @Test func holdingsAccountsUseTheSnapshotBaseline() {
        // Snapshot baseline (1000), NOT previousClose (90 * 10 = 900, which
        // would give ~22%) — per-market session closes anchor at different
        // times of day and misalign mixed-market portfolios.
        let account = makeAccount(in: context, type: .brokerage, balance: 1_100,
                                  history: [(1_000, daysAgo(1))],
                                  holdings: [makeHolding(quantity: 10, lastPrice: 110, previousClose: 90)])
        expectClose(account.dailyChangePercent(), 0.1)
    }

    @Test func holdingsAccountWithoutHistoryIsNil() {
        let account = makeAccount(in: context, type: .brokerage, balance: 1_100,
                                  holdings: [makeHolding(quantity: 10, lastPrice: 110, previousClose: 100)])
        #expect(account.dailyChangePercent() == nil)
    }

    @Test func todaysSnapshotIsNotAReference() {
        // Only history from today -> nothing recorded strictly before today -> nil.
        let account = makeAccount(in: context, balance: 1_100,
                                  history: [(1_000, Date())])
        #expect(account.dailyChangePercent() == nil)
    }

    @Test func nilWithoutHistory() {
        let account = makeAccount(in: context, balance: 1_100)
        #expect(account.dailyChangePercent() == nil)
    }

    @Test func nilWhenYesterdayWasZero() {
        let account = makeAccount(in: context, balance: 1_100,
                                  history: [(0, daysAgo(1))])
        #expect(account.dailyChangePercent() == nil)
    }

    @Test func nilWhenUnchanged() {
        let account = makeAccount(in: context, balance: 1_000,
                                  history: [(1_000, daysAgo(1))])
        #expect(account.dailyChangePercent() == nil)
    }

    @Test func negativeChangeKeepsBalanceSign() {
        // Sign is from the balance perspective even for liabilities;
        // callers flip via dailyChangeIsGain.
        let account = makeAccount(in: context, type: .mortgage, balance: 900,
                                  history: [(1_000, daysAgo(1))])
        expectClose(account.dailyChangePercent(), -0.1)
    }
}

// MARK: - consolidateDailyHistory

@Suite("consolidateDailyHistory")
struct ConsolidateHistoryTests {
    let container: ModelContainer
    let context: ModelContext
    init() { (container, context) = makeContext() }

    @Test func collapsesMultiRowDaysKeepingNewest() throws {
        let account = makeAccount(in: context, balance: 300)
        let dayStart = Calendar.current.startOfDay(for: Date())
        for (hour, balance) in [(1, 100.0), (2, 200.0), (3, 300.0)] {
            account.balanceHistory.append(
                BalanceSnapshot(balance: balance, recordedAt: dayStart.addingTimeInterval(Double(hour) * 3600))
            )
        }
        let deleted = account.consolidateDailyHistory(in: context)
        try context.save()
        #expect(deleted == 2)
        #expect(account.balanceHistory.count == 1)
        expectClose(account.balanceHistory.first?.balance, 300)
    }

    @Test func idempotentOnCleanHistory() throws {
        let account = makeAccount(in: context, balance: 100,
                                  history: [(90, daysAgo(2)), (100, daysAgo(1))])
        #expect(account.consolidateDailyHistory(in: context) == 0)
    }
}

// MARK: - NetWorthMath

@Suite("NetWorthMath")
struct NetWorthMathTests {
    let container: ModelContainer
    let context: ModelContext
    let currency = makeCurrency()
    init() { (container, context) = makeContext() }

    @Test func netsAssetGainAndDebtPaydown() {
        let cash = makeAccount(in: context, balance: 1_100, history: [(1_000, daysAgo(1))])
        let mortgage = makeAccount(in: context, type: .mortgage, balance: 400,
                                   history: [(500, daysAgo(1))])
        // +100 asset gain, +100 debt paid off -> +200 net worth
        expectClose(NetWorthMath.todaysChange(accounts: [cash, mortgage], currency: currency), 200)
    }

    @Test func accountAddedTodayCountsFully() {
        let existing = makeAccount(in: context, balance: 1_000, history: [(1_000, daysAgo(1))])
        let fresh = makeAccount(in: context, balance: 500) // no pre-today history
        expectClose(NetWorthMath.todaysChange(accounts: [existing, fresh], currency: currency), 500)
    }

    @Test func convertsMixedCurrenciesAtCurrentRates() {
        // USD account: yesterday 1270 USD (= 1000 GBP), today 2540 USD (= 2000 GBP)
        let usd = makeAccount(in: context, balance: 2_540, currency: "USD",
                              history: [(1_270, daysAgo(1))])
        expectClose(NetWorthMath.todaysChange(accounts: [usd], currency: currency), 1_000)
    }

    @Test func todaysSnapshotIsNotABaseline() {
        // Only history from today -> previous side is empty -> full balance is the change.
        let account = makeAccount(in: context, balance: 1_100, history: [(900, Date())])
        expectClose(NetWorthMath.todaysChange(accounts: [account], currency: currency), 1_100)
    }
}

// MARK: - ModelContext helpers

@Suite("ModelContext helpers")
struct ModelContextHelperTests {
    let container: ModelContainer
    let context: ModelContext
    let currency = makeCurrency()
    init() { (container, context) = makeContext() }

    @Test func recordNetWorthSnapshotConvertsAndSigns() throws {
        makeAccount(in: context, name: "GBP cash", balance: 1_000)
        makeAccount(in: context, name: "USD cash", balance: 1_270, currency: "USD") // = 1000 GBP
        makeAccount(in: context, name: "Mortgage", type: .mortgage, balance: 500)
        context.recordNetWorthSnapshot(currency: currency)

        let snapshots = try context.fetch(FetchDescriptor<NetWorthSnapshot>())
        let snap = try #require(snapshots.first)
        #expect(snapshots.count == 1)
        #expect(snap.currency == "GBP")
        expectClose(snap.totalAssets, 2_000)
        expectClose(snap.totalLiabilities, 500)
        expectClose(snap.netWorth, 1_500)
    }

    @Test func recordNetWorthSnapshotUpsertsSameDay() throws {
        makeAccount(in: context, balance: 1_000)
        context.recordNetWorthSnapshot(currency: currency)
        context.recordNetWorthSnapshot(currency: currency)

        let snapshots = try context.fetch(FetchDescriptor<NetWorthSnapshot>())
        #expect(snapshots.count == 1)
    }

    @Test func consolidateNetWorthHistoryCollapsesLegacyRows() throws {
        let dayStart = Calendar.current.startOfDay(for: Date())
        for hour in 1...3 {
            context.insert(NetWorthSnapshot(
                netWorth: Double(hour) * 100, totalAssets: Double(hour) * 100,
                totalLiabilities: 0, currency: "GBP",
                recordedAt: dayStart.addingTimeInterval(Double(hour) * 3600)
            ))
        }
        try context.save()
        #expect(context.consolidateNetWorthHistory() == 2)
        let remaining = try context.fetch(FetchDescriptor<NetWorthSnapshot>())
        #expect(remaining.count == 1)
        expectClose(remaining.first?.netWorth, 300) // newest row kept
    }

    @Test func reconcileAccountBalancesRepairsDrift() throws {
        let account = makeAccount(in: context, balance: 400,
                                  history: [(500, daysAgo(1))])
        try context.save()
        context.reconcileAccountBalances()
        expectClose(account.currentBalance, 500)
    }

    @Test func consolidateAllDailyHistoryReportsDeletions() throws {
        let account = makeAccount(in: context, balance: 200)
        let dayStart = Calendar.current.startOfDay(for: Date())
        account.balanceHistory.append(BalanceSnapshot(balance: 100, recordedAt: dayStart.addingTimeInterval(3600)))
        account.balanceHistory.append(BalanceSnapshot(balance: 200, recordedAt: dayStart.addingTimeInterval(7200)))
        try context.save()
        #expect(context.consolidateAllDailyHistory() == 1)
        #expect(account.balanceHistory.count == 1)
    }
}
