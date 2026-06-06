import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var currency: CurrencyService

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
                } header: {
                    Text("Data")
                } footer: {
                    Text("Export saves all accounts and holdings to a JSON file. Import replaces all existing accounts.")
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
                    Text("This will replace all \(accountCount) existing accounts with \(backup.accounts.count) accounts from the backup file.")
                }
            }
        }
    }

    private var accountCount: Int {
        (try? modelContext.fetch(FetchDescriptor<Account>()))?.count ?? 0
    }

    // MARK: - Export

    private func exportData() {
        exportError = nil
        do {
            let accounts = try modelContext.fetch(FetchDescriptor<Account>())
            let backup = AppBackup.from(accounts: accounts)
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
            // Delete all existing accounts (cascade removes holdings + history)
            let existing = try modelContext.fetch(FetchDescriptor<Account>())
            for account in existing { modelContext.delete(account) }

            // Insert accounts from backup
            for ab in backup.accounts {
                let account = Account(
                    name: ab.name,
                    type: AccountType(rawValue: ab.type) ?? .checking,
                    balance: ab.currentBalance,
                    institution: ab.institution,
                    currency: ab.currency
                )
                account.cashBalance = ab.cashBalance
                modelContext.insert(account)

                for hb in ab.holdings {
                    let holding = Holding(tickerSymbol: hb.tickerSymbol, quantity: hb.quantity)
                    holding.lastPrice = hb.lastPrice
                    holding.priceCurrency = hb.priceCurrency
                    account.holdings.append(holding)
                }
            }

            try modelContext.save()
            pendingBackup = nil
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
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
