import Foundation

// MARK: - Result type

/// One point on the projection timeline.
/// Amounts are already converted to `currency.baseCurrency`.
struct ProjectionPoint: Identifiable {
    let id = UUID()
    let date: Date
    let netWorth: Double
    /// Per-category asset value (post-growth). Used for the stacked-area chart.
    let assetsByCategory: [AccountCategory: Double]
    /// Total liabilities at this point (post-paydown).
    let liabilities: Double

    var totalAssets: Double { assetsByCategory.values.reduce(0, +) }
}

// MARK: - Service

/// Pure-function projection math. No state, no I/O.
struct ProjectionService {

    /// Project the user's net worth at monthly granularity for `years` into the future.
    /// Each asset category compounds on its starting balance plus the standard
    /// annuity contribution stream. Liabilities pay down linearly toward zero.
    ///
    /// V2 model: net monthly savings (income − expenses) flows into the Investments
    /// category. Negative net flows out (drawdown / retiree scenario).
    static func project(
        over years: Int,
        accounts: [Account],
        settings: ProjectionSettings,
        currency: CurrencyService,
        from start: Date = Date()
    ) -> [ProjectionPoint] {

        guard years > 0 else { return [] }

        let base = currency.baseCurrency
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        let totalMonths = years * 12

        // 1) Sum starting balances per category in base currency.
        var startByCategory: [AccountCategory: Double] = [:]
        for account in accounts {
            let amount = currency.convert(
                Money(account.currentBalance, account.currency),
                to: base
            ).amount
            startByCategory[account.type.category, default: 0] += amount
        }

        // 2) Convert annual rates to monthly compounding rates.
        var monthlyRate: [AccountCategory: Double] = [:]
        for category in AccountCategory.allCases {
            let annual = settings.growthRate(for: category)
            monthlyRate[category] = pow(1 + annual, 1.0 / 12.0) - 1
        }

        // 3) Linear monthly liability paydown (zero when paydownYears is 0).
        let startingLiabilities = startByCategory[.liabilities] ?? 0
        let liabilityMonthlyPaydown: Double = {
            guard settings.liabilityPaydownYears > 0 else { return 0 }
            return startingLiabilities / Double(settings.liabilityPaydownYears * 12)
        }()

        // 4) Build one point per month, including month 0 = today.
        var points: [ProjectionPoint] = []
        points.reserveCapacity(totalMonths + 1)

        for month in 0...totalMonths {
            let date = calendar.date(byAdding: .month, value: month, to: startDay) ?? startDay

            var assets: [AccountCategory: Double] = [:]
            for category in AccountCategory.allCases where category != .liabilities {
                let start = startByCategory[category] ?? 0
                let rate  = monthlyRate[category] ?? 0
                let contribution = monthlyContribution(for: category, settings: settings)
                // FV = PV * (1+r)^t + PMT * ((1+r)^t − 1) / r
                // For r = 0 the annuity term collapses to PMT * t (linear).
                let growthFactor = pow(1 + rate, Double(month))
                let pvGrowth = start * growthFactor
                let pmtGrowth: Double = rate == 0
                    ? contribution * Double(month)
                    : contribution * (growthFactor - 1) / rate
                // Floor at 0 — once a category drains, it can't go negative.
                assets[category] = max(0, pvGrowth + pmtGrowth)
            }

            let liabilities = max(0, startingLiabilities - liabilityMonthlyPaydown * Double(month))
            let totalAssets = assets.values.reduce(0, +)

            points.append(ProjectionPoint(
                date: date,
                netWorth: totalAssets - liabilities,
                assetsByCategory: assets,
                liabilities: liabilities
            ))
        }

        return points
    }

    /// Monthly contribution that flows into each category. V2 routes net savings
    /// (income − expenses) into Investments only; pension and real estate can
    /// get their own streams in a future iteration.
    private static func monthlyContribution(for category: AccountCategory, settings: ProjectionSettings) -> Double {
        switch category {
        case .investments:                                   return settings.netMonthlySavings
        case .cashAndBank, .pension, .realEstate, .liabilities: return 0
        }
    }
}

// MARK: - Stacked points for chart rendering

/// Stacked area chart data point — same shape as `StackedDataPoint` but for projection.
/// Kept separate so we can evolve projection rendering independently.
struct ProjectionStackedPoint: Identifiable {
    let id = UUID()
    let date: Date
    let category: AccountCategory
    let stackedStart: Double
    let stackedEnd: Double
}

extension ProjectionService {
    /// Flatten projection points into stacked-area segments for Swift Charts.
    /// Same category order as the history chart for visual consistency.
    static func stackedSegments(from points: [ProjectionPoint]) -> [ProjectionStackedPoint] {
        let order: [AccountCategory] = [.cashAndBank, .investments, .pension, .realEstate]
        var result: [ProjectionStackedPoint] = []

        for point in points {
            var cumulative = 0.0
            for category in order {
                let value = point.assetsByCategory[category] ?? 0
                guard value > 0 else { continue }
                result.append(ProjectionStackedPoint(
                    date: point.date,
                    category: category,
                    stackedStart: cumulative,
                    stackedEnd: cumulative + value
                ))
                cumulative += value
            }
        }
        return result
    }
}
