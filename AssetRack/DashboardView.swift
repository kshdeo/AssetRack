import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Query private var accounts: [Account]
    @Query(sort: \NetWorthSnapshot.recordedAt) private var snapshots: [NetWorthSnapshot]

    @Environment(\.modelContext) private var modelContext
    @State private var vm = DashboardViewModel()
    @State private var currencyService = CurrencyService()
    @State private var ticker = TickerService()
    @State private var selectedSnapshot: NetWorthSnapshot?
    @State private var showingAllAccounts = false
    @State private var showingAddAccount = false
    @State private var showingSettings = false
    @State private var accountToEdit: Account?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    let netWorth = vm.netWorth(from: accounts, currency: currencyService)
                    let totalAssets = vm.totalAssets(from: accounts, currency: currencyService)
                    let totalLiabilities = vm.totalLiabilities(from: accounts, currency: currencyService)

                    NetWorthHeroCard(
                        netWorth: netWorth.amount,
                        totalAssets: totalAssets.amount,
                        totalLiabilities: totalLiabilities.amount,
                        delta: vm.monthOverMonthDelta(from: snapshots),
                        currency: currencyService.baseCurrency
                    )

                    NetWorthChartCard(
                        snapshots: snapshots,
                        selectedSnapshot: $selectedSnapshot
                    )

                    AllocationCard(segments: vm.allocationSegments(from: accounts, currency: currencyService))

                    AccountsCard(
                        accounts: vm.topAccounts(from: accounts),
                        totalCount: accounts.count,
                        onSeeAll: { showingAllAccounts = true },
                        onEdit: { accountToEdit = $0 }
                    )
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .refreshable {
                // Wrap in an unstructured Task so the network requests are not
                // subject to the refreshable's cooperative cancellation. SwiftUI
                // can cancel the refreshable Task mid-scroll, which would
                // propagate into URLSession and produce NSURLError -999.
                let work = Task {
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
    func refreshTickers() {
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await ticker.fetch(context: modelContext, currency: currencyService)
            modelContext.recordNetWorthSnapshot(currency: currencyService)
            try? modelContext.save()
        }
    }
}

// MARK: - Hero Card

struct NetWorthHeroCard: View {
    let netWorth: Double
    let totalAssets: Double
    let totalLiabilities: Double
    let delta: Double?
    var currency: String = "USD"

    var body: some View {
        VStack(spacing: 6) {
            Text("Total Net Worth")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(netWorth.currencyFormatted(code: currency))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.4), value: netWorth)

            if let delta {
                HStack(spacing: 4) {
                    Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                    Text("\(abs(delta), format: .percent.precision(.fractionLength(1))) vs last month")
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(delta >= 0 ? Color.green : Color.red)
            }

            Divider().padding(.vertical, 4)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Assets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(totalAssets.currencyFormatted(code: currency))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Liabilities")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(totalLiabilities.currencyFormatted(code: currency))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Chart Card

struct NetWorthChartCard: View {
    let snapshots: [NetWorthSnapshot]
    @Binding var selectedSnapshot: NetWorthSnapshot?

    private var sorted: [NetWorthSnapshot] {
        // One point per calendar day — keep the latest snapshot for each day
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: snapshots) {
            calendar.startOfDay(for: $0.recordedAt)
        }
        return grouped
            .values
            .compactMap { $0.max(by: { $0.recordedAt < $1.recordedAt }) }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    /// Green when net worth is flat or rising, red when falling.
    private var trendColor: Color {
        guard let first = sorted.first, let last = sorted.last else { return .green }
        return last.netWorth >= first.netWorth ? .green : .red
    }

    private var displayedValue: Double {
        selectedSnapshot?.netWorth ?? sorted.last?.netWorth ?? 0
    }

    private var displayedDate: Date? {
        selectedSnapshot?.recordedAt ?? sorted.last?.recordedAt
    }

    @State private var showingHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                Button {
                    showingHistory = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 10)

            if sorted.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "chart.line.uptrend.xyaxis")
                    .frame(height: 180)
            } else {
                // Value + date header — updates while scrubbing
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayedValue.currencyFormatted(code: sorted.last?.currency ?? "USD"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(selectedSnapshot == nil ? .primary : trendColor)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.1), value: displayedValue)

