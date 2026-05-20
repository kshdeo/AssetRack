import Foundation
import SwiftData

extension ModelContainer {
    static let schema = Schema([Account.self, Holding.self, BalanceSnapshot.self, NetWorthSnapshot.self])

    @MainActor
    static var previewContainer: ModelContainer = {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        let ctx = container.mainContext

        // Non-brokerage accounts
        let simpleAccounts: [(String, AccountType, Double, String)] = [
            ("Chase Checking",    .checking,   12_450,  "Chase"),
            ("Marcus Savings",    .savings,    38_200,  "Marcus"),
            ("Primary Residence", .realEstate, 680_000, ""),
            ("Chase Mortgage",    .mortgage,   312_500, "Chase"),
            ("Citi Credit Card",  .creditCard, 2_340,   "Citi"),
            ("Car Loan",          .loan,       8_750,   "Capital One"),
        ]

        for (name, type, balance, institution) in simpleAccounts {
            let account = Account(name: name, type: type, balance: balance, institution: institution)
            ctx.insert(account)

            for monthsAgo in (0..<12).reversed() {
                let date = Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date())!
                let jitter = balance * Double.random(in: -0.04...0.04)
                let snap = BalanceSnapshot(balance: balance + jitter, recordedAt: date)
                ctx.insert(snap)
                account.balanceHistory.append(snap)
            }
        }

        // Brokerage account with holdings + cash
        let brokerage = Account(name: "Fidelity Brokerage", type: .brokerage, balance: 0, institution: "Fidelity")
        ctx.insert(brokerage)

        let holdings: [(String, Double, Double)] = [
            ("VOO",  10,  485.0),
            ("AAPL", 15,  189.0),
            ("MSFT",  8,  415.0),
        ]
        for (symbol, qty, price) in holdings {
            let h = Holding(tickerSymbol: symbol, quantity: qty)
            h.lastPrice = price
            ctx.insert(h)
            brokerage.holdings.append(h)
        }
        brokerage.cashBalance = 3_200
        brokerage.recomputeBalance()

        // 12 months of net worth snapshots
        let baseNetWorth = 550_000.0
        for monthsAgo in (0..<12).reversed() {
            let date = Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date())!
            let growth = baseNetWorth * 0.008 * Double(12 - monthsAgo)
            let jitter = baseNetWorth * Double.random(in: -0.01...0.01)
            let nw = baseNetWorth + growth + jitter
            let snap = NetWorthSnapshot(
                netWorth: nw,
                totalAssets: nw + 323_590,
                totalLiabilities: 323_590,
                recordedAt: date
            )
            ctx.insert(snap)
        }

        return container
    }()

    static var appContainer: ModelContainer = {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
}
