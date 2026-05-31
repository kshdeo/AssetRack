import SwiftUI
import SwiftData

struct AddHistoricalEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]

    let currencyService: CurrencyService

    @State private var date: Date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var balanceTexts: [UUID: String] = [:]

    private var liveTotal: Double {
        let amounts: [Money] = accounts.compactMap { account in
            guard let text = balanceTexts[account.id],
                  let value = Double(text.replacingOccurrences(of: ",", with: "")) else { return nil }
            let signed = account.isLiability ? -value : value
            return Money(signed, account.currency)
        }
        return currencyService.sum(amounts, in: currencyService.baseCurrency).amount
    }

    private var categorisedAccounts: [(category: AccountCategory, accounts: [Account])] {
        let order: [AccountCategory] = [.cashAndBank, .investments, .pension, .realEstate, .liabilities]
        return order.compactMap { category in
            let filtered = accounts.filter { $0.type.category == category }
            return filtered.isEmpty ? nil : (category, filtered.sorted { $0.name < $1.name })
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: [.date])
                        .onChange(of: date) { _, newDate in prefill(for: newDate) }
                    LabeledContent("Net Worth") {
                        Text(currencyService.formattedBase(liveTotal))
                            .font(.headline)
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.15), value: liveTotal)
                    }
                }

                ForEach(categorisedAccounts, id: \.category) { group in
                    Section(group.category.rawValue) {
                        ForEach(group.accounts) { account in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name)
                                        .font(.subheadline)
                                    Text(account.currency)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                TextField("0", text: Binding(
                                    get: { balanceTexts[account.id] ?? "" },
                                    set: { balanceTexts[account.id] = $0 }
                                ))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 140)
                                .foregroundStyle(account.isLiability ? .red : .primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Historical Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .onAppear { prefill(for: date) }
    }

    /// Pre-fill each account with its carry-forward balance for the selected date.
    private func prefill(for date: Date) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        for account in accounts {
            let balance = account.balanceHistory
                .filter({ calendar.startOfDay(for: $0.recordedAt) <= day })
                .max(by: { $0.recordedAt < $1.recordedAt })?.balance ?? 0
            balanceTexts[account.id] = String(format: "%.2f", balance)
        }
    }

    private func save() {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: date)
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date

        for account in accounts {
            guard let text = balanceTexts[account.id],
                  let value = Double(text.replacingOccurrences(of: ",", with: "")) else { continue }

            // Update existing snapshot for this day if one exists, otherwise create new
            if let existing = account.balanceHistory
                .filter({ calendar.startOfDay(for: $0.recordedAt) == targetDay })
                .max(by: { $0.recordedAt < $1.recordedAt }) {
                existing.balance = value
            } else {
                account.balanceHistory.append(BalanceSnapshot(balance: value, recordedAt: noon))
            }
        }
        // Keep currentBalance in sync with the latest snapshot we just wrote.
        modelContext.reconcileAccountBalances()
        try? modelContext.save()
        dismiss()
    }
}

#Preview {
    AddHistoricalEntryView(currencyService: CurrencyService())
        .modelContainer(ModelContainer.previewContainer)
}
