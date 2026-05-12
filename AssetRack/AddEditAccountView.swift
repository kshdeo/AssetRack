import SwiftUI
import SwiftData

struct AddEditAccountView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]

    var editingAccount: Account?

    @State private var name: String = ""
    @State private var institution: String = ""
    @State private var selectedType: AccountType = .checking
    @State private var balanceText: String = ""
    @State private var showingDeleteConfirm = false

    private var isEditing: Bool { editingAccount != nil }

    private var parsedBalance: Double? {
        let cleaned = balanceText
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && parsedBalance != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account Type") {
                    accountTypePicker
                }

                Section("Details") {
                    TextField("Account name", text: $name)
                        .autocorrectionDisabled()
                    TextField("Institution (optional)", text: $institution)
                        .autocorrectionDisabled()
                }

                Section(selectedType.isLiability ? "Amount Owed" : "Current Balance") {
                    HStack {
                        Text("$")
                            .foregroundStyle(.secondary)
                        TextField("0", text: $balanceText)
                            .keyboardType(.decimalPad)
                    }
                    if selectedType.isLiability {
                        Text("Enter the amount you owe as a positive number.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label("Delete Account", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Account" : "Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog(
                "Delete \(editingAccount?.name ?? "Account")?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteAndDismiss() }
            } message: {
                Text("This will permanently remove the account and its history.")
            }
        }
        .onAppear { prefill() }
    }

    // MARK: - Type Picker

    private var accountTypePicker: some View {
        VStack(spacing: 0) {
            ForEach(AccountCategory.allCases, id: \.self) { category in
                let types = AccountType.allCases.filter { $0.category == category }
                if !types.isEmpty {
                    Section {
                        ForEach(types, id: \.self) { type in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedType = type
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: type.systemImage)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(type.isLiability ? .red : .blue)
                                        .frame(width: 28, height: 28)
                                        .background(
                                            (type.isLiability ? Color.red : Color.blue).opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 7)
                                        )

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(type.displayName)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Text(category.rawValue)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if selectedType == type {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text(category.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func prefill() {
        guard let account = editingAccount else { return }
        name = account.name
        institution = account.institution
        selectedType = account.type
        balanceText = String(format: "%.2f", account.currentBalance)
    }

    private func save() {
        guard let balance = parsedBalance else { return }

        if let account = editingAccount {
            account.name = name
            account.institution = institution
            account.type = selectedType
            account.currentBalance = balance
            account.updatedAt = Date()

            let snap = BalanceSnapshot(balance: balance)
            modelContext.insert(snap)
            account.balanceHistory.append(snap)
        } else {
            let account = Account(
                name: name.trimmingCharacters(in: .whitespaces),
                type: selectedType,
                balance: balance,
                institution: institution.trimmingCharacters(in: .whitespaces)
            )
            modelContext.insert(account)

            let snap = BalanceSnapshot(balance: balance)
            modelContext.insert(snap)
            account.balanceHistory.append(snap)
        }

        recordNetWorthSnapshot()
        dismiss()
    }

    private func deleteAndDismiss() {
        guard let account = editingAccount else { return }
        modelContext.delete(account)
        recordNetWorthSnapshot()
        dismiss()
    }

    private func recordNetWorthSnapshot() {
        // Inline snapshot — SnapshotService (Step 4) will centralise this
        let allAccounts = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
        let assets = allAccounts.filter { !$0.isLiability }.reduce(0) { $0 + $1.currentBalance }
        let liabilities = allAccounts.filter { $0.isLiability }.reduce(0) { $0 + $1.currentBalance }
        let snap = NetWorthSnapshot(
            netWorth: assets - liabilities,
            totalAssets: assets,
            totalLiabilities: liabilities
        )
        modelContext.insert(snap)
    }
}

#Preview("Add") {
    AddEditAccountView()
        .modelContainer(ModelContainer.previewContainer)
}

#Preview("Edit") {
    let container = ModelContainer.previewContainer
    let account = Account(name: "Chase Checking", type: .checking, balance: 12_450, institution: "Chase")
    return AddEditAccountView(editingAccount: account)
        .modelContainer(container)
}
