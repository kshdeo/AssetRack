import SwiftUI
import SwiftData

// MARK: - Account Balance History

struct AccountBalanceHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var account: Account
    let currencyService: CurrencyService

    @State private var snapshotToEdit: BalanceSnapshot?

    private var sorted: [BalanceSnapshot] {
        account.balanceHistory.sorted { $0.recordedAt > $1.recordedAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sorted.isEmpty {
                    ContentUnavailableView("No history yet", systemImage: "clock.arrow.circlepath")
                } else {
                    List {
                        ForEach(sorted) { snap in
                            Button { snapshotToEdit = snap } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(snap.recordedAt.formatted(.dateTime.month(.abbreviated).day().year()))
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Text(snap.recordedAt.formatted(.dateTime.hour().minute()))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(currencyService.formatted(Money(snap.balance, account.currency)))
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                        .onDelete { indices in
                            for index in indices {
                                modelContext.delete(sorted[index])
                            }
                            try? modelContext.save()
                        }
                    }
                }
            }
            .navigationTitle("\(account.name) History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
            .sheet(item: $snapshotToEdit) { snap in
                EditBalanceSnapshotView(snapshot: snap, currency: account.currency)
            }
        }
    }
}

// MARK: - Edit Balance Snapshot

struct EditBalanceSnapshotView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var snapshot: BalanceSnapshot
    let currency: String

    @State private var balanceText: String = ""
    @State private var date: Date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: [.date])
                    LabeledContent("Balance (\(currency))") {
                        TextField("Amount", text: $balanceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Edit Balance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(parsedBalance == nil)
                }
            }
        }
        .onAppear {
            date = snapshot.recordedAt
            balanceText = String(format: "%.2f", snapshot.balance)
        }
    }

    private var parsedBalance: Double? {
        Double(balanceText.replacingOccurrences(of: ",", with: ""))
    }

    private func save() {
        guard let value = parsedBalance else { return }
        snapshot.balance = value
        snapshot.recordedAt = date
        try? modelContext.save()
        dismiss()
    }
}

#Preview("Balance History") {
    let container = ModelContainer.previewContainer
    let account = Account(name: "Barclays Savings", type: .savings, balance: 12_500, institution: "Barclays", currency: "GBP")
    container.mainContext.insert(account)
    let calendar = Calendar.current
    account.balanceHistory = [
        BalanceSnapshot(balance: 10_000, recordedAt: calendar.date(byAdding: .month, value: -2, to: Date())!),
        BalanceSnapshot(balance: 11_200, recordedAt: calendar.date(byAdding: .month, value: -1, to: Date())!),
        BalanceSnapshot(balance: 12_500, recordedAt: Date()),
    ]
    return AccountBalanceHistoryView(account: account, currencyService: CurrencyService())
        .modelContainer(container)
}
