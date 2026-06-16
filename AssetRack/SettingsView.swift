import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var currency: CurrencyService

    @Environment(BiometricLockService.self) private var lockService
    @AppStorage(ISINLookupService.apiKeyDefaultsKey) private var finnhubApiKey = ""
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    // Export
    @State private var exportURL: URL?
    @State private var exportError: String?

    // Import
    @State private var showingImportPicker = false
    @State private var pendingBackup: AppBackup?
    @State private var importError: String?
    @State private var showingImportConfirm = false

    // CSV import
    @State private var showingCSVPicker = false
    @State private var pendingCSV: CSVImportResult?
    @State private var csvError: String?
    @State private var showingCSVConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Currency
                Section {
                    Picker("Currency", selection: $currency.baseCurrency) {
                        ForEach(Currency.allCases, id: \.self) { c in
                            Text(c.label).tag(c.rawValue)
                        }
                    }
                } header: {
                    Text("Currency")
                } footer: {
                    Text("All account balances are converted to this currency when calculating your net worth.")
                }

                // MARK: Exchange Rates
                Section("Exchange Rates") {
                    if currency.isLoading {
                        HStack {
                            ProgressView().padding(.trailing, 4)
                            Text("Updating rates…").foregroundStyle(.secondary)
                        }
                    } else if let error = currency.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                    } else if let date = currency.lastFetched {
                        LabeledContent("Last updated") {
                            Text(date.formatted(.relative(presentation: .named)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Refresh Now") {
                        Task { await currency.fetch() }
                    }
                    .disabled(currency.isLoading)
                }

                // MARK: Security
                Section {
                    @Bindable var lock = lockService
                    Toggle(isOn: $lock.isEnabled) {
                        Label(securityToggleLabel, systemImage: securityToggleIcon)
                    }
                    .disabled(!lockService.canUseLock)
                } header: {
                    Text("Security")
                } footer: {
                    if lockService.canUseLock {
                        Text("Require authentication when returning to the app after it moves to the background.")
                    } else {
                        Text("Set up a passcode in iPhone Settings to enable the app lock.")
                    }
                }

                // MARK: Integrations
                Section {
                    HStack {
                        Text("Finnhub API Key")
                        Spacer()
                        SecureField("Paste key here", text: $finnhubApiKey)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("Integrations")
                } footer: {
                    Text("Used to search securities and auto-fill ISINs when adding Tradegate holdings. Get a free key at finnhub.io.")
                }

                // MARK: Data
                Section {
                    // Export
                    Button {
                        exportData()
                    } label: {
                        Label("Export Data", systemImage: "square.and.arrow.up")
                    }

                    if let error = exportError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }

                    // Import
                    Button {
                        showingImportPicker = true
                    } label: {
                        Label("Import Data", systemImage: "square.and.arrow.down")
                    }

                    if let error = importError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }

                    // Import from CSV
                    Button {
                        showingCSVPicker = true
                    } label: {
                        Label("Import from CSV", systemImage: "tablecells")
                    }

                    if let error = csvError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Export saves your accounts, holdings, balance history, net-worth history, and projection assumptions to a JSON file. Import replaces all existing data.\n\nImport from CSV adds accounts and holdings from a spreadsheet. Each row is an account (name, type, balance) or a holding (symbol, quantity, price); holdings attach to the account named in their row or the account row above them.")
                }

                // MARK: About
                Section {
                    Button {
                        // Dismiss Settings first, then flip the flag — otherwise the
                        // dashboard underneath would swap to OnboardingView while
                        // this sheet is still on top.
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            hasCompletedOnboarding = false
                        }
                    } label: {
                        Label("Show Welcome Tour", systemImage: "sparkles")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("Re-runs the first-launch tour. Your accounts and data stay untouched.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Share sheet for export
            .sheet(item: $exportURL) { url in
                ActivityShareSheet(url: url)
                    .ignoresSafeArea()
            }
            // File picker for import
            .fileImporter(
                isPresented: $showingImportPicker,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImportPick(result)
            }
            // Confirmation before replacing data
            .confirmationDialog(
                "Replace all data?",
                isPresented: $showingImportConfirm,
                titleVisibility: .visible
            ) {
                Button("Import", role: .destructive) { commitImport() }
            } message: {
                if let backup = pendingBackup {
                    Text(importConfirmMessage(for: backup))
                }
            }
            // File picker for CSV import
            .fileImporter(
                isPresented: $showingCSVPicker,
                allowedContentTypes: [.commaSeparatedText, .plainText],
                allowsMultipleSelection: false
            ) { result in
                handleCSVPick(result)
            }
            // Confirmation before adding CSV data (additive, not destructive)
            .confirmationDialog(
                "Import from CSV?",
                isPresented: $showingCSVConfirm,
                titleVisibility: .visible
            ) {
                Button("Add to my accounts") { commitCSVImport() }
            } message: {
                if let csv = pendingCSV {
                    Text(csvConfirmMessage(for: csv))
                }
            }
        }
    }

    private var securityToggleLabel: String {
        switch lockService.biometryType {
        case .faceID:   return "Face ID Lock"
        case .touchID:  return "Touch ID Lock"
        default:        return "Passcode Lock"
        }
    }

    private var securityToggleIcon: String {
        switch lockService.biometryType {
        case .faceID:   return "faceid"
        case .touchID:  return "touchid"
        default:        return "lock.fill"
        }
    }

    private var accountCount: Int {
        (try? modelContext.fetch(FetchDescriptor<Account>()))?.count ?? 0
    }

    /// Human-readable summary of what an import will replace — driven by what's
    /// actually in the backup file so v1 (accounts only) and v2 (history +
    /// projection) read accurately.
    private func importConfirmMessage(for backup: AppBackup) -> String {
        var parts = ["\(backup.accounts.count) accounts"]
        let snapshotCount = backup.accounts.reduce(0) { $0 + ($1.balanceHistory?.count ?? 0) }
        if snapshotCount > 0 {
            parts.append("\(snapshotCount) history entries")
        }
        if let nw = backup.netWorthSnapshots, !nw.isEmpty {
            parts.append("\(nw.count) net-worth snapshots")
        }
        if backup.projectionSettings != nil {
            parts.append("projection assumptions")
        }
        let summary = parts.joined(separator: ", ")
        return "This will replace your current data (\(accountCount) accounts) with \(summary) from the backup file."
    }

    // MARK: - Export

    private func exportData() {
        exportError = nil
        do {
            // The full SwiftData state. `balanceHistory` rides along with each
            // account via its relationship; net-worth snapshots and projection
            // settings live in their own stores.
            let accounts = try modelContext.fetch(FetchDescriptor<Account>())
            let netWorthSnapshots = try modelContext.fetch(FetchDescriptor<NetWorthSnapshot>())
            let projection = modelContext.projectionSettings()

            let backup = AppBackup.from(
                accounts: accounts,
                netWorthSnapshots: netWorthSnapshots,
                projectionSettings: projection
            )
            exportURL = try backup.writeToTempFile()
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Import

    private func handleImportPick(_ result: Result<[URL], Error>) {
        importError = nil
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Could not access the selected file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let data = try Data(contentsOf: url)
            pendingBackup = try AppBackup.decode(from: data)
            showingImportConfirm = true
        } catch {
            importError = "Could not read file: \(error.localizedDescription)"
        }
    }

    private func commitImport() {
        guard let backup = pendingBackup else { return }
        importError = nil
        do {
            // 1. Wipe accounts (cascade removes holdings + balance history) and
            //    net-worth snapshots. Projection settings are a singleton — we
            //    overwrite its fields rather than re-inserting.
            let existingAccounts = try modelContext.fetch(FetchDescriptor<Account>())
            for account in existingAccounts { modelContext.delete(account) }

            let existingNetWorth = try modelContext.fetch(FetchDescriptor<NetWorthSnapshot>())
            for snap in existingNetWorth { modelContext.delete(snap) }

            // 2. Re-create accounts, holdings, and per-account history.
            for ab in backup.accounts {
                let account = Account(
                    name: ab.name,
                    type: AccountType(rawValue: ab.type) ?? .checking,
                    balance: ab.currentBalance,
                    institution: ab.institution,
                    currency: ab.currency
                )
                account.cashBalance = ab.cashBalance
                if let createdAt = ab.createdAt { account.createdAt = createdAt }
                if let updatedAt = ab.updatedAt { account.updatedAt = updatedAt }
                modelContext.insert(account)

                for hb in ab.holdings {
                    let holding = Holding(tickerSymbol: hb.tickerSymbol, quantity: hb.quantity)
                    holding.lastPrice = hb.lastPrice
                    holding.priceCurrency = hb.priceCurrency
                    if let name = hb.name { holding.name = name }
                    if let isin = hb.isin { holding.isin = isin }
                    if let src = hb.priceSourceRaw { holding.priceSourceRaw = src }
                    if let prev = hb.previousClose { holding.previousClose = prev }
                    holding.lastPriceFetchedAt = hb.lastPriceFetchedAt
                    account.holdings.append(holding)
                }

                // v2 — per-account history. Append to the relationship so
                // SwiftData auto-inserts each snapshot under the parent (no
                // explicit insert, per Rule #5).
                for bs in ab.balanceHistory ?? [] {
                    account.balanceHistory.append(
                        BalanceSnapshot(balance: bs.balance, recordedAt: bs.recordedAt)
                    )
                }
            }

            // 3. v2 — net-worth snapshots.
            for ns in backup.netWorthSnapshots ?? [] {
                let snap = NetWorthSnapshot(
                    netWorth: ns.netWorth,
                    totalAssets: ns.totalAssets,
                    totalLiabilities: ns.totalLiabilities,
                    currency: ns.currency,
                    recordedAt: ns.recordedAt
                )
                modelContext.insert(snap)
            }

            // 4. v2 — projection settings. Singleton: fetch (creates on first
            // access) and overwrite fields in place.
            if let ps = backup.projectionSettings {
                let settings = modelContext.projectionSettings()
                settings.cashRate              = ps.cashRate
                settings.investmentsRate       = ps.investmentsRate
                settings.pensionRate           = ps.pensionRate
                settings.realEstateRate        = ps.realEstateRate
                settings.liabilityPaydownYears = ps.liabilityPaydownYears
                settings.monthlyIncome         = ps.monthlyIncome
                settings.monthlyExpenses       = ps.monthlyExpenses
                settings.horizonYears          = ps.horizonYears
            }

            try modelContext.save()
            pendingBackup = nil
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: - CSV import

    private func csvConfirmMessage(for csv: CSVImportResult) -> String {
        var parts = ["\(csv.accountCount) accounts"]
        if csv.holdingCount > 0 { parts.append("\(csv.holdingCount) holdings") }
        var msg = "This will add \(parts.joined(separator: " and ")) to your existing data."
        if !csv.warnings.isEmpty {
            let shown = csv.warnings.prefix(3).joined(separator: "\n")
            let extra = csv.warnings.count > 3 ? "\n…and \(csv.warnings.count - 3) more." : ""
            msg += "\n\nNotes:\n\(shown)\(extra)"
        }
        return msg
    }

    private func handleCSVPick(_ result: Result<[URL], Error>) {
        csvError = nil
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                csvError = "Could not access the selected file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                csvError = "Could not read the file as text."
                return
            }
            let parsed = try CSVAccountImporter.parse(text, defaultCurrency: currency.baseCurrency)
            guard parsed.accountCount > 0 else {
                csvError = "No accounts or holdings found in the file."
                return
            }
            pendingCSV = parsed
            showingCSVConfirm = true
        } catch let error as CSVImportError {
            csvError = error.errorDescription
        } catch {
            csvError = "Could not read file: \(error.localizedDescription)"
        }
    }

    private func commitCSVImport() {
        guard let parsed = pendingCSV else { return }
        csvError = nil
        CSVAccountImporter.commit(parsed, into: modelContext, currency: currency)
        pendingCSV = nil
    }
}

// MARK: - Share sheet wrapper

/// Wraps UIActivityViewController for the system share sheet.
/// URL conforms to Identifiable so it can be used with .sheet(item:).
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    SettingsView(currency: CurrencyService())
        .modelContainer(ModelContainer.previewContainer)
}
