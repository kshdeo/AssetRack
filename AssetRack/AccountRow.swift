import SwiftUI
import SwiftData

struct AccountRow: View {
    let account: Account
    let currencyService: CurrencyService

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.type.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(account.isLiability ? .red : .blue)
                .frame(width: 32, height: 32)
                .background(
                    (account.isLiability ? Color.red : Color.blue).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 4) {
                    Text(account.type.displayName)
                    if account.hasHoldings {
                        Text("·")
                        Text("^[\(account.holdings.count) holding](inflect: true)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(currencyService.formatted(Money(account.currentBalance, account.currency)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(account.isLiability ? .red : .primary)

                if let percent = account.dailyChangePercent(using: currencyService) {
                    // Liabilities flip — debt going down reads as a gain (green).
                    ChangeBadge(percent: percent, isGain: account.dailyChangeIsGain(percent))
                }
            }
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    let container = ModelContainer.previewContainer
    let account = Account(name: "Barclays Savings", type: .savings, balance: 12_500, institution: "Barclays", currency: "GBP")
    return AccountRow(account: account, currencyService: CurrencyService())
        .padding()
        .modelContainer(container)
}
