import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var currency: CurrencyService

    var body: some View {
        NavigationStack {
            Form {
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

                Section("Exchange Rates") {
                    if currency.isLoading {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 4)
                            Text("Updating rates…")
                                .foregroundStyle(.secondary)
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
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView(currency: CurrencyService())
}
