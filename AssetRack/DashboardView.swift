import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Query private var accounts: [Account]

    @Environment(\.modelContext) private var modelContext
    @State private var vm = DashboardViewModel()
    @State private var currencyService = CurrencyService()
    @State private var ticker = TickerService()
    @State private var selectedDate: Date?
    @State private var showingAllAccounts = false
    @State private var showingAddAccount = false
    @State private var showingSettings = false
    @State private var showingProjection = false
    @State private var accountToEdit: Account?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 10) {
                        NetWorthHeroCard(
                            netWorth: vm.netWorth.amount,
                            totalAssets: vm.totalAssets.amount,
                            totalLiabilities: vm.totalLiabilities.amount,
                            todaysGain: vm.todaysGain,
                            currencyService: currencyService
                        )

                        TrendStrip(
                            weekDelta: vm.weekDelta,
                            monthDelta: vm.monthDelta,
                            yearDelta: vm.yearDelta
                        )
                    }

                    NetWorthChartCard(
                        stackedData: vm.stackedData,
                        historyEntries: vm.historyEntries,
                        currencyService: currencyService,
                        selectedDate: $selectedDate
                    )

                    AllocationCard(segments: vm.allocationSegments)

                    ProjectionTeaserCard(
                        accounts: accounts,
                        currencyService: currencyService,
                        onTap: { showingProjection = true }
                    )

                    AccountsCard(
                        accounts: vm.topAccounts,
                        totalCount: accounts.count,
                        currencyService: currencyService,
                        onSeeAll: { showingAllAccounts = true },
                        onEdit: { accountToEdit = $0 }
                    )

                    if let lastUpdated = lastUpdated {
                        Text("Last updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .task(id: DashboardViewModel.dataKey(accounts: accounts, currency: currencyService)) {
                vm.recalculate(accounts: accounts, currency: currencyService)
            }
            .refreshable {
                // Wrap in an unstructured Task so the network requests are not
                // subject to the refreshable's cooperative cancellation. SwiftUI
                // can cancel the refreshable Task mid-scroll, which would
                // propagate into URLSession and produce NSURLError -999.
                let work = Task { @MainActor in
                    await currencyService.fetch()
                    await ticker.fetch(context: modelContext, currency: currencyService)
                    modelContext.recordNetWorthSnapshot(currency: currencyService)
                    try? modelContext.save()
                }
                await work.value
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Net Worth")
            .navigationDestination(isPresented: $showingAllAccounts) {
                AccountsListView(currency: currencyService, ticker: ticker)
            }
            .navigationDestination(isPresented: $showingProjection) {
                ProjectionView(currencyService: currencyService)
            }
            .task {
                await currencyService.fetchIfNeeded()
                await ticker.fetchIfNeeded(context: modelContext, currency: currencyService)
            }
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showingSettings) {
                SettingsView(currency: currencyService)
            }
            .sheet(isPresented: $showingAddAccount, onDismiss: refreshTickers) {
                AddEditAccountView(tickerService: ticker, currencyService: currencyService)
            }
            .sheet(item: $accountToEdit, onDismiss: refreshTickers) { account in
                AddEditAccountView(editingAccount: account, tickerService: ticker, currencyService: currencyService)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddAccount = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }
}

// MARK: - DashboardView helpers

extension DashboardView {
    /// Most recent fetch across the two refreshable services. Reading both
    /// `lastFetched`s inside the view body makes Observation track them, so the
    /// "Last updated" footer auto-refreshes when either fires.
    var lastUpdated: Date? {
        [currencyService.lastFetched, ticker.lastFetched]
            .compactMap { $0 }
            .max()
    }

    func refreshTickers() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            await ticker.fetch(context: modelContext, currency: currencyService)
            modelContext.recordNetWorthSnapshot(currency: currencyService)
            try? modelContext.save()
        }
    }
}

// MARK: - Trend Strip

/// Thin, transparent row of period deltas. Lives outside the hero card to keep
/// the hero calm — Direction C in the design exploration.
struct TrendStrip: View {
    let weekDelta: Double?
    let monthDelta: Double?
    let yearDelta: Double?

