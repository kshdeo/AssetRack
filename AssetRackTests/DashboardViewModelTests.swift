import Foundation
import SwiftData
import Testing
@testable import AssetRack

// All tests drive the public pipeline — recalculate(accounts:currency:) —
// and read the cached properties, exactly as the views do.
private func recalculated(_ accounts: [Account],
                          _ currency: CurrencyService = makeCurrency()) -> DashboardViewModel {
    let vm = DashboardViewModel()
    vm.recalculate(accounts: accounts, currency: currency)
    return vm
}

// MARK: - Totals

@Suite("Dashboard totals")
struct DashboardTotalsTests {
    let container: ModelContainer
    let context: ModelContext
    init() { (container, context) = makeContext() }

    @Test func mixedCurrencyTotals() {
        let accounts = [
            makeAccount(in: context, name: "GBP cash", balance: 1_000),
            makeAccount(in: context, name: "USD cash", balance: 1_270, currency: "USD"), // = 1000 GBP
            makeAccount(in: context, name: "Mortgage", type: .mortgage, balance: 500),
        ]
        let vm = recalculated(accounts)
        #expect(vm.netWorth.currency == "GBP")
        expectClose(vm.netWorth.amount, 1_500)
        expectClose(vm.totalAssets.amount, 2_000)
        expectClose(vm.totalLiabilities.amount, 500)
    }

    @Test func emptyAccountsGiveZeroTotals() {
        let vm = recalculated([])
        expectClose(vm.netWorth.amount, 0)
        #expect(vm.topMovers.isEmpty)
        #expect(vm.todaysGain == nil)
    }
}

// MARK: - Top movers

@Suite("Top movers")
struct TopMoversTests {
    let container: ModelContainer
    let context: ModelContext
    init() { (container, context) = makeContext() }

    @Test func sortedByAbsoluteChangeAndCappedAtThree() {
        // Changes: A +10.1, B +240, C -210, D +52.5 (pct * current balance).
        let a = makeAccount(in: context, name: "A", balance: 1_010, history: [(1_000, daysAgo(1))])
        let b = makeAccount(in: context, name: "B", balance: 1_200, history: [(1_000, daysAgo(1))])
        let c = makeAccount(in: context, name: "C", balance: 700,   history: [(1_000, daysAgo(1))])
        let d = makeAccount(in: context, name: "D", balance: 1_050, history: [(1_000, daysAgo(1))])
        let vm = recalculated([a, b, c, d])

        #expect(vm.topMovers.count == 3)
        #expect(vm.topMovers.map { $0.account.name } == ["B", "C", "D"])
        expectClose(vm.topMovers[0].changeAmount, 240)
        expectClose(vm.topMovers[1].changeAmount, -210)
    }

    @Test func excludesAccountsWithoutAnyChange() {
        let flat = makeAccount(in: context, balance: 1_000, history: [(1_000, daysAgo(1))])
        let fresh = makeAccount(in: context, balance: 1_000) // no history at all
        let vm = recalculated([flat, fresh])
        #expect(vm.topMovers.isEmpty)
    }

    @Test func excludesHoldingsAccountsWithStalePrices() {
        // Same holdings change, but prices last fetched two days ago (market closed).
        let stale = makeAccount(in: context, type: .brokerage, balance: 1_100,
                                holdings: [makeHolding(quantity: 10, lastPrice: 110,
                                                       previousClose: 100, fetchedAt: daysAgo(2))])
        let vm = recalculated([stale])
        #expect(vm.topMovers.isEmpty)
    }

    @Test func includesHoldingsAccountsFetchedToday() {
        let fresh = makeAccount(in: context, type: .brokerage, balance: 1_100,
                                holdings: [makeHolding(quantity: 10, lastPrice: 110,
                                                       previousClose: 100, fetchedAt: Date())])
        let vm = recalculated([fresh])
        #expect(vm.topMovers.count == 1)
        expectClose(vm.topMovers[0].changePercent, 0.1)
    }

    @Test func excludesHoldingsAccountsNeverFetched() {
        let never = makeAccount(in: context, type: .brokerage, balance: 1_100,
                                holdings: [makeHolding(quantity: 10, lastPrice: 110,
                                                       previousClose: 100, fetchedAt: nil)])
        let vm = recalculated([never])
        #expect(vm.topMovers.isEmpty)
    }

