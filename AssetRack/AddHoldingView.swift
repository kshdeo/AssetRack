import SwiftUI
import SwiftData

// MARK: - Holding Draft Row

struct HoldingDraftRow: View {
    let draft: HoldingDraft

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
                let displayPrice    = draft.existingHolding?.lastPrice    ?? draft.lastPrice
                let displayCurrency = draft.existingHolding?.priceCurrency ?? draft.priceCurrency
                if displayPrice > 0 {
                    Text("\(draft.quantity.formatted()) @ \(displayPrice.currencyFormatted(code: displayCurrency, fractionDigits: 2))")
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
            } else if draft.lastPrice > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text((draft.lastPrice * draft.quantity).currencyFormatted(code: draft.priceCurrency, fractionDigits: 2))
                        .font(.subheadline.weight(.semibold))
                    Text("Preview price")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
                Text(holding.value.currencyFormatted(code: holding.priceCurrency, fractionDigits: 2))
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.numericText())

                // Prefer the daily change badge when available — it's the
                // more interesting signal. Fall back to the freshness
                // timestamp (or "Not yet updated") when there's no prior
                // price to compare against.
                if let pct = holding.dailyChangePercent {
                    ChangeBadge(percent: pct)
                } else if let fetchedAt = holding.lastPriceFetchedAt {
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

    var existing: HoldingDraft?
    var onSave: (HoldingDraft) -> Void

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

    // Price preview
    @State private var pricePreview: (price: Double, currency: String)?
    @State private var isPriceFetching = false
    @State private var pricePreviewError: String?
    @State private var pricePreviewTask: Task<Void, Never>?

    private let lookupService = ISINLookupService()

    private var parsedQuantity: Double? { NumberParsing.userNumber(quantityText) }
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
                // Price source — segmented, with an explanatory caption.
                Section {
                    Picker("Price source", selection: $priceSource) {
                        ForEach(PriceSource.allCases, id: \.self) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                } footer: {
                    Text(sourceCaption)
                }
                .onChange(of: priceSource) { _, _ in
                    searchResults = []
                    searchQuery = ""
                    searchError = nil
                }

                searchSection
                searchResultsSection
                tickerQuantitySection
            }
            // Trim the default gap above the first section — the segmented
            // control sat too far below the navigation bar.
            .contentMargins(.top, 8, for: .scrollContent)
            .onChange(of: tickerSymbol) { _, _ in
                if priceSource == .yahooFinance { schedulePricePreview(debounce: true) }
            }
            .onChange(of: isin) { _, _ in
                if priceSource == .tradegate { schedulePricePreview(debounce: false) }
            }
            .onChange(of: priceSource) { _, _ in
                clearPricePreview()
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

    private var hasTicker: Bool {
        !tickerSymbol.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Caption under the segmented source control explaining the active source.
    private var sourceCaption: String {
        switch priceSource {
        case .yahooFinance:
            return "Yahoo Finance — global stocks, ETFs and crypto (e.g. AAPL, VOO, BTC-USD)."
        case .tradegate:
            return "Tradegate — European exchange, prices in EUR. Identified by ISIN."
        }
    }

    // MARK: - Ticker + quantity

    /// Ticker and quantity share one row; quantity stays hidden until a ticker
    /// is set (typed or picked from search), so the form starts minimal. The
    /// live total appears as soon as a quantity and a preview price are known.
    private var tickerQuantitySection: some View {
        Section {
            HStack(spacing: 12) {
                TextField(tickerPlaceholder, text: $tickerSymbol)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)

                if hasTicker {
                    Text("×")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Quantity", text: $quantityText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }

            if priceSource == .tradegate {
                TextField("ISIN (e.g. DE0007664039)", text: $isin)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            }

            pricePreviewRow
            totalRow
        } header: {
            Text(priceSource == .tradegate ? "Holding" : "Ticker")
        } footer: {
            Text(tickerFooter)
        }
    }

    private var tickerPlaceholder: String {
        priceSource == .tradegate ? "Ticker / name (e.g. VOW3)" : "Ticker (e.g. AAPL)"
    }

    private var tickerFooter: String {
        priceSource == .tradegate
            ? "Search above, or enter the ISIN directly. Prices in EUR."
            : "Search above, or type a Yahoo symbol. Crypto: BTC-USD, ETH-USD."
    }

    /// Live total = preview price × quantity, shown the moment both are known.
    @ViewBuilder
    private var totalRow: some View {
        if let qty = parsedQuantity, qty > 0, let preview = pricePreview {
            LabeledContent("Total") {
                Text((preview.price * qty).currencyFormatted(code: preview.currency, fractionDigits: 2))
                    .fontWeight(.semibold)
            }
        }
    }

    // MARK: - Shared search UI

    /// Search input + status footer. Reused by both Yahoo (Finnhub-backed)
    /// and Tradegate. The placeholder adapts to the active source.
    private var searchSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(searchPlaceholder, text: $searchQuery)
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
            } else if !isSearching && searchResults.isEmpty
                        && !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No matching results")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        if !searchResults.isEmpty {
            Section("Results") {
                ForEach(searchResults) { result in
                    Button { selectResult(result) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.description)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Text("\(result.displaySymbol) · \(result.type)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    // .plain so .primary / .secondary text colours win over
                    // the default accent-blue Button tinting inside Forms.
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var searchPlaceholder: String {
        priceSource == .tradegate
            ? "Search by ISIN or name…"
            : "Search by company name or ticker…"
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
        } catch is CancellationError {
            // A newer search superseded this one — not an error
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession was cancelled by task cancellation — not an error
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
        // Clear the search field — an empty query guards early in scheduleSearch,
        // so this dismisses the results list without triggering a new search.
        searchQuery   = ""
        searchResults = []
        if let resolvedISIN = result.resolvedISIN {
            isin = resolvedISIN
        }
        schedulePricePreview(debounce: false)
    }

    // MARK: - Price preview

    @ViewBuilder
    private var pricePreviewRow: some View {
        if isPriceFetching {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.75)
                Text("Fetching price…")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        } else if let (price, currency) = pricePreview {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(price.currencyFormatted(code: currency, fractionDigits: 2))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        } else if let error = pricePreviewError {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.subheadline)
                .foregroundStyle(.red)
        }
    }

    private func schedulePricePreview(debounce: Bool) {
        pricePreviewTask?.cancel()
        clearPricePreview()
        let symbol = tickerSymbol.trimmingCharacters(in: .whitespaces)
        let currentISIN = isin.trimmingCharacters(in: .whitespaces)
        guard (priceSource == .yahooFinance && !symbol.isEmpty) ||
              (priceSource == .tradegate && currentISIN.count == 12) else { return }
        pricePreviewTask = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
            }
            await fetchPricePreview()
        }
    }

    @MainActor
    private func fetchPricePreview() async {
        isPriceFetching = true
        defer { isPriceFetching = false }
        do {
            let result = try await lookupService.previewPrice(
                symbol: tickerSymbol.uppercased().trimmingCharacters(in: .whitespaces),
                source: priceSource,
                isin: isin.trimmingCharacters(in: .whitespaces)
            )
            pricePreview = result
        } catch {
            pricePreviewError = error.localizedDescription
        }
    }

    private func clearPricePreview() {
        pricePreview = nil
        pricePreviewError = nil
    }

    // MARK: - Save

    private func saveHolding() {
        guard let qty = parsedQuantity else { return }
        var draft = HoldingDraft(
            id: existing?.id ?? UUID(),
            tickerSymbol: tickerSymbol.uppercased().trimmingCharacters(in: .whitespaces),
            quantity: qty,
            priceSource: priceSource,
            isin: isin.uppercased().trimmingCharacters(in: .whitespaces),
            existingHolding: existing?.existingHolding
        )
        // Carry the previewed price so the account balance is correct immediately
        if let preview = pricePreview {
            draft.lastPrice = preview.price
            draft.priceCurrency = preview.currency
        }
        onSave(draft)
        dismiss()
    }
}