    private var hasContent: Bool {
        weekDelta != nil || monthDelta != nil || yearDelta != nil
    }

    var body: some View {
        if hasContent {
            HStack(spacing: 16) {
                if let d = weekDelta  { ChangeBadge(percent: d, label: "w/w") }
                if let d = monthDelta { ChangeBadge(percent: d, label: "m/m") }
                if let d = yearDelta  { ChangeBadge(percent: d, label: "y/y") }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Hero Card

struct NetWorthHeroCard: View {
    let netWorth: Double
    let totalAssets: Double
    let totalLiabilities: Double
    let todaysGain: DashboardViewModel.TodaysGain?
    let currencyService: CurrencyService

    var body: some View {
        VStack(spacing: 6) {
            Text(currencyService.formattedBase(netWorth))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.4), value: netWorth)

            if let gain = todaysGain {
                todaysGainRow(gain)
            }

            Divider().padding(.vertical, 4)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Assets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(currencyService.formattedBase(totalAssets))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Liabilities")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(currencyService.formattedBase(totalLiabilities))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Absolute gain since the last snapshot, shown directly under the main value.
    /// Sign is always rendered ("+" / "−") and colour-coded so the direction is
    /// obvious at a glance regardless of locale formatting quirks for negatives.
    @ViewBuilder
    private func todaysGainRow(_ gain: DashboardViewModel.TodaysGain) -> some View {
        let isUp = gain.amount >= 0
        let sign = isUp ? "+" : "−"
        HStack(spacing: 6) {
            Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
            Text("\(sign)\(currencyService.formattedBase(abs(gain.amount)))")
                .contentTransition(.numericText())
            if let percent = gain.percent {
                Text("(\(percent, format: .percent.precision(.fractionLength(2))))")
                    .foregroundStyle(.secondary)
            }
            Text("today")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(isUp ? Color.green : Color.red)
    }
}

// MARK: - Chart Card

struct NetWorthChartCard: View {
    let stackedData: [StackedDataPoint]
    let historyEntries: [DashboardViewModel.AccountHistoryEntry]
    let currencyService: CurrencyService
    @Binding var selectedDate: Date?

    @State private var showingHistory = false

    private var currency: String { currencyService.baseCurrency }

    // Unique dates in ascending order
    private var sortedDates: [Date] {
        Array(Set(stackedData.map { $0.date })).sorted()
    }

    // The date to highlight in the header (scrubbed or latest)
    private var displayDate: Date? {
        selectedDate ?? sortedDates.last
    }

    // Net worth for the display date: assets − liabilities, all carry-forward
    private var displayValue: Double {
        guard let date = displayDate else { return 0 }
        return historyEntries.first(where: { $0.date == date })?.totalInBase ?? 0
    }

    // Colors keyed by category raw value for chartForegroundStyleScale
    private static let categoryColors: KeyValuePairs<String, Color> = [
        AccountCategory.cashAndBank.rawValue: .teal,
        AccountCategory.investments.rawValue: .blue,
        AccountCategory.pension.rawValue:     .purple,
        AccountCategory.realEstate.rawValue:  .indigo,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                Button { showingHistory = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 10)

            if stackedData.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "chart.line.uptrend.xyaxis")
                    .frame(height: 180)
            } else {
                // Header: total + date, updates while scrubbing
                VStack(alignment: .leading, spacing: 1) {
                    Text(currencyService.formattedBase(displayValue))
                        .font(.title3.weight(.semibold))
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.1), value: displayValue)

                    if let date = displayDate {
                        Text(date.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 12)

                Chart(stackedData) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        yStart: .value("Start", point.stackedStart),
                        yEnd: .value("End", point.stackedEnd)
                    )
                    .foregroundStyle(by: .value("Category", point.category.rawValue))
                    .interpolationMethod(.linear)

                    if let selected = selectedDate {
                        RuleMark(x: .value("Selected", selected))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .chartForegroundStyleScale(Self.categoryColors)
                .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .frame(height: 200)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { drag in
                                        guard let plotFrame = proxy.plotFrame else { return }
                                        let origin = geo[plotFrame].origin
                                        let x = drag.location.x - origin.x
                                        if let date: Date = proxy.value(atX: x) {
                                            withAnimation(.none) {
                                                selectedDate = sortedDates.min {
                                                    abs($0.timeIntervalSince(date)) <
                                                    abs($1.timeIntervalSince(date))
                                                }
                                            }
                                        }
                                    }
                                    .onEnded { _ in
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            selectedDate = nil
                                        }
                                    }
                            )
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $showingHistory) {
            NetWorthHistoryView(entries: historyEntries, currencyService: currencyService)
        }
    }
}

// MARK: - Net Worth History (date list)

struct NetWorthHistoryView: View {
    @Environment(\.dismiss) private var dismiss

