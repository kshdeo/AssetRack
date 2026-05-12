import Foundation
import Observation

@Observable
final class DashboardViewModel {

    // MARK: - Net worth

    func netWorth(from accounts: [Account], fx: FXRateService) -> Double {
        accounts.reduce(0) { $0 + fx.toBase($1.signedBalance, currency: $1.currency) }
    }

    func totalAssets(from accounts: [Account], fx: FXRateService) -> Double {
        accounts.filter { !$0.isLiability }
            .reduce(0) { $0 + fx.toBase($1.currentBalance, currency: $1.currency) }
    }

    func totalLiabilities(from accounts: [Account], fx: FXRateService) -> Double {
        accounts.filter { $0.isLiability }
            .reduce(0) { $0 + fx.toBase($1.currentBalance, currency: $1.currency) }
    }

    // MARK: - Chart

    func monthOverMonthDelta(from snapshots: [NetWorthSnapshot]) -> Double? {
        let sorted = snapshots.sorted { $0.recordedAt < $1.recordedAt }
        guard sorted.count >= 2 else { return nil }
        let prev = sorted[sorted.count - 2].netWorth
        let curr = sorted[sorted.count - 1].netWorth
        guard prev != 0 else { return nil }
        return (curr - prev) / abs(prev)
    }

    // MARK: - Allocation

    func allocationSegments(from accounts: [Account]) -> [(category: AccountCategory, value: Double, color: String)] {
        let assets = accounts.filter { !$0.isLiability }
        let total = assets.reduce(0) { $0 + $1.currentBalance }
        guard total > 0 else { return [] }

        var grouped: [AccountCategory: Double] = [:]
        for account in assets {
            grouped[account.type.category, default: 0] += account.currentBalance
        }

        return grouped
            .map { (category: $0.key, value: $0.value / total, color: colorName(for: $0.key)) }
            .sorted { $0.value > $1.value }
    }

    private func colorName(for category: AccountCategory) -> String {
        switch category {
        case .cashAndBank:  return "teal"
        case .investments:  return "blue"
        case .realEstate:   return "indigo"
        case .liabilities:  return "red"
        }
    }

    // MARK: - Accounts list

    func topAccounts(from accounts: [Account], limit: Int = 5) -> [Account] {
        accounts
            .sorted { abs($0.currentBalance) > abs($1.currentBalance) }
            .prefix(limit)
            .map { $0 }
    }
}