    @Test func topHoldingIsTheBiggestAbsoluteMover() throws {
        // VOO: (110-100)*10 = +100; AAPL: (80-100)*10 = -200 -> AAPL drives the move.
        let account = makeAccount(in: context, type: .brokerage, balance: 1_900,
                                  holdings: [makeHolding(symbol: "VOO", quantity: 10, lastPrice: 110,
                                                         previousClose: 100, fetchedAt: Date()),
                                             makeHolding(symbol: "AAPL", quantity: 10, lastPrice: 80,
                                                         previousClose: 100, fetchedAt: Date())])
        let vm = recalculated([account])
        let holding = try #require(vm.topMovers.first?.topHolding)
        #expect(holding.symbol == "AAPL")
        expectClose(holding.changeAmount, -200)
    }

    @Test func manualAccountsHaveNoTopHolding() throws {
        let cash = makeAccount(in: context, balance: 1_100, history: [(1_000, daysAgo(1))])
        let vm = recalculated([cash])
        #expect(try #require(vm.topMovers.first).topHolding == nil)
    }

    @Test func liabilityDecreaseIsAGain() throws {
        let mortgage = makeAccount(in: context, type: .mortgage, balance: 900,
                                   history: [(1_000, daysAgo(1))])
        let vm = recalculated([mortgage])
        let mover = try #require(vm.topMovers.first)
        #expect(mover.changeAmount < 0)
        #expect(mover.isGain)
    }
}

// MARK: - Today's gain

@Suite("Today's gain")
struct TodaysGainTests {
    let container: ModelContainer
    let context: ModelContext
    init() { (container, context) = makeContext() }

    @Test func nilWithoutPriorHistory() {
        let account = makeAccount(in: context, balance: 1_000)
        #expect(recalculated([account]).todaysGain == nil)
    }

    @Test func comparesTodayAgainstLatestSnapshot() throws {
        let account = makeAccount(in: context, balance: 1_100, history: [(1_000, daysAgo(1))])
        let gain = try #require(recalculated([account]).todaysGain)
        expectClose(gain.amount, 100)
        expectClose(gain.percent, 0.1)
    }

    @Test func liabilitySignsAreNetted() throws {
        // Asset flat, mortgage paid down 100 -> net worth up 100.
        let cash = makeAccount(in: context, balance: 2_000, history: [(2_000, daysAgo(1))])
        let mortgage = makeAccount(in: context, type: .mortgage, balance: 400,
                                   history: [(500, daysAgo(1))])
        let gain = try #require(recalculated([cash, mortgage]).todaysGain)
        expectClose(gain.amount, 100)
    }
}

// MARK: - Stacked history

@Suite("Stacked history")
struct StackedHistoryTests {
    let container: ModelContainer
    let context: ModelContext
    init() { (container, context) = makeContext() }

    private func total(on date: Date, in vm: DashboardViewModel) -> Double {
        let day = Calendar.current.startOfDay(for: date)
        return vm.stackedData.filter { $0.date == day }.map { $0.value }.reduce(0, +)
    }

    @Test func emptyWithoutAnySnapshots() {
        let account = makeAccount(in: context, balance: 1_000)
        #expect(recalculated([account]).stackedData.isEmpty)
    }

    @Test func carriesForwardAcrossMissingDays() {
        // A has a snapshot only at -2d; B only at -1d. On -1d, A's value carries forward.
        let a = makeAccount(in: context, name: "A", balance: 100, history: [(100, daysAgo(2))])
        let b = makeAccount(in: context, name: "B", type: .brokerage, balance: 50,
                            history: [(50, daysAgo(1))])
        let vm = recalculated([a, b])
        expectClose(total(on: daysAgo(2), in: vm), 100)
        expectClose(total(on: daysAgo(1), in: vm), 150)
    }

    @Test func todayUsesLiveBalance() {
        let account = makeAccount(in: context, balance: 1_100, history: [(1_000, daysAgo(1))])
        let vm = recalculated([account])
        expectClose(total(on: Date(), in: vm), 1_100)
    }

    @Test func liabilitiesAreExcluded() {
        let mortgage = makeAccount(in: context, type: .mortgage, balance: 500,
                                   history: [(500, daysAgo(1))])
        #expect(recalculated([mortgage]).stackedData.isEmpty)
    }
}

// MARK: - History entries

