import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var fx: FXRateService

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reporting Currency", selection: $fx.baseCurrency) {
                        ForEach(AddEditAccountView.currencies, id: \.code) { currency in
                            Text(currency.label).tag(currency.code)
                        }
                    }
                } header: {
                    Text("Reporting Currency")
                } footer: {
                    Text("All account balances are converted to this currency when calculating your net worth.")
                }

                Section("Exchange Rates") {
                    if fx.isLoading {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 4)
                            Text("Updating rates…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = fx.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                    } else if let date = fx.lastFetched {
                        LabeledContent("Last updated") {
                            Text(date.formatted(.relative(presentation: .named)))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Refresh Now") {
                        Task { await fx.fetch() }
                    }
                    .disabled(fx.isLoading)
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
    SettingsView(fx: FXRateService())
}
