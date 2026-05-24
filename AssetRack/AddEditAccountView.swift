import SwiftUI
import SwiftData

// MARK: - Add / Edit Account

struct AddEditAccountView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var editingAccount: Account?
    var tickerService: TickerService?
    var currencyService: CurrencyService?

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
    @State private var showingBalanceHistory = false

    struct HoldingDraft: Identifiable {
        var id = UUID()
        var tickerSymbol: String
        var quantity: Double
        var priceSource: PriceSource = .yahooFinance
        var isin: String = ""
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

    private var holdingsTotal: String {
        let amounts: [Money] = holdings.compactMap { draft in
            guard let h = draft.existingHolding else { return nil }
            return Money(h.value, h.priceCurrency)
        } + [Money(parsedCashBalance, selectedCurrency.code)]

        guard let cs = currencyService else {
            return Money(parsedCashBalance, selectedCurrency.code).formatted()
        }
        return cs.formatted(cs.sum(amounts, in: selectedCurrency.code))
    }

    private var showHoldingsTotal: Bool {
        !holdings.isEmpty || parsedCashBalance > 0
    }

    private var hasPendingPrices: Bool {
        holdings.contains { $0.existingHolding?.lastPrice == 0 || $0.existingHolding == nil }
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
            .sheet(isPresented: $showingBalanceHistory) {
                if let account = editingAccount, let cs = currencyService {
                    AccountBalanceHistoryView(account: account, currencyService: cs)
                }
            }
        }
        .onAppear {
            prefill()
            if editingAccount?.type.supportsHoldings == true, let ts = tickerService {
                Task { await ts.fetch(context: modelContext, currency: currencyService ?? CurrencyService()) }
            }
        }
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
                HStack {
                    Text("Holdings")
                    Spacer()
                    if let ts = tickerService {
                        if ts.isLoading {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Button {
                                Task { await ts.fetch(context: modelContext, currency: currencyService ?? CurrencyService()) }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                            }
                        }
                    }
                }
            } footer: {
                if let ts = tickerService, let errSymbol = ts.errors.keys.first {
                    Label("Could not fetch price for \(errSymbol)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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

            if showHoldingsTotal {
                Section {
                    LabeledContent("Total") {
                        Text(holdingsTotal)
                            .fontWeight(.semibold)
                    }
                } footer: {
                    if hasPendingPrices {
                        Text("Holdings without a fetched price are excluded from the total.")
                    }
                }
            }
        }
    }

    // MARK: - Balance Section (non-brokerage)

    @ViewBuilder
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

        if isEditing, let account = editingAccount {
            Section {
                Button {
                    showingBalanceHistory = true
                } label: {
                    HStack {
                        Text("Balance History")
                        Spacer()
                        Text("^[\(account.balanceHistory.count) entry](inflect: true)")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
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
                HoldingDraft(tickerSymbol: $0.tickerSymbol, quantity: $0.quantity,
                             priceSource: $0.priceSource, isin: $0.isin, existingHolding: $0)
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
                // SwiftData auto-inserts via @Relationship — no explicit insert needed
                account.balanceHistory.append(BalanceSnapshot(balance: balance, recordedAt: balanceDate))
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
                    // account is in context — appending auto-inserts the Holding
                    account.holdings.append(Holding(tickerSymbol: draft.tickerSymbol, quantity: draft.quantity,
                                                    priceSource: draft.priceSource, isin: draft.isin))
                }
                account.cashBalance = parsedCashBalance
                account.recomputeBalance()
            } else {
                let balance = parsedBalance ?? 0
                // account is in context — appending auto-inserts the BalanceSnapshot
                account.balanceHistory.append(BalanceSnapshot(balance: balance))
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
                existing.priceSource = draft.priceSource
                existing.isin = draft.isin
            } else {
                // account is already in context — appending auto-inserts the Holding
                account.holdings.append(Holding(tickerSymbol: draft.tickerSymbol, quantity: draft.quantity))
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
        modelContext.recordNetWorthSnapshot(currency: currencyService ?? CurrencyService(), at: date)
    }
}

// MARK: - Holding Draft Row

struct HoldingDraftRow: View {
    let draft: AddEditAccountView.HoldingDraft

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(draft.tickerSymbol.uppercased())
                        .font(.subheadline.weight(.semibold))
                    if draft.priceSource == .tradegate {
                        Text("TG")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                if let existing = draft.existingHolding, existing.lastPrice > 0 {
                    Text("\(draft.quantity.formatted()) @ \(existing.lastPrice.currencyFormatted(code: existing.priceCurrency))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                } else {
                    Text("\(draft.quantity.formatted()) shares")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let existing = draft.existingHolding {
                HoldingPriceView(holding: existing)
            } else {
                Text("Price pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// Separate view so @Model observation triggers re-renders automatically
struct HoldingPriceView: View {
    var holding: Holding

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if holding.lastPrice > 0 {
                Text(holding.value.currencyFormatted(code: holding.priceCurrency))
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.numericText())
                if let fetchedAt = holding.lastPriceFetchedAt {
                    Text("Updated \(fetchedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not yet updated")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Price pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.easeOut(duration: 0.2), value: holding.lastPrice)
    }
}

// MARK: - Add Holding Sheet

struct AddHoldingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ISINLookupService.apiKeyDefaultsKey) private var finnhubApiKey = ""

    var existing: AddEditAccountView.HoldingDraft?
    var onSave: (AddEditAccountView.HoldingDraft) -> Void

    @State private var priceSource: PriceSource = .yahooFinance
    @State private var tickerSymbol: String = ""
    @State private var isin: String = ""
    @State private var quantityText: String = ""

    // Search (Tradegate + Yahoo Finance)
    @State private var searchQuery: String = ""
    @State private var searchResults: [StockSearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?

    private let lookupService = ISINLookupService()

    private var parsedQuantity: Double? { Double(quantityText) }
    private var canSave: Bool {
        guard parsedQuantity != nil,
              !tickerSymbol.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if priceSource == .tradegate {
            return !isin.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                // Source picker
                Section {
                    Picker("Price source", selection: $priceSource) {
                        ForEach(PriceSource.allCases, id: \.self) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                }
                .onChange(of: priceSource) { _, _ in
                    searchResults = []
                    searchQuery = ""
                    searchError = nil
                }

                if priceSource == .tradegate {
                    tradegateSections
                } else {
                    yahooSection
                }

                // Quantity
                Section {
                    HStack {
                        TextField("Number of shares", text: $quantityText)
                            .keyboardType(.decimalPad)
                        Text("shares")
                            .foregroundStyle(.secondary)
                    }
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
                priceSource  = existing.priceSource
                tickerSymbol = existing.tickerSymbol
                isin         = existing.isin
                quantityText = existing.quantity.formatted()
            }
        }
    }

    // MARK: - Yahoo Finance section

    private var yahooSection: some View {
        Section {
            TextField("Ticker symbol (e.g. VOO, AAPL, BTC-USD)", text: $tickerSymbol)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
        } footer: {
            Text("Use Yahoo Finance symbols. Crypto: BTC-USD, ETH-USD.")
        }
    }

    // MARK: - Tradegate sections

    @ViewBuilder
    private var tradegateSections: some View {
        // Search
        Section {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search by name or ticker…", text: $searchQuery)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: searchQuery) { _, newValue in
                        scheduleSearch(query: newValue)
                    }
                if isSearching {
                    ProgressView().scaleEffect(0.8)
                }
            }
        } header: {
            Text("Search")
        } footer: {
            if let error = searchError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        // Search results
        if !searchResults.isEmpty {
            Section("Results") {
                ForEach(searchResults) { result in
                    Button { selectResult(result) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.description)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Text("\(result.displaySymbol) · \(result.type)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }

        // Resolved details (shown once ticker is set)
        Section {
            HStack {
                TextField("Ticker / name (e.g. VOW3)", text: $tickerSymbol)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            }
            TextField("ISIN (e.g. DE0007664039)", text: $isin)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
        } header: {
            Text("Details")
        } footer: {
            Text("Prices fetched from Tradegate Exchange in EUR.")
        }
    }

    // MARK: - Search logic

    private func scheduleSearch(query: String) {
        searchTask?.cancel()
        searchError = nil
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await performSearch(query: query)
        }
    }

    @MainActor
    private func performSearch(query: String) async {
        isSearching = true
        defer { isSearching = false }
        do {
            switch priceSource {
            case .tradegate:
                // Tradegate HTML search — returns ISINs directly, no API key needed
                searchResults = try await lookupService.searchTradegate(query: query)
            case .yahooFinance:
                let key = ISINLookupService.effectiveApiKey(userKey: finnhubApiKey)
                searchResults = try await lookupService.search(query: query, apiKey: key)
            }
        } catch {
            searchError = "Search failed: \(error.localizedDescription)"
            searchResults = []
        }
    }

    @MainActor
    private func selectResult(_ result: StockSearchResult) {
        // For Tradegate: use the ticker code (displaySymbol) when it differs from the ISIN,
        // otherwise fall back to the company name as a readable label.
        // For Yahoo Finance: displaySymbol is the proper ticker (e.g. "AAPL").
        let isRealTicker = result.displaySymbol != result.resolvedISIN
        tickerSymbol  = isRealTicker ? result.displaySymbol : result.description
        searchQuery   = result.description
        searchResults = []
        if let resolvedISIN = result.resolvedISIN {
            isin = resolvedISIN
        }
    }

    // MARK: - Save

    private func saveHolding() {
        guard let qty = parsedQuantity else { return }
        let draft = AddEditAccountView.HoldingDraft(
            id: existing?.id ?? UUID(),
            tickerSymbol: tickerSymbol.uppercased().trimmingCharacters(in: .whitespaces),
            quantity: qty,
            priceSource: priceSource,
            isin: isin.uppercased().trimmingCharacters(in: .whitespaces),
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