@Suite("History entries")
struct HistoryEntriesTests {
    let container: ModelContainer
    let context: ModelContext
    init() { (container, context) = makeContext() }

    @Test func descendingWithSyntheticTodayFirst() throws {
        let account = makeAccount(in: context, balance: 1_100, history: [(1_000, daysAgo(1))])
        let vm = recalculated([account])
        #expect(vm.historyEntries.count == 2)

        let today = try #require(vm.historyEntries.first)
        #expect(Calendar.current.isDateInToday(today.date))
        expectClose(today.rows.first?.balance, 1_100)
        #expect(today.rows.first?.isCarriedForward == true) // today is always synthetic

        let yesterday = vm.historyEntries[1]
        #expect(yesterday.rows.first?.isCarriedForward == false)
        expectClose(yesterday.rows.first?.balance, 1_000)
    }

    @Test func carriedForwardRowsAreFlagged() throws {
        let a = makeAccount(in: context, name: "A", balance: 100, history: [(100, daysAgo(2))])
        let b = makeAccount(in: context, name: "B", balance: 50, history: [(50, daysAgo(1))])
        let vm = recalculated([a, b])

        // Entry for -1d: B has a real snapshot, A is carried forward from -2d.
        let entry = try #require(vm.historyEntries.first {
            Calendar.current.isDate($0.date, inSameDayAs: daysAgo(1))
        })
        let rowA = try #require(entry.rows.first { $0.accountName == "A" })
        let rowB = try #require(entry.rows.first { $0.accountName == "B" })
        #expect(rowA.isCarriedForward)
        #expect(!rowB.isCarriedForward)
        expectClose(rowA.balance, 100)
    }

    @Test func liabilitiesSubtractFromDayTotal() throws {
        let cash = makeAccount(in: context, balance: 1_000, history: [(1_000, daysAgo(1))])
        let loan = makeAccount(in: context, type: .loan, balance: 300,
                               history: [(300, daysAgo(1))])
        let vm = recalculated([cash, loan])
        let today = try #require(vm.historyEntries.first)
        expectClose(today.totalInBase, 700)
    }
}

// MARK: - Allocation

@Suite("Allocation")
struct AllocationTests {
    let container: ModelContainer
    let context: ModelContext
    init() { (container, context) = makeContext() }

    @Test func segmentsAreSharesSortedDescending() {
        let cash = makeAccount(in: context, balance: 750)
        let brokerage = makeAccount(in: context, type: .brokerage, balance: 250)
        let vm = recalculated([cash, brokerage])

        #expect(vm.allocationSegments.count == 2)
        #expect(vm.allocationSegments[0].category == .cashAndBank)
        expectClose(vm.allocationSegments[0].value, 0.75)
        expectClose(vm.allocationSegments[1].value, 0.25)
        expectClose(vm.allocationSegments.map { $0.value }.reduce(0, +), 1.0)
    }

    @Test func emptyWithoutAssets() {
        let mortgage = makeAccount(in: context, type: .mortgage, balance: 500)
        #expect(recalculated([mortgage]).allocationSegments.isEmpty)
    }
}

// MARK: - Period deltas

@Suite("Period deltas")
struct PeriodDeltaTests {
    let container: ModelContainer
    let context: ModelContext
    init() { (container, context) = makeContext() }

    @Test func weekDeltaAgainstSevenDayOldSnapshot() {
        let account = makeAccount(in: context, balance: 1_100, history: [(1_000, daysAgo(7))])
        let vm = recalculated([account])
        expectClose(vm.weekDelta, 0.1)
    }

    @Test func monthDeltaAgainstThirtyDayOldSnapshot() {
        let account = makeAccount(in: context, balance: 1_100, history: [(1_000, daysAgo(30))])
        let vm = recalculated([account])
        expectClose(vm.monthDelta, 0.1)
        // Nearest date to the -7d anchor is today itself -> no distinct week reference.
        #expect(vm.weekDelta == nil)
    }

    @Test func nilWhenOnlyTodayExists() {
        let account = makeAccount(in: context, balance: 1_000, history: [(1_000, Date())])
        let vm = recalculated([account])
        #expect(vm.weekDelta == nil)
        #expect(vm.monthDelta == nil)
        #expect(vm.yearDelta == nil)
    }
}

// MARK: - History range & downsampling

