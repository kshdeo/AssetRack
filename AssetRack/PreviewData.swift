import Foundation
import SwiftData

extension ModelContainer {
    static let schema = Schema([Account.self, BalanceSnapshot.self, NetWorthSnapshot.self])

    @MainActor
    static var previewContainer: ModelContainer = {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        let ctx = container.mainContext

        let accounts: [(String, AccountType, Double, String)] = [
            ("Chase Checking",       .checking,   12_450,  "Chase"),
            ("Marcus Savings",       .savings,    38_200,  "Marcus"),
            ("Fidelity Brokerage",   .brokerage,  142_800, "Fidelity"),
            ("Primary Residence",    .realEstate, 680_000, ""),
            ("Chase Mortgage",       .mortgage,   312_500, "Chase"),
            ("Citi Credit Card",     .creditCard, 2_340,   "Citi"),
            ("Car Loan",             .loan,       8_750,   "Capital One"),
        ]

        var insertedAccounts: [Account] = []
        for (name, type, balance, institution) in accounts {
            let account = Account(name: name, type: type, balance: balance, institution: institution)
            ctx.insert(account)
            insertedAccounts.append(account)

            // 12 months of balance history per account
            for monthsAgo in (0..<12).reversed() {
                let date = Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date())!
                let jitter = balance * Double.random(in: -0.04...0.04)
                let snap = BalanceSnapshot(balance: balance + jitter, recordedAt: date)
                ctx.insert(snap)
                account.balanceHistory.append(snap)
            }
        }

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
