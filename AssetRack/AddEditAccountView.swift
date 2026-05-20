import SwiftUI
import SwiftData

// MARK: - Add / Edit Account

struct AddEditAccountView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var editingAccount: Account?

    @State private var name: String = ""
    @State private var institution: String = ""
    @State private var selectedType: AccountType = .checking
    @State private var balanceText: String = ""
    @State private var selectedCurrency: Currency = .usd
    @State private var balanceDate: Date = Date()
    @State private var cashBalanceText: String = ""
    @State private var holdings: [HoldingDraft] = []
    @State private var showingAddHolding = false
    @State private var holdingToEdit: HoldingDraft?
    @State private var showingDeleteConfirm = false

    struct HoldingDraft: Identifiable {
        var id = UUID()
        var tickerSymbol: String
        var quantity: Double
        // Holds reference to persisted Holding when editing existing account
        var existingHolding: Holding?
    }

    private var isEditing: Bool { editingAccount != nil }

    private var parsedBalance: Double? {
        let cleaned = balanceText
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    private var parsedCashBalance: Double {
        let cleaned = cashBalanceText
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned) ?? 0
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if selectedType.supportsHoldings { return true }
        return parsedBalance != nil
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

                if selectedType.supportsHoldings {
                    holdingsSection
                } else {
                    balanceSection
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
            .sheet(isPresented: $showingAddHolding) {
                AddHoldingView { draft in
                    holdings.append(draft)
                }
            }
            .sheet(item: $holdingToEdit) { draft in
                AddHoldingView(existing: draft) { updated in
                    if let idx = holdings.firstIndex(where: { $0.id == updated.id }) {
                        holdings[idx] = updated
                    }
                }
            }
        }
        .onAppear { prefill() }
    }

    // MARK: - Holdings Section

    private var holdingsSection: some View {
        Group {
            Section {
                if holdings.isEmpty {
                    Text("No holdings yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(holdings) { draft in
                        Button { holdingToEdit = draft } label: {
                            HoldingDraftRow(draft: draft)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indices in
                        holdings.remove(atOffsets: indices)
                    }
                }

                Button {
                    showingAddHolding = true
                } label: {
                    Label("Add Holding", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Holdings")
            }

            Section {
                Picker("Currency", selection: $selectedCurrency) {
                    ForEach(Currency.allCases, id: \.self) { c in
                        Text(c.label).tag(c)
                    }
                }

                HStack {
                    Text(selectedCurrency.symbol)
                        .foregroundStyle(.secondary)
                    TextField("0", text: $cashBalanceText)
                        .keyboardType(.decimalPad)
                }
            } header: {
                Text("Cash Balance")
            } footer: {
                Text("Cash held in this brokerage account, separate from your holdings.")
            }

            if !holdings.isEmpty || parsedCashBalance > 0 {
                Section {
                    let holdingsTotal = holdings.reduce(0.0) { $0 + ($1.existingHolding?.value ?? 0) }
                    let cash = parsedCashBalance
                    let total = holdingsTotal + cash
                    LabeledContent("Total") {
                        Text(total.currencyFormatted(code: selectedCurrency.code))
                            .fontWeight(.semibold)
                    }
                } footer: {
                    if holdings.contains(where: { $0.existingHolding?.lastPrice == 0 || $0.existingHolding == nil }) {
                        Text("Holdings without a fetched price are excluded from the total.")
                    }
                }
            }
        }
    }

    // MARK: - Balance Section (non-brokerage)

    private var balanceSection: some View {
        Section(selectedType.isLiability ? "Amount Owed" : "Current Balance") {
            Picker("Currency", selection: $selectedCurrency) {
                ForEach(Currency.allCases, id: \.self) { c in
                    Text(c.label).tag(c)
                }
            }

            HStack {
                Text(selectedCurrency.symbol)
                    .foregroundStyle(.secondary)
                TextField("0", text: $balanceText)
                    .keyboardType(.decimalPad)
            }

            if isEditing {
                DatePicker(
                    "As of",
                    selection: $balanceDate,
                    in: ...Date(),
                    displayedComponents: [.date]
                )
            }

            if selectedType.isLiability {
                Text("Enter the amount you owe as a positive number.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

    // MARK: - Helpers


    private func prefill() {
        guard let account = editingAccount else { return }
        name = account.name
        institution = account.institution
        selectedType = account.type
        selectedCurrency = Currency(rawValue: account.currency) ?? .usd

        if account.type.supportsHoldings {
            cashBalanceText = account.cashBalance > 0 ? String(format: "%.2f", account.cashBalance) : ""
            holdings = account.holdings.map {
                HoldingDraft(tickerSymbol: $0.tickerSymbol, quantity: $0.quantity, existingHolding: $0)
            }
        } else {
            balanceText = String(format: "%.2f", account.currentBalance)
        }
    }

    // MARK: - Save / Delete

    private func save() {
        if let account = editingAccount {
            account.name = name
            account.institution = institution
            account.type = selectedType
            account.currency = selectedCurrency.code

            if selectedType.supportsHoldings {
                syncHoldings(to: account)
                account.cashBalance = parsedCashBalance
                account.recomputeBalance()
            } else {
                let balance = parsedBalance ?? 0
                account.currentBalance = balance
                account.updatedAt = balanceDate
                let snap = BalanceSnapshot(balance: balance, recordedAt: balanceDate)
                modelContext.insert(snap)
                account.balanceHistory.append(snap)
            }
        } else {
            let account = Account(
                name: name.trimmingCharacters(in: .whitespaces),
                type: selectedType,
                balance: selectedType.supportsHoldings ? 0 : (parsedBalance ?? 0),
                institution: institution.trimmingCharacters(in: .whitespaces),
                currency: selectedCurrency.code
            )
            modelContext.insert(account)

            if selectedType.supportsHoldings {
                for draft in holdings {
                    let h = Holding(tickerSymbol: draft.tickerSymbol, quantity: draft.quantity)
                    modelContext.insert(h)
                    account.holdings.append(h)
                }
                account.cashBalance = parsedCashBalance
                account.recomputeBalance()
            } else {
                let balance = parsedBalance ?? 0
                let snap = BalanceSnapshot(balance: balance)
                modelContext.insert(snap)
                account.balanceHistory.append(snap)
            }
        }

        recordNetWorthSnapshot(at: selectedType.supportsHoldings ? Date() : balanceDate)
        try? modelContext.save()
        dismiss()
    }

    private func syncHoldings(to account: Account) {
        // Delete removed holdings
        let draftIds = Set(holdings.compactMap { $0.existingHolding?.id })
        for existing in account.holdings where !draftIds.contains(existing.id) {
            modelContext.delete(existing)
        }

        // Update or insert
        for draft in holdings {
            if let existing = draft.existingHolding {
                existing.tickerSymbol = draft.tickerSymbol
                existing.quantity = draft.quantity
            } else {
                let h = Holding(tickerSymbol: draft.tickerSymbol, quantity: draft.quantity)
                modelContext.insert(h)
                account.holdings.append(h)
            }
        }
    }

    private func deleteAndDismiss() {
        guard let account = editingAccount else { return }
        modelContext.delete(account)
        recordNetWorthSnapshot(at: Date())
        try? modelContext.save()
        dismiss()
    }

    private func recordNetWorthSnapshot(at date: Date) {
        let allAccounts = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
        let assets = allAccounts.filter { !$0.isLiability }.reduce(0) { $0 + $1.currentBalance }
        let liabilities = allAccounts.filter { $0.isLiability }.reduce(0) { $0 + $1.currentBalance }
        let snap = NetWorthSnapshot(
            netWorth: assets - liabilities,
            totalAssets: assets,
            totalLiabilities: liabilities,
            recordedAt: date
        )
        modelContext.insert(snap)
    }
}

// MARK: - Holding Draft Row

struct HoldingDraftRow: View {
    let draft: AddEditAccountView.HoldingDraft

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.tickerSymbol.uppercased())
                    .font(.subheadline.weight(.semibold))
                Text("\(draft.quantity.formatted()) shares")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let existing = draft.existingHolding, existing.lastPrice > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(existing.value.currencyFormatted())
                        .font(.subheadline.weight(.medium))
                    Text("@ \(existing.lastPrice.currencyFormatted()) ea")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Add Holding Sheet

struct AddHoldingView: View {
    @Environment(\.dismiss) private var dismiss

    var existing: AddEditAccountView.HoldingDraft?
    var onSave: (AddEditAccountView.HoldingDraft) -> Void

    @State private var tickerSymbol: String = ""
    @State private var quantityText: String = ""

    private var parsedQuantity: Double? { Double(quantityText) }
    private var canSave: Bool {
        !tickerSymbol.trimmingCharacters(in: .whitespaces).isEmpty && parsedQuantity != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ticker symbol (e.g. VOO, AAPL, BTC-USD)", text: $tickerSymbol)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)

                    HStack {
                        TextField("Number of shares", text: $quantityText)
                            .keyboardType(.decimalPad)
                        Text("shares")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Use Yahoo Finance symbols. Crypto: BTC-USD, ETH-USD.")
                }
            }
            .navigationTitle(existing == nil ? "Add Holding" : "Edit Holding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveHolding() }
                        .disabled(!canSave)
                }
            }
        }
        .onAppear {
            if let existing {
                tickerSymbol = existing.tickerSymbol
                quantityText = existing.quantity.formatted()
            }
        }
    }

    private func saveHolding() {
        guard let qty = parsedQuantity else { return }
        let draft = AddEditAccountView.HoldingDraft(
            id: existing?.id ?? UUID(),
            tickerSymbol: tickerSymbol.uppercased().trimmingCharacters(in: .whitespaces),
            quantity: qty,
            existingHolding: existing?.existingHolding
        )
        onSave(draft)
        dismiss()
    }
}

// MARK: - Previews

#Preview("Add") {
    AddEditAccountView()
        .modelContainer(ModelContainer.previewContainer)
}

#Preview("Edit Brokerage") {
    let container = ModelContainer.previewContainer
    let account = Account(name: "Fidelity Brokerage", type: .brokerage, balance: 0, institution: "Fidelity")
    return AddEditAccountView(editingAccount: account)
        .modelContainer(container)
}
