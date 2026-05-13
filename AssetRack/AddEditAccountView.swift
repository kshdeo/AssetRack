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
    @State private var selectedCurrency: String = "USD"
    @State private var tickerSymbol: String = ""
    @State private var quantityText: String = ""
    @State private var showingDeleteConfirm = false

    private var isTickerMode: Bool {
        selectedType.supportsTicker && !tickerSymbol.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var parsedQuantity: Double? {
        Double(quantityText.trimmingCharacters(in: .whitespaces))
    }

    static let currencies: [(code: String, label: String)] = [
        ("USD", "USD — US Dollar"),
        ("EUR", "EUR — Euro"),
        ("GBP", "GBP — British Pound"),
        ("CAD", "CAD — Canadian Dollar"),
        ("AUD", "AUD — Australian Dollar"),
        ("CHF", "CHF — Swiss Franc"),
        ("JPY", "JPY — Japanese Yen"),
        ("CNY", "CNY — Chinese Yuan"),
        ("INR", "INR — Indian Rupee"),
        ("SGD", "SGD — Singapore Dollar"),
        ("HKD", "HKD — Hong Kong Dollar"),
        ("NZD", "NZD — New Zealand Dollar"),
        ("MXN", "MXN — Mexican Peso"),
        ("BRL", "BRL — Brazilian Real"),
        ("KRW", "KRW — South Korean Won"),
        ("SEK", "SEK — Swedish Krona"),
        ("NOK", "NOK — Norwegian Krone"),
        ("DKK", "DKK — Danish Krone"),
        ("AED", "AED — UAE Dirham"),
        ("ZAR", "ZAR — South African Rand"),
    ]

    private var isEditing: Bool { editingAccount != nil }

    private var parsedBalance: Double? {
        let cleaned = balanceText
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if isTickerMode { return parsedQuantity != nil }
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

                if selectedType.supportsTicker {
                    Section {
                        HStack {
                            TextField("Ticker symbol (e.g. VOO, AAPL)", text: $tickerSymbol)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.characters)
                            if !tickerSymbol.isEmpty {
                                Button { tickerSymbol = "" } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !tickerSymbol.trimmingCharacters(in: .whitespaces).isEmpty {
                            HStack {
                                TextField("Number of shares", text: $quantityText)
                                    .keyboardType(.decimalPad)
                                Text("shares")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Auto-Track Price")
                    } footer: {
                        Text(isTickerMode
                             ? "Balance will be updated automatically using market price × shares."
                             : "Optional. Enter a ticker to track price automatically.")
                    }
                }

                Section(selectedType.isLiability ? "Amount Owed" : "Current Balance") {
                    Picker("Currency", selection: $selectedCurrency) {
                        ForEach(Self.currencies, id: \.code) { currency in
                            Text(currency.label).tag(currency.code)
                        }
                    }

                    if isTickerMode {
                        HStack {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Calculated from market price × shares")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack {
                            Text(currencySymbol(for: selectedCurrency))
                                .foregroundStyle(.secondary)
                            TextField("0", text: $balanceText)
                                .keyboardType(.decimalPad)
                        }
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

    private func currencySymbol(for code: String) -> String {
        let locale = Locale.availableIdentifiers
            .map { Locale(identifier: $0) }
            .first { $0.currency?.identifier == code }
        return locale?.currencySymbol ?? code
    }

    private func prefill() {
        guard let account = editingAccount else { return }
        name = account.name
        institution = account.institution
        selectedType = account.type
        selectedCurrency = account.currency
        tickerSymbol = account.tickerSymbol
        if account.quantity > 0 {
            quantityText = String(format: "%g", account.quantity)
        }
        if !account.isTickerTracked {
            balanceText = String(format: "%.2f", account.currentBalance)
        }
    }

    private func save() {
        let balance = parsedBalance ?? 0
        let ticker = tickerSymbol.trimmingCharacters(in: .whitespaces).uppercased()
        let qty = parsedQuantity ?? 0

        if let account = editingAccount {
            account.name = name
            account.institution = institution
            account.type = selectedType
            account.currency = selectedCurrency
            account.tickerSymbol = ticker
            account.quantity = qty
            if !isTickerMode {
                account.currentBalance = balance
                let snap = BalanceSnapshot(balance: balance)
                modelContext.insert(snap)
                account.balanceHistory.append(snap)
            }
            account.updatedAt = Date()
        } else {
            let account = Account(
                name: name.trimmingCharacters(in: .whitespaces),
                type: selectedType,
                balance: isTickerMode ? 0 : balance,
                institution: institution.trimmingCharacters(in: .whitespaces),
                currency: selectedCurrency
            )
            account.tickerSymbol = ticker
            account.quantity = qty
            modelContext.insert(account)

            if !isTickerMode {
                let snap = BalanceSnapshot(balance: balance)
                modelContext.insert(snap)
                account.balanceHistory.append(snap)
            }
        }

        recordNetWorthSnapshot()
        try? modelContext.save()
        dismiss()
    }

    private func deleteAndDismiss() {
        guard let account = editingAccount else { return }
        modelContext.delete(account)
        recordNetWorthSnapshot()
        try? modelContext.save()
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