                    if let date = displayedDate {
                        Text(date.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 12)

                Chart(sorted) { snap in
                    // Subtle gradient fill below the line
                    AreaMark(
                        x: .value("Date", snap.recordedAt),
                        y: .value("Net Worth", snap.netWorth)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [trendColor.opacity(0.15), trendColor.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.linear)

                    // Main line
                    LineMark(
                        x: .value("Date", snap.recordedAt),
                        y: .value("Net Worth", snap.netWorth)
                    )
                    .foregroundStyle(trendColor)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    // Scrub: vertical rule + dot
                    if let selected = selectedSnapshot {
                        RuleMark(x: .value("Date", selected.recordedAt))
                            .foregroundStyle(.secondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1))

                        if selected.id == snap.id {
                            PointMark(
                                x: .value("Date", snap.recordedAt),
                                y: .value("Net Worth", snap.netWorth)
                            )
                            .foregroundStyle(trendColor)
                            .symbolSize(60)
                        }
                    }
                }
                // Don't anchor to zero — zoom into the actual range so movement is visible
                .chartYScale(domain: .automatic(includesZero: false))
                // Hide y-axis labels; the value is shown above
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .frame(height: 180)
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
                                                selectedSnapshot = sorted.min {
                                                    abs($0.recordedAt.timeIntervalSince(date)) <
                                                    abs($1.recordedAt.timeIntervalSince(date))
                                                }
                                            }
                                        }
                                    }
                                    .onEnded { _ in
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            selectedSnapshot = nil
                                        }
                                    }
                            )
                    }
                }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $showingHistory) {
            NetWorthHistoryView()
        }
    }
}

// MARK: - Net Worth History

struct NetWorthHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \NetWorthSnapshot.recordedAt, order: .reverse) private var snapshots: [NetWorthSnapshot]

    var body: some View {
        NavigationStack {
            List {
                ForEach(snapshots) { snap in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snap.recordedAt.formatted(.dateTime.month(.abbreviated).day().year()))
                                .font(.subheadline)
                            Text(snap.recordedAt.formatted(.dateTime.hour().minute()))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(snap.netWorth.currencyFormatted(code: snap.currency))
                            .font(.subheadline.weight(.medium))
                    }
                }
                .onDelete { indices in
                    for index in indices {
                        modelContext.delete(snapshots[index])
                    }
                    try? modelContext.save()
                }
            }
            .navigationTitle("Net Worth History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
        }
    }
}

// MARK: - Allocation Card

struct AllocationCard: View {
    let segments: [(category: AccountCategory, value: Double, color: String)]

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
                        ForEach(segments, id: \.category) { seg in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(color(for: seg.color))
                                .frame(width: geo.size.width * seg.value)
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(spacing: 6) {
                    ForEach(segments, id: \.category) { seg in
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
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
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

// MARK: - Accounts Card

struct AccountsCard: View {
    let accounts: [Account]
    let totalCount: Int
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
                            AccountRow(account: account)
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
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.type.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(account.isLiability ? .red : .blue)
                .frame(width: 32, height: 32)
                .background(
                    (account.isLiability ? Color.red : Color.blue).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 4) {
                    Text(account.type.displayName)
                    if account.hasHoldings {
                        Text("·")
                        Text("^[\(account.holdings.count) holding](inflect: true)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(account.currentBalance.currencyFormatted(code: account.currency))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(account.isLiability ? .red : .primary)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Preview

#Preview {
    DashboardView()
        .modelContainer(ModelContainer.previewContainer)
}
