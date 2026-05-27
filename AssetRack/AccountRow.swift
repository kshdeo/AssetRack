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

                if let percent = account.dailyChangePercent {
                    dailyChangeBadge(percent)
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// Small directional indicator below the balance. Muted styling: only the
    /// arrow carries the green/red signal; the percent sits in `.secondary`.
    /// For liabilities, down-arrow = green (debt paid off).
    @ViewBuilder
    private func dailyChangeBadge(_ percent: Double) -> some View {
        let isGain = account.dailyChangeIsGain(percent)
        HStack(spacing: 3) {
            Image(systemName: percent >= 0 ? "arrow.up" : "arrow.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isGain ? Color.green : Color.red)
            Text(abs(percent), format: .percent.precision(.fractionLength(2)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    let container = ModelContainer.previewContainer
    let account = Account(name: "Barclays Savings", type: .savings, balance: 12_500, institution: "Barclays", currency: "GBP")
    return AccountRow(account: account, currencyService: CurrencyService())
        .padding()
        .modelContainer(container)
}
