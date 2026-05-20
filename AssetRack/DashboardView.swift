import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Query private var accounts: [Account]
    @Query(sort: \NetWorthSnapshot.recordedAt) private var snapshots: [NetWorthSnapshot]

    @Environment(\.modelContext) private var modelContext
    @State private var vm = DashboardViewModel()
    @State private var fx = FXRateService()
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
                    NetWorthHeroCard(
                        netWorth: vm.netWorth(from: accounts, fx: fx),
                        totalAssets: vm.totalAssets(from: accounts, fx: fx),
                        totalLiabilities: vm.totalLiabilities(from: accounts, fx: fx),
                        delta: vm.monthOverMonthDelta(from: snapshots),
                        currency: fx.baseCurrency
                    )

                    NetWorthChartCard(
                        snapshots: snapshots,
                        selectedSnapshot: $selectedSnapshot
                    )

                    AllocationCard(segments: vm.allocationSegments(from: accounts))

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
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Net Worth")
            .navigationDestination(isPresented: $showingAllAccounts) {
                AccountsListView(fx: fx, ticker: ticker)
            }
            .task {
                await fx.fetchIfNeeded()
                await ticker.fetchIfNeeded(context: modelContext)
            }
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showingSettings) {
                SettingsView(fx: fx)
            }
            .sheet(isPresented: $showingAddAccount, onDismiss: refreshTickers) {
                AddEditAccountView()
            }
            .sheet(item: $accountToEdit, onDismiss: refreshTickers) { account in
                AddEditAccountView(editingAccount: account)
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
            await ticker.fetch(context: modelContext)
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

    private var displayedValue: Double {
        selectedSnapshot?.netWorth ?? snapshots.last?.netWorth ?? 0
    }

    private var displayedDate: Date? {
        selectedSnapshot?.recordedAt ?? snapshots.last?.recordedAt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History")
                .font(.headline)

            if snapshots.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "chart.line.uptrend.xyaxis")
                    .frame(height: 160)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayedValue.currencyFormatted())
                        .font(.title2.weight(.semibold))
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.15), value: displayedValue)

                    if let date = displayedDate {
                        Text(date.formatted(.dateTime.month().year()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Chart(snapshots) { snap in
                    AreaMark(
                        x: .value("Date", snap.recordedAt),
                        y: .value("Net Worth", snap.netWorth)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue.opacity(0.3), .blue.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Date", snap.recordedAt),
                        y: .value("Net Worth", snap.netWorth)
                    )
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    if let selected = selectedSnapshot, selected.id == snap.id {
                        PointMark(
                            x: .value("Date", snap.recordedAt),
                            y: .value("Net Worth", snap.netWorth)
                        )
                        .foregroundStyle(.blue)
                        .symbolSize(80)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month, count: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(v.currencyFormatted())
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 160)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { drag in
                                        let origin = geo[proxy.plotAreaFrame].origin
                                        let x = drag.location.x - origin.x
                                        if let date: Date = proxy.value(atX: x) {
                                            selectedSnapshot = snapshots.min {
                                                abs($0.recordedAt.timeIntervalSince(date)) <
                                                abs($1.recordedAt.timeIntervalSince(date))
                                            }
                                        }
                                    }
                                    .onEnded { _ in
                                        withAnimation { selectedSnapshot = nil }
                                    }
                            )
                    }
                }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
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
                if totalCount > 5 {
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
