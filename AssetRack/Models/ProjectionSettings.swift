import Foundation
import SwiftData

/// User-editable assumptions for the net-worth projection.
/// Singleton — `ModelContext.projectionSettings()` fetches or creates the single row.
@Model
final class ProjectionSettings {
    var id: UUID = UUID()

    // Annual growth rates as decimals (0.07 = 7%) per asset category.
    var cashRate: Double         = 0.02
    var investmentsRate: Double  = 0.07
    var pensionRate: Double      = 0.06
    var realEstateRate: Double   = 0.03

    /// Years to amortise each liability toward zero (linear paydown, V1).
    var liabilityPaydownYears: Int = 5

    /// Persisted UI choice so the user lands on their last horizon.
    var horizonYears: Int = 10

    init() {
        self.id = UUID()
    }

    /// Annual growth rate for an asset category. Liabilities return 0 — they
    /// are amortised separately via `liabilityPaydownYears`.
    func growthRate(for category: AccountCategory) -> Double {
        switch category {
        case .cashAndBank: return cashRate
        case .investments: return investmentsRate
        case .pension:     return pensionRate
        case .realEstate:  return realEstateRate
        case .liabilities: return 0
        }
    }

    /// Convenience setter so the view can write through a category key.
    func setGrowthRate(_ rate: Double, for category: AccountCategory) {
        switch category {
        case .cashAndBank: cashRate        = rate
        case .investments: investmentsRate = rate
        case .pension:     pensionRate     = rate
        case .realEstate:  realEstateRate  = rate
        case .liabilities: break
        }
    }
}

// MARK: - ModelContext helper

extension ModelContext {
    /// Fetches the singleton `ProjectionSettings` row, creating it on first access.
    func projectionSettings() -> ProjectionSettings {
        let descriptor = FetchDescriptor<ProjectionSettings>()
        if let existing = (try? fetch(descriptor))?.first { return existing }
        let fresh = ProjectionSettings()
        insert(fresh)
        try? save()
        return fresh
    }
}
