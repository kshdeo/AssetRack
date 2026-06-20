import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Holding Draft

struct HoldingDraft: Identifiable {
    var id = UUID()
    var tickerSymbol: String
    var quantity: Double
    var priceSource: PriceSource = .yahooFinance
    var isin: String = ""
    /// Price fetched during the add/edit flow — used to pre-populate the holding
    /// so the account balance is correct immediately, before the next TickerService refresh.
    var lastPrice: Double = 0
    var priceCurrency: String = "USD"
    // Holds reference to persisted Holding when editing existing account
    var existingHolding: Holding?
}

// MARK: - Add / Edit Account

struct AddEditAccountView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var editingAccount: Account?
    var tickerService: TickerService?
    var currencyService: CurrencyService?

    @State private var name: String = ""
    @State private var institution: String = ""
    @State private var selectedType: AccountType = .checking
    @State private var selectedCategory: AccountCategory = .cashAndBank
    @State private var balanceText: String = ""
    @State private var selectedCurrency: Currency = .usd
    @State private var balanceDate: Date = Date()
    @State private var cashBalanceText: String = ""
    @State private var holdings: [HoldingDraft] = []
    @State private var showingAddHolding = false
    @State private var holdingToEdit: HoldingDraft?
    @State private var showingDeleteConfirm = false
    @State private var showingBalanceHistory = false
    @State private var showingTypeChangeAlert = false

    // MARK: Scan-statement state
    //
    // Only used in the "add" flow — editing an existing account keeps its
    // values. `pendingScanItem` is what `PhotosPicker` writes into; the
    // `.task(id:)` modifier reacts to changes and runs the scanner.
    @State private var scanner = StatementScanner()
    @State private var pendingScanItem: PhotosPickerItem?
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var scanSummary: String?

    private var isEditing: Bool { editingAccount != nil }

    private var parsedBalance: Double? {
        NumberParsing.userNumber(balanceText)
    }

    private var parsedCashBalance: Double {
        NumberParsing.userNumber(cashBalanceText) ?? 0
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
        holdings.contains { draft in
            let price = draft.existingHolding?.lastPrice ?? draft.lastPrice
            return price == 0
        }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if selectedType.supportsHoldings { return true }
        return parsedBalance != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isEditing {
                    scanSection
                }

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
            .navigationTitle(isEditing ? (editingAccount?.name ?? "Edit Account") : "Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let account = editingAccount, selectedType != account.type {
                            showingTypeChangeAlert = true
                        } else {
                            save()
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .alert("Change Account Type?", isPresented: $showingTypeChangeAlert) {
                Button("Change Type", role: .destructive) { save() }
                Button("Cancel", role: .cancel) {}
            } message: {
                let original = editingAccount?.type
                let holdingsWarning = original?.supportsHoldings == true && !selectedType.supportsHoldings
                    ? " Holdings data will not carry over and the balance may be reset." : ""
                let signWarning = original?.isLiability != selectedType.isLiability
                    ? " The account will switch between asset and liability, affecting your net worth." : ""
                Text("Changing from \(original?.displayName ?? "") to \(selectedType.displayName) may affect how this account's balance is tracked.\(holdingsWarning)\(signWarning)")
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
            // PhotosPicker writes the selection into `pendingScanItem`. We
            // react to changes via `.task(id:)` instead of `.onChange` so the
            // scan runs in a structured Task that cancels cleanly if the user
            // dismisses the sheet mid-OCR.
            .task(id: pendingScanItem) {
                guard let item = pendingScanItem else { return }
                await performScan(item)
            }
        }
        .onAppear {
            prefill()
            if editingAccount?.type.supportsHoldings == true, let ts = tickerService {
                Task { await ts.fetch(context: modelContext, currency: currencyService ?? CurrencyService()) }
            }
        }
    }

    // MARK: - Scan section

    /// "Magic" entry point at the top of the form. PhotosPicker handles the
    /// image source; we surface progress and any errors inline so the user
    /// never leaves this screen during the scan. When the on-device model
    /// isn't ready (older OS, Apple Intelligence disabled, etc) we still
    /// show the row but disable it with the reason — easier to debug than a
    /// silently-missing entry point.
    private var scanSection: some View {
        Section {
            let isReady = scanner.availability.isReady
            PhotosPicker(selection: $pendingScanItem, matching: .images, photoLibrary: .shared()) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            LinearGradient(colors: isReady ? [.blue, .purple] : [.gray.opacity(0.6), .gray.opacity(0.4)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 9)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(isScanning ? "Scanning…" : "Scan statement")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isReady ? .primary : .secondary)
                        Text(scanSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isScanning {
                        ProgressView()
                    }
                }
                .contentShape(Rectangle())
            }
            .disabled(isScanning || !isReady)

            if let summary = scanSummary {
                Label(summary, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let error = scanError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } footer: {
            Text("Runs entirely on your device. The image never leaves your phone.")
        }
    }

    /// Subtitle shown under the scan-statement row. Surfaces *why* the button
    /// is disabled instead of silently hiding it. Each branch is actionable —
    /// the user can read it and know exactly what to do.
    private var scanSubtitle: String {
        switch scanner.availability {
        case .available:
            return "Pre-fill from a screenshot of your bank or brokerage app"
        case .preparing(let reason):
            return reason
        case .unsupportedDevice:
            return "This device or iOS version doesn't support Apple Intelligence"
        case .appleIntelligenceDisabled:
            return "Enable Apple Intelligence in Settings → Apple Intelligence & Siri"
        case .otherUnavailable(let reason):
            return "Apple Intelligence unavailable: \(reason)"
        }
    }

    /// Load the picked photo, hand it to the scanner, and merge results into
    /// the form. Clears `pendingScanItem` on completion so re-selecting the
    /// same image re-runs the scan.
    private func performScan(_ item: PhotosPickerItem) async {
        isScanning = true
        scanError = nil
        scanSummary = nil
        defer {
            isScanning = false
            pendingScanItem = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                scanError = "Couldn't load that image."
                return
            }
            let extracted = try await scanner.scan(image: image)
            applyScan(extracted)
        } catch let error as StatementScanner.ScanError {
            scanError = error.errorDescription
        } catch {
            scanError = error.localizedDescription
        }
    }

    /// Merge extracted fields into the form. We only overwrite fields the
    /// user hasn't already filled in, so a partial second scan doesn't blow
    /// away their edits. The type picker is the exception — if the model is
    /// confident enough to return a type, trust it (the user picked Scan to
    /// avoid setting things by hand).
    private func applyScan(_ extracted: StatementScanner.Extracted) {
        if let type = extracted.accountType {
            selectedType = type
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty, let accountName = extracted.accountName {
            name = accountName
        }
        if institution.trimmingCharacters(in: .whitespaces).isEmpty, let inst = extracted.institution {
            institution = inst
        }
        if let code = extracted.currency, let currency = Currency(rawValue: code) {
            selectedCurrency = currency
        }

        if selectedType.supportsHoldings {
            if let cash = extracted.cashBalance {
                cashBalanceText = NumberParsing.editableString(cash)
            }
            for h in extracted.holdings {
                // Prefer the model's derived ticker; fall back to the company
                // name so the row is never blank. Either way the user can fix
                // it with the existing ticker autocomplete before saving.
                let symbol = h.tickerSymbol.isEmpty ? (h.companyName ?? "") : h.tickerSymbol
                // Skip rows that carry no identifier and no quantity — OCR
                // noise occasionally yields an empty position.
                guard !symbol.isEmpty || h.quantity > 0 else { continue }
                let draft = HoldingDraft(
                    tickerSymbol: symbol,
                    quantity: h.quantity,
                    priceSource: .yahooFinance,
                    lastPrice: h.lastPrice ?? 0,
                    priceCurrency: h.priceCurrency ?? selectedCurrency.code
                )
                holdings.append(draft)
            }
        } else if let total = extracted.totalBalance {
            balanceText = NumberParsing.editableString(total)
        }

        scanSummary = summary(for: extracted)
    }

    /// Short user-facing recap of what filled in, so the user can see the
    /// scan worked without having to re-check every field.
    private func summary(for extracted: StatementScanner.Extracted) -> String {
        var parts: [String] = []
        if let inst = extracted.institution { parts.append(inst) }
        if let total = extracted.totalBalance {
            parts.append(String(format: "%.2f %@", total, extracted.currency ?? selectedCurrency.code))
        }
        if !extracted.holdings.isEmpty {
            parts.append("\(extracted.holdings.count) holdings")
        }
        guard !parts.isEmpty else { return "Scan complete — review fields below." }
        return "Scanned: " + parts.joined(separator: " · ")
    }

    // MARK: - Holdings Section

    /// Open a holding's symbol in the Apple Stocks app via its universal link.
    /// `https://stocks.apple.com/symbol/<TICKER>` deep-links straight to the
    /// symbol's page (and falls back to in-app search if it's unrecognised).
    /// No-op for rows whose symbol is blank or a multi-word company-name
    /// fallback (scanned rows the user hasn't resolved to a ticker yet).
    private func openInStocks(_ draft: HoldingDraft) {
        let symbol = draft.tickerSymbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !symbol.isEmpty, !symbol.contains(" "),
              let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://stocks.apple.com/symbol/\(encoded)")
        else { return }
        openURL(url)
    }

    private var holdingsSection: some View {
        Group {
            Section {
                if holdings.isEmpty {
                    Text("No holdings yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(holdings) { draft in
                        HoldingDraftRow(draft: draft)
                            .contentShape(Rectangle())
                            // Single tap edits; double tap opens the symbol in
                            // Apple Stocks. (Double-tap handler is declared
                            // first so it wins over the single-tap handler.)
                            .onTapGesture(count: 2) { openInStocks(draft) }
                            .onTapGesture { holdingToEdit = draft }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    holdings.removeAll { $0.id == draft.id }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    holdingToEdit = draft
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
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
                Text("Cash held in this account, separate from your holdings.")
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

    @ViewBuilder
    private var accountTypePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AccountCategory.allCases, id: \.self) { category in
                    let isSelected = selectedCategory == category
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedCategory = category
                            if selectedType.category != category {
                                selectedType = AccountType.allCases.first { $0.category == category } ?? selectedType
                            }
                        }
                    } label: {
                        Text(category.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(isSelected ? Color.accentColor : Color(.secondarySystemFill),
                                        in: Capsule())
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)

        ForEach(AccountType.allCases.filter { $0.category == selectedCategory }, id: \.self) { type in
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedType = type
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: type.systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(type.accentColor)
                        .frame(width: 36, height: 36)
                        .background(
                            type.accentColor.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 9)
                        )

                    Text(type.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)

                    Spacer()

                    if selectedType == type {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(type.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private func prefill() {
        guard let account = editingAccount else { return }
        name = account.name
        institution = account.institution
        selectedType = account.type
        selectedCategory = account.type.category
        selectedCurrency = Currency(rawValue: account.currency) ?? .usd

        if account.type.supportsHoldings {
            // Prefer the explicit cash balance; otherwise (e.g. a pension
            // tracked as a single value with no holdings) fall back to the
            // account's current balance so the value is shown, not 0.
            let cashValue = account.cashBalance > 0 ? account.cashBalance
                : (account.holdings.isEmpty ? account.currentBalance : 0)
            cashBalanceText = cashValue > 0 ? NumberParsing.editableString(cashValue) : ""
            holdings = account.holdings.map {
                HoldingDraft(tickerSymbol: $0.tickerSymbol, quantity: $0.quantity,
                             priceSource: $0.priceSource, isin: $0.isin, existingHolding: $0)
            }
        } else {
            balanceText = NumberParsing.editableString(account.currentBalance)
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
                // Upsert today's (or `balanceDate`'s) snapshot — keeps one row
                // per day per account regardless of how many times the user
                // edits the value. Same-value re-saves no longer churn history.
                account.setBalanceSnapshot(balance: balance, at: balanceDate)
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
                    let h = Holding(tickerSymbol: draft.tickerSymbol, quantity: draft.quantity,
                                    priceSource: draft.priceSource, isin: draft.isin)
                    if draft.lastPrice > 0 {
                        h.lastPrice = draft.lastPrice
                        h.priceCurrency = draft.priceCurrency
                    }
                    account.holdings.append(h)
                }
                account.cashBalance = parsedCashBalance
                account.recomputeBalance()
            } else {
                let balance = parsedBalance ?? 0
                account.setBalanceSnapshot(balance: balance)
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
                if draft.lastPrice > 0 {
                    existing.lastPrice = draft.lastPrice
                    existing.priceCurrency = draft.priceCurrency
                }
            } else {
                // account is already in context — appending auto-inserts the Holding
                let h = Holding(tickerSymbol: draft.tickerSymbol, quantity: draft.quantity,
                                priceSource: draft.priceSource, isin: draft.isin)
                if draft.lastPrice > 0 {
                    h.lastPrice = draft.lastPrice
                    h.priceCurrency = draft.priceCurrency
                }
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
        modelContext.recordNetWorthSnapshot(currency: currencyService ?? CurrencyService(), at: date)
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
