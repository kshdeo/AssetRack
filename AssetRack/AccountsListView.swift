import SwiftUI
import SwiftData

struct AccountsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var accountToEdit: Account?
    @State private var showingAddAccount = false

    @Bindable var currency: CurrencyService
    @Bindable var ticker: TickerService

    private var grouped: [(category: AccountCategory, accounts: [Account])] {
        AccountCategory.allCases.compactMap { category in
            let filtered = accounts.filter { $0.type.category == category }
            guard !filtered.isEmpty else { return nil }
            return (category: category, accounts: filtered)
        }
    }

    var body: some View {
        List {
            ForEach(grouped, id: \.category) { group in
                Section(group.category.rawValue) {
                    ForEach(group.accounts) { account in
                        Button { accountToEdit = account } label: {
                            AccountRow(account: account)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("All Accounts")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddAccount = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddAccount, onDismiss: refreshTickers) {
            AddEditAccountView(tickerService: ticker, currencyService: currency)
        }
        .sheet(item: $accountToEdit, onDismiss: refreshTickers) { account in
            AddEditAccountView(editingAccount: account, tickerService: ticker, currencyService: currency)
        }
        .overlay {
            if accounts.isEmpty {
                ContentUnavailableView(
                    "No Accounts",
                    systemImage: "building.columns",
                    description: Text("Tap + to add your first account.")
                )
            }
        }
    }

    private func refreshTickers() {
        Task { await ticker.fetch(context: modelContext, currency: currency) }
    }
}

#Preview {
    NavigationStack {
        AccountsListView(currency: CurrencyService(), ticker: TickerService())
            .modelContainer(ModelContainer.previewContainer)
    }
}