@Suite("History range and downsampling")
struct HistoryRangeTests {
    let container: ModelContainer
    let context: ModelContext
    init() { (container, context) = makeContext() }

    @Test func longHistoryStaysUnderPointBudget() {
        let history = (1...400).map { (balance: 1_000.0 + Double($0), date: daysAgo($0)) }
        let account = makeAccount(in: context, balance: 2_000, history: history)
        let vm = DashboardViewModel()
        vm.recalculate(accounts: [account], currency: makeCurrency(), historyRange: .all)

        let dates = Set(vm.stackedData.map { $0.date })
        // +1 for the pinned earliest day
        #expect(dates.count <= DashboardViewModel.chartPointBudget + 1)
        #expect(dates.contains(Calendar.current.startOfDay(for: Date())))       // today kept
        #expect(dates.contains(Calendar.current.startOfDay(for: daysAgo(400)))) // earliest kept
    }

    @Test func shortHistoryIsNotThinned() {
        let account = makeAccount(in: context, balance: 1_100,
                                  history: [(1_000, daysAgo(2)), (1_050, daysAgo(1))])
        let vm = DashboardViewModel()
        vm.recalculate(accounts: [account], currency: makeCurrency(), historyRange: .all)
        #expect(Set(vm.stackedData.map { $0.date }).count == 3) // -2d, -1d, today
    }

    @Test func rangeFilterLimitsChartWindow() {
        let account = makeAccount(in: context, balance: 1_100,
                                  history: [(1_000, daysAgo(200)), (1_050, daysAgo(10))])
        let vm = DashboardViewModel()
        vm.recalculate(accounts: [account], currency: makeCurrency(), historyRange: .threeMonths)

        let dates = Set(vm.stackedData.map { $0.date })
        #expect(!dates.contains(Calendar.current.startOfDay(for: daysAgo(200))))
        #expect(dates.contains(Calendar.current.startOfDay(for: daysAgo(10))))
    }

    @Test func periodDeltasIgnoreChartRange() {
        // Chart shows 3 months, but y/y must still resolve from full history.
        let account = makeAccount(in: context, balance: 1_100,
                                  history: [(1_000, daysAgo(365))])
        let vm = DashboardViewModel()
        vm.recalculate(accounts: [account], currency: makeCurrency(), historyRange: .threeMonths)
        expectClose(vm.yearDelta, 0.1)
    }
}

// MARK: - Top accounts

@Suite("Top accounts")
struct TopAccountsTests {
    let container: ModelContainer
    let context: ModelContext
    init() { (container, context) = makeContext() }

    @Test func sortedByAbsoluteBalanceCappedAtFive() {
        let accounts = (1...6).map {
            makeAccount(in: context, name: "A\($0)", balance: Double($0 * 100))
        }
        let vm = recalculated(accounts)
        #expect(vm.topAccounts.count == 5)
        #expect(vm.topAccounts.first?.name == "A6")
        #expect(!vm.topAccounts.contains { $0.name == "A1" })
    }
}

// MARK: - dataKey

@Suite("dataKey")
struct DataKeyTests {
    let container: ModelContainer
    let context: ModelContext
    init() { (container, context) = makeContext() }

    @Test func stableForSameInputs() {
        let account = makeAccount(in: context, balance: 1_000, history: [(900, daysAgo(1))])
        let currency = makeCurrency()
        let key1 = DashboardViewModel.dataKey(accounts: [account], currency: currency)
        let key2 = DashboardViewModel.dataKey(accounts: [account], currency: currency)
        #expect(key1 == key2)
    }

    @Test func changesWhenBalanceChanges() {
        let account = makeAccount(in: context, balance: 1_000)
        let currency = makeCurrency()
        let before = DashboardViewModel.dataKey(accounts: [account], currency: currency)
        account.currentBalance = 1_001
        let after = DashboardViewModel.dataKey(accounts: [account], currency: currency)
        #expect(before != after)
    }

    @Test func changesWhenSnapshotAdded() {
        let account = makeAccount(in: context, balance: 1_000)
        let currency = makeCurrency()
        let before = DashboardViewModel.dataKey(accounts: [account], currency: currency)
        account.setBalanceSnapshot(balance: 1_000, at: daysAgo(1))
        let after = DashboardViewModel.dataKey(accounts: [account], currency: currency)
        #expect(before != after)
    }
}
