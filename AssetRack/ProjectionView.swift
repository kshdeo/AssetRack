import SwiftUI
import SwiftData
import Charts

// MARK: - ViewModel

/// Owns the computed projection so `body` never has to call `ProjectionService`
/// directly (per CLAUDE.md rule #7 — no heavy work in View `body`).
@Observable
final class ProjectionViewModel {
    private(set) var points: [ProjectionPoint] = []
    private(set) var stackedSegments: [ProjectionStackedPoint] = []

    /// Convenience for the endpoint values most views need.
    var startNetWorth: Double { points.first?.netWorth ?? 0 }
    var endNetWorth: Double   { points.last?.netWorth ?? 0 }

    func recalculate(
        years: Int,
        accounts: [Account],
        settings: ProjectionSettings,
        currency: CurrencyService
    ) {
        let computed = ProjectionService.project(
            over: years,
            accounts: accounts,
            settings: settings,
            currency: currency
        )
        points = computed
        stackedSegments = ProjectionService.stackedSegments(from: computed)
    }

    /// Single source of truth for the `.task(id:)` key — every consumer of
    /// projection data uses this so the hash logic isn't duplicated per view.
    static func dataKey(
        accounts: [Account],
        settings: ProjectionSettings?,
        horizonYears: Int,
        baseCurrency: String
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(horizonYears)
        for account in accounts {
            hasher.combine(account.id)
            hasher.combine(account.currentBalance)
            hasher.combine(account.currency)
            hasher.combine(account.typeRaw)
        }
        if let s = settings {
            hasher.combine(s.cashRate)
            hasher.combine(s.investmentsRate)
            hasher.combine(s.pensionRate)
            hasher.combine(s.realEstateRate)
            hasher.combine(s.liabilityPaydownYears)
            hasher.combine(s.monthlyIncome)
            hasher.combine(s.monthlyExpenses)
        }
        hasher.combine(baseCurrency)
        return hasher.finalize()
    }
}

// MARK: - Lifecycle modifier

/// Wires a view's lifecycle into a `ProjectionViewModel`: ensures the
/// singleton settings row exists, then recalculates whenever any input
/// changes. Lets call sites read `vm.points` / `vm.endNetWorth` from `body`
/// without duplicating the `.onAppear` + `.task(id:)` plumbing per consumer.
struct ProjectionDataModifier: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    let vm: ProjectionViewModel
    let accounts: [Account]
    let settings: ProjectionSettings?
    let horizonYears: Int
    let currencyService: CurrencyService

    private var dataKey: Int {
        ProjectionViewModel.dataKey(
            accounts: accounts,
            settings: settings,
            horizonYears: horizonYears,
            baseCurrency: currencyService.baseCurrency
        )
    }

    func body(content: Content) -> some View {
        content
            .onAppear { _ = modelContext.projectionSettings() }
            .task(id: dataKey) {
                guard let settings else { return }
                vm.recalculate(
                    years: horizonYears,
                    accounts: accounts,
                    settings: settings,
                    currency: currencyService
                )
            }
    }
}

extension View {
    /// Attach a `ProjectionViewModel` to this view's lifecycle so it keeps its
    /// `points` / `stackedSegments` in sync with the underlying inputs.
    func projectionData(
        vm: ProjectionViewModel,
        accounts: [Account],
        settings: ProjectionSettings?,
        horizonYears: Int,
        currencyService: CurrencyService
    ) -> some View {
        modifier(ProjectionDataModifier(
            vm: vm,
            accounts: accounts,
            settings: settings,
            horizonYears: horizonYears,
            currencyService: currencyService
        ))
    }
}

// MARK: - Projection

