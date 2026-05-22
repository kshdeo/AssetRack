import Foundation
import Observation

@Observable
final class DashboardViewModel {

    // MARK: - Net worth

    func netWorth(from accounts: [Account], currency: CurrencyService) -> Money {
        currency.sum(accounts.map { Money($0.signedBalance, $0.currency) }, in: currency.baseCurrency)
    }

    func totalAssets(from accounts: [Account], currency: CurrencyService) -> Money {
        currency.sum(
            accounts.filter { !$0.isLiability }.map { Money($0.currentBalance, $0.currency) },
            in: currency.baseCurrency
        )
    }

    func totalLiabilities(from accounts: [Account], currency: CurrencyService) -> Money {
        currency.sum(
            accounts.filter { $0.isLiability }.map { Money($0.currentBalance, $0.currency) },
            in: currency.baseCurrency
        )
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

    func allocationSegments(from accounts: [Account], currency: CurrencyService) -> [(category: AccountCategory, value: Double, color: String)] {
        let assets = accounts.filter { !$0.isLiability }
        let total = currency.sum(assets.map { Money($0.currentBalance, $0.currency) }, in: currency.baseCurrency).amount
        guard total > 0 else { return [] }

        var grouped: [AccountCategory: Double] = [:]
        for account in assets {
            grouped[account.type.category, default: 0] += currency.convert(
                account.currentBalance,
                from: account.currency,
                to: currency.baseCurrency
            )
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