    let entries: [DashboardViewModel.AccountHistoryEntry]
    let currencyService: CurrencyService

    @State private var showingAddEntry = false

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("No history yet", systemImage: "clock.arrow.circlepath")
                } else {
                    List {
                        ForEach(entries) { entry in
                            NavigationLink {
                                HistoryDayDetailView(entry: entry, currencyService: currencyService)
                            } label: {
                                HStack {
                                    Text(entry.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                        .font(.subheadline)
                                    Spacer()
                                    Text(currencyService.formattedBase(entry.totalInBase))
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Balance History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAddEntry = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddEntry) {
                AddHistoricalEntryView(currencyService: currencyService)
            }
        }
    }
}

// MARK: - History Day Detail (per-account balances, all editable)

struct HistoryDayDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let entry: DashboardViewModel.AccountHistoryEntry
    let currencyService: CurrencyService

    @State private var date: Date
    @State private var balanceTexts: [UUID: String] = [:]

    init(entry: DashboardViewModel.AccountHistoryEntry, currencyService: CurrencyService) {
        self.entry = entry
        self.currencyService = currencyService
        _date = State(initialValue: entry.date)
    }

    // Only rows that have an exact snapshot for this day can be edited or date-shifted.
    private var editableRows: [DashboardViewModel.AccountHistoryEntry.AccountRow] {
        entry.rows.filter { !$0.isCarriedForward }
    }

    private var hasChanges: Bool {
        if date != entry.date { return true }
        return editableRows.contains { row in
            guard let text = balanceTexts[row.id],
                  let value = Double(text.replacingOccurrences(of: ",", with: "")) else { return false }
            return value != row.balance
        }
    }

    private var liveTotal: Double {
        let amounts: [Money] = entry.rows.map { row in
            let balance: Double
            if row.isCarriedForward {
                balance = row.balance
            } else if let text = balanceTexts[row.id],
                      let value = Double(text.replacingOccurrences(of: ",", with: "")) {
                balance = value
            } else {
                balance = row.balance
            }
            let signed = row.isLiability ? -balance : balance
            return Money(signed, row.currency)
        }
        return currencyService.sum(amounts, in: currencyService.baseCurrency).amount
    }

    var body: some View {
        Form {
            Section {
                DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: [.date])
                LabeledContent("Net Worth") {
                    Text(currencyService.formattedBase(liveTotal))
                        .font(.headline)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.15), value: liveTotal)
                }
            }

            Section {
                ForEach(entry.rows) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.accountName)
                                .font(.subheadline)
                                .foregroundStyle(row.isCarriedForward ? .secondary : .primary)
                            Text(row.currency)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if row.isCarriedForward {
                            Text(currencyService.formatted(Money(row.balance, row.currency)))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            TextField("0", text: Binding(
                                get: { balanceTexts[row.id] ?? "" },
                                set: { balanceTexts[row.id] = $0 }
                            ))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                            .foregroundStyle(row.isLiability ? .red : .primary)
                        }
                    }
                }
            } header: {
                Text("Account Balances")
            } footer: {
                if entry.rows.contains(where: { $0.isCarriedForward }) {
                    Text("Greyed values are carried forward from a previous date and cannot be edited here.")
                }
            }
        }
        .navigationTitle(entry.date.formatted(.dateTime.month(.abbreviated).day().year()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!hasChanges)
            }
        }
        .onAppear {
            for row in editableRows {
                balanceTexts[row.id] = String(format: "%.2f", row.balance)
            }
        }
    }

    private func save() {
        let cal = Calendar.current
        for row in editableRows {
            guard let snapshot = row.snapshot else { continue }
            if let text = balanceTexts[row.id],
               let value = Double(text.replacingOccurrences(of: ",", with: "")) {
                snapshot.balance = value
            }
            // Preserve time-of-day, only shift the calendar date
            let originalTime = snapshot.recordedAt
            snapshot.recordedAt = cal.date(
                bySettingHour: cal.component(.hour, from: originalTime),
                minute: cal.component(.minute, from: originalTime),
                second: cal.component(.second, from: originalTime),
                of: date
            ) ?? date
        }
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Allocation Card

struct AllocationCard: View {
    let segments: [DashboardViewModel.AllocationSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Asset Allocation")
                .font(.headline)

            if segments.isEmpty {
                Text("No assets yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(segments) { seg in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(color(for: seg.color))
                                .frame(width: geo.size.width * seg.value)
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(spacing: 6) {
                    ForEach(segments) { seg in
                        HStack {
                            Circle()
                                .fill(color(for: seg.color))
                                .frame(width: 8, height: 8)
                            Text(seg.category.rawValue)
                                .font(.subheadline)
                            Spacer()
                            Text(seg.value, format: .percent.precision(.fractionLength(1)))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func color(for name: String) -> Color {
        switch name {
        case "teal":   return .teal
        case "blue":   return .blue
        case "purple": return .purple
        case "indigo": return .indigo
        case "red":    return .red
        default:       return .gray
        }
    }
}

// MARK: - Projection Teaser Card

/// Compact teaser shown on the dashboard. Reuses `ProjectionViewModel` and the
/// `.projectionData(...)` modifier so the dataKey / recalculate plumbing lives
/// in one place — see CLAUDE.md rule #8.
struct ProjectionTeaserCard: View {
    @Query private var settingsList: [ProjectionSettings]
    let accounts: [Account]
    let currencyService: CurrencyService
    let onTap: () -> Void

    @State private var vm = ProjectionViewModel()

    private var settings: ProjectionSettings? { settingsList.first }
    private var horizon: Int { settings?.horizonYears ?? 10 }

    var body: some View {
        let delta = vm.endNetWorth - vm.startNetWorth

        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(.purple)
                        Text("In \(horizon) years")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    Text(currencyService.formattedBase(vm.endNetWorth))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    if vm.startNetWorth > 0 || vm.endNetWorth > 0 {
                        Text("\(delta >= 0 ? "Up" : "Down") \(currencyService.formattedBase(abs(delta))) from today")
                            .font(.caption)
                            .foregroundStyle(delta >= 0 ? .green : .red)
                    } else {
                        Text("Add accounts to see your trajectory")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .projectionData(
            vm: vm,
            accounts: accounts,
            settings: settings,
            horizonYears: horizon,
            currencyService: currencyService
        )
    }
}

// MARK: - Accounts Card

struct AccountsCard: View {
    let accounts: [Account]
    let totalCount: Int
    let currencyService: CurrencyService
    let onSeeAll: () -> Void
    let onEdit: (Account) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Accounts")
                    .font(.headline)
                Spacer()
                if totalCount > 10 {
                    Button("See All (\(totalCount))", action: onSeeAll)
                        .font(.subheadline)
                }
            }

            if accounts.isEmpty {
                Text("Add an account to get started")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        Button { onEdit(account) } label: {
                            AccountRow(account: account, currencyService: currencyService)
                        }
                        .buttonStyle(.plain)

                        if index < accounts.count - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Preview

#Preview {
    DashboardView()
        .modelContainer(ModelContainer.previewContainer)
}