struct ProjectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [Account]
    @Query private var settingsList: [ProjectionSettings]

    let currencyService: CurrencyService

    @State private var vm = ProjectionViewModel()
    @State private var horizonYears: Int = 10
    @State private var showingAssumptions = false

    private let horizons: [Int] = [1, 5, 10, 20, 30]

    private var settings: ProjectionSettings? { settingsList.first }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                horizonPicker

                ProjectionSummaryCard(
                    horizonYears: horizonYears,
                    points: vm.points,
                    netMonthlySavings: settings?.netMonthlySavings ?? 0,
                    currencyService: currencyService
                )

                ProjectionChartCard(
                    points: vm.points,
                    stackedSegments: vm.stackedSegments
                )

                ProjectionBreakdownCard(
                    points: vm.points,
                    currencyService: currencyService
                )
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Projection")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAssumptions = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .disabled(settings == nil)
            }
        }
        .sheet(isPresented: $showingAssumptions) {
            if let settings {
                ProjectionAssumptionsView(settings: settings, currencyService: currencyService)
            }
        }
        .projectionData(
            vm: vm,
            accounts: accounts,
            settings: settings,
            horizonYears: horizonYears,
            currencyService: currencyService
        )
        .onAppear {
            // Seed the picker from the persisted horizon on first appearance.
            if let s = settings, horizonYears != s.horizonYears {
                horizonYears = s.horizonYears
            }
        }
        .onChange(of: horizonYears) { _, newValue in
            settings?.horizonYears = newValue
            try? modelContext.save()
        }
    }

    // MARK: - Subviews

    private var horizonPicker: some View {
        Picker("Horizon", selection: $horizonYears) {
            ForEach(horizons, id: \.self) { years in
                Text("\(years)y").tag(years)
            }
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - Summary Card

struct ProjectionSummaryCard: View {
    let horizonYears: Int
    let points: [ProjectionPoint]
    let netMonthlySavings: Double
    let currencyService: CurrencyService

    private var cashFlowSubtitle: String {
        let abs = currencyService.formattedBase(Swift.abs(netMonthlySavings))
        return netMonthlySavings >= 0
            ? "Assumes saving \(abs)/mo into investments"
            : "Assumes drawing \(abs)/mo from investments"
    }

    var body: some View {
        let endNetWorth = points.last?.netWorth ?? 0
        let startNetWorth = points.first?.netWorth ?? 0
        let delta = endNetWorth - startNetWorth
        let pctChange: Double? = startNetWorth != 0 ? delta / abs(startNetWorth) : nil

        VStack(spacing: 6) {
            Text("Projected Net Worth in \(horizonYears)y")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(currencyService.formattedBase(endNetWorth))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.4), value: endNetWorth)

            if let pct = pctChange {
                HStack(spacing: 4) {
                    Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                    Text("\(pct, format: .percent.precision(.fractionLength(0))) vs today")
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(delta >= 0 ? Color.green : Color.red)
            }

            if netMonthlySavings != 0 {
                Text(cashFlowSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 4)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(currencyService.formattedBase(startNetWorth))
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("In \(horizonYears)y")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(currencyService.formattedBase(endNetWorth))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(endNetWorth >= startNetWorth ? Color.green : Color.red)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Chart Card

struct ProjectionChartCard: View {
    let points: [ProjectionPoint]
    let stackedSegments: [ProjectionStackedPoint]

    private static let categoryColors: KeyValuePairs<String, Color> = [
        AccountCategory.cashAndBank.rawValue: .teal,
        AccountCategory.investments.rawValue: .blue,
        AccountCategory.pension.rawValue:     .purple,
        AccountCategory.realEstate.rawValue:  .indigo,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trajectory")
                .font(.headline)

            if points.isEmpty || points.allSatisfy({ $0.totalAssets == 0 && $0.liabilities == 0 }) {
                ContentUnavailableView("Add an account to see a projection",
                                       systemImage: "chart.line.uptrend.xyaxis")
                    .frame(height: 200)
            } else {
                Chart {
                    ForEach(stackedSegments) { segment in
                        AreaMark(
                            x: .value("Date", segment.date),
                            yStart: .value("Start", segment.stackedStart),
                            yEnd: .value("End", segment.stackedEnd)
                        )
                        .foregroundStyle(by: .value("Category", segment.category.rawValue))
                        .interpolationMethod(.linear)
                    }
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Net Worth", point.netWorth)
                        )
                        .foregroundStyle(Color.primary)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartForegroundStyleScale(Self.categoryColors)
                .chartLegend(position: .bottom, alignment: .center, spacing: 8)
                .frame(height: 220)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Breakdown Card

struct ProjectionBreakdownCard: View {
    let points: [ProjectionPoint]
    let currencyService: CurrencyService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By category")
                .font(.headline)

            ForEach(Array(AccountCategory.allCases), id: \.self) { category in
                let from = startValue(for: category)
                let to   = endValue(for: category)
                if from > 0 || to > 0 {
                    row(category: category, from: from, to: to)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func startValue(for category: AccountCategory) -> Double {
        if category == .liabilities { return points.first?.liabilities ?? 0 }
        return points.first?.assetsByCategory[category] ?? 0
    }

    private func endValue(for category: AccountCategory) -> Double {
        if category == .liabilities { return points.last?.liabilities ?? 0 }
        return points.last?.assetsByCategory[category] ?? 0
    }

    private func row(category: AccountCategory, from: Double, to: Double) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.rawValue)
                    .font(.subheadline.weight(.medium))
                Text(currencyService.formattedBase(from))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(currencyService.formattedBase(to))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(to >= from ? Color.primary : Color.red)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Assumptions sheet

struct ProjectionAssumptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: ProjectionSettings
    let currencyService: CurrencyService

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    growthRow(title: "Cash & Bank",
                              rate: Binding(get: { settings.cashRate },
                                            set: { settings.cashRate = $0 }))
                    growthRow(title: "Investments",
                              rate: Binding(get: { settings.investmentsRate },
                                            set: { settings.investmentsRate = $0 }))
                    growthRow(title: "Pension",
                              rate: Binding(get: { settings.pensionRate },
                                            set: { settings.pensionRate = $0 }))
                    growthRow(title: "Real Estate",
                              rate: Binding(get: { settings.realEstateRate },
                                            set: { settings.realEstateRate = $0 }))
                } header: {
                    Text("Annual growth rates")
                } footer: {
                    Text("Each asset category compounds at its own rate. Defaults assume long-run historical averages.")
                }

                Section {
                    amountRow(title: "Monthly income",   amount: $settings.monthlyIncome)
                    amountRow(title: "Monthly expenses", amount: $settings.monthlyExpenses)
                    LabeledContent("Net savings") {
                        Text(currencyService.formattedBase(settings.netMonthlySavings))
                            .foregroundStyle(settings.netMonthlySavings >= 0 ? .green : .red)
                    }
                } header: {
                    Text("Monthly cash flow")
                } footer: {
                    Text("Net savings (income − expenses) flow into investments each month. A negative net draws investments down — useful for retirement scenarios. All amounts in your base currency (\(currencyService.baseCurrency)).")
                }

                Section {
                    Stepper(value: $settings.liabilityPaydownYears, in: 0...40) {
                        HStack {
                            Text("Pay off in")
                            Spacer()
                            Text("\(settings.liabilityPaydownYears) years")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Liabilities")
                } footer: {
                    Text("Liabilities are amortised linearly to zero over this period. Set to 0 to leave balances unchanged.")
                }
            }
            .navigationTitle("Assumptions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func growthRow(title: String, rate: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0%",
                      value: Binding(
                          get: { rate.wrappedValue * 100 },
                          set: { rate.wrappedValue = $0 / 100 }),
                      format: .number.precision(.fractionLength(1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Text("%")
                .foregroundStyle(.secondary)
        }
    }

    private func amountRow(title: String, amount: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0",
                      value: amount,
                      format: .currency(code: currencyService.baseCurrency)
                                .precision(.fractionLength(0)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 120)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ProjectionView(currencyService: CurrencyService())
    }
    .modelContainer(ModelContainer.previewContainer)
}
